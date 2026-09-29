import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Compositor

/// Opt-in: Compositor's PSD import compared, file by file and layer by layer, with what psd-tools reads from a folder
/// of real Photoshop files. It runs only when `COMPOSITOR_PSD_CORPUS` names a folder holding local copies of the files
/// and the `expectations.json` that scripts/psd-corpus-expectations.py wrote next to them:
///
///     uv run --with psd-tools python3 scripts/psd-corpus-expectations.py <folder>
///     TEST_RUNNER_COMPOSITOR_PSD_CORPUS=<folder> xcodebuild test … -only-testing:CompositorTests/PSDCorpusTests
///
/// (xcodebuild hands `TEST_RUNNER_`-prefixed variables to the tests without the prefix.) Checks: no layer lost; each
/// layer's kind (folder or not) and locks; editable type as live text with its text, font, size and justification;
/// smart-object IDs and placement quads; which effects Compositor shows and whether each is on; for each shape,
/// whether it imports live (as Compositor's rules decide, which the script repeats) and as which kind, or else that it
/// keeps its `vogk` with the same origin types; and the document's resolution. Files and layers are named by hash and
/// layer ID only, as the expectations name them, so nothing of the files' contents reaches the test log. The folder
/// and its files go through `PSDCorpusGuard` first: a cloud-backed folder is refused, and a file that is not local
/// and fully present is skipped.
@MainActor
struct PSDCorpusTests {
    struct Expectations: Decodable {
        let version: Int
        let files: [File]
    }
    struct File: Decodable {
        let fileSha1: String
        let error: String?
        let supported: Bool?
        let width: Int?
        let height: Int?
        let resolution: Double?
        let layerCount: Int?
        let layers: [Layer]?
    }
    struct Layer: Decodable {
        let id: Int64
        let nameSha1: String
        let kind: String
        let locks: UInt32
        let text: Text?
        let smartObject: SmartObject?
        let effects: Effects?
        let shape: ShapeLayer?
    }
    struct Text: Decodable {
        let textSha1: String
        let transform: [Double]
        let runs: [Run]
        let paragraphs: [Paragraph]
        let editable: Bool
    }
    struct Run: Decodable {
        let shown: Int
        let font: String
        let size: Double
    }
    struct Paragraph: Decodable {
        let shown: Int
        let justification: Int
    }
    struct SmartObject: Decodable {
        let uniqueId: String
        let placed: String
        let quad: [Double]?
    }
    struct Effects: Decodable {
        let master: Bool
        let kinds: [String: [Entry]]
    }
    struct Entry: Decodable {
        let enabled: Bool
        let rgb: Bool
        let paint: String?
    }
    struct ShapeLayer: Decodable {
        let items: [Shape]
        /// Whether Compositor's import rules make it a live shape, and which kind (`rectangle`, `ellipse`, `line`).
        let live: Bool
        let kind: String?
    }
    struct Shape: Decodable, Equatable {
        let type: Int
        let invalidated: Bool
    }

    /// What the run found, by count.
    struct Tally: CustomStringConvertible {
        var files = 0, skipped = 0, layers = 0, liveText = 0, keptText = 0, smartObjects = 0, effectLayers = 0
        var liveShapes = 0, shapeLayers = 0, locked = 0
        var description: String {
            "\(files) files (\(skipped) skipped), \(layers) layers: text \(liveText) live, \(keptText) kept as pixels; "
                + "\(smartObjects) smart objects; \(effectLayers) layers with effects; shapes \(liveShapes) live of "
                + "\(shapeLayers); \(locked) locked"
        }
    }

    static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The run showing the most characters; the first on a tie (as `PSDTypeReader.dominantRun` picks).
    static func dominant<T>(_ runs: [T], shown: (T) -> Int) -> T? {
        guard let best = runs.indices.max(by: { shown(runs[$0]) < shown(runs[$1]) || (shown(runs[$0]) == shown(runs[$1]) && $0 > $1) }) else { return nil }
        return runs[best]
    }

    static let kinds: [String: LayerEffectKind] = [
        "stroke": .stroke, "shadow": .shadow, "colorOverlay": .colorOverlay, "innerShadow": .innerShadow, "outerGlow": .outerGlow,
    ]

    /// The effects Compositor shows for `effects` and whether each is on: of a kind's present entries the first enabled
    /// one, else the first; none when its color isn't RGB or, for a stroke, its paint isn't a solid color; all off
    /// with the master switch off.
    static func expected(_ effects: Effects) -> [LayerEffectKind: Bool] {
        var result: [LayerEffectKind: Bool] = [:]
        for (name, entries) in effects.kinds {
            guard let kind = kinds[name], !entries.isEmpty else { continue }
            let chosen = entries.first(where: \.enabled) ?? entries[0]
            guard chosen.rgb, (chosen.paint ?? "SClr") == "SClr" else { continue }
            result[kind] = effects.master && chosen.enabled
        }
        return result
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_PSD_CORPUS"] != nil), .timeLimit(.minutes(10)))
    func importMatchesPsdTools() throws {
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_PSD_CORPUS"])
        let entries: [(name: String, file: Result<URL, PSDCorpusGuard.Refusal>)]
        do throws(PSDCorpusGuard.Refusal) {
            entries = try PSDCorpusGuard.entries(path) { $0 == "expectations.json" || $0.lowercased().hasSuffix(".psd") }
        } catch {
            Issue.record("the corpus folder is refused, \(error.rawValue): copy the files to a local folder")
            return
        }
        guard case .success(let expectationsURL)? = entries.first(where: { $0.name == "expectations.json" })?.file else {
            Issue.record("expectations.json is missing, or not a local file")
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let expectations = try decoder.decode(Expectations.self, from: Data(contentsOf: expectationsURL))
        #expect(expectations.version == 2)
        let byHash = Dictionary(entries.filter { $0.name != "expectations.json" }.map { (Self.sha1($0.name), $0.file) }) { first, _ in first }
        var tally = Tally()
        for file in expectations.files {
            let label = String(file.fileSha1.prefix(12))
            tally.files += 1
            guard file.error == nil, file.supported == true, let expectedLayers = file.layers else { tally.skipped += 1; continue }
            let entry = try #require(byHash[file.fileSha1], "\(label): no file with this name hash in the corpus folder")
            let url: URL
            switch entry {
            case .success(let local): url = local
            case .failure(let reason):
                tally.skipped += 1
                Issue.record("\(label) skipped: \(reason.rawValue)", severity: .warning)
                continue
            }
            let imported: PSDImport
            do { imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(from: url)) } catch {
                Issue.record("\(label): Compositor couldn’t import the file (\(type(of: error)))")
                continue
            }
            #expect(imported.width == file.width && imported.height == file.height, "\(label): size")
            // Resolution as the reader keeps it: 72 when absent or below 1 ppi, at most 9,600.
            let ppi = file.resolution.map { $0.isFinite && $0 >= 1 ? min(9600, $0) : 72 } ?? 72
            #expect(abs(imported.resolution - ppi) < 0.001, "\(label): resolution \(imported.resolution), expected \(ppi)")
            #expect(imported.layers.count == file.layerCount, "\(label): \(imported.layers.count) layers, expected \(file.layerCount ?? -1)")
            tally.layers += imported.layers.count

            // Matched by layer ID (`lyid`), else by name.
            var unmatched = imported.layers
            for expected in expectedLayers {
                let index = unmatched.firstIndex { layer in
                    expected.id >= 0 ? layer.psdExtras?.layerID.map { Int64(UInt32(bitPattern: $0)) } == expected.id
                        : layer.psdExtras?.layerID == nil && Self.sha1(layer.name) == expected.nameSha1
                }
                guard let index else {
                    Issue.record("\(label) layer \(expected.id): missing from the import")
                    continue
                }
                let layer = unmatched.remove(at: index)
                let site = "\(label) layer \(expected.id)"
                #expect(layer.isGroup == (expected.kind == "group"), "\(site): folder or not")
                #expect(layer.locks.rawValue == expected.locks, "\(site): locks \(layer.locks.rawValue), expected \(expected.locks)")
                if expected.locks != 0 { tally.locked += 1 }
                if let text = expected.text { check(text, on: layer, site, &tally) }
                if let smartObject = expected.smartObject { check(smartObject, on: layer, site, &tally) }
                check(expected.effects, on: layer, site, &tally)
                if let shape = expected.shape { check(shape, on: layer, site, &tally) }
            }
        }
        // Counts only; attached to the test result as well, since the runner doesn't keep the tests' output.
        print("PSD corpus: \(tally)")
        Attachment.record(tally.description, named: "psd-corpus.txt")
    }

    private func check(_ text: Text, on layer: ImageLayer, _ site: String, _ tally: inout Tally) {
        guard let style = layer.liveText?.style else {
            tally.keptText += 1
            #expect(!text.editable, "\(site): editable type imported as pixels")
            #expect(layer.psdExtras?.block("TySh") != nil, "\(site): type data not kept")
            return
        }
        tally.liveText += 1
        #expect(Self.sha1(style.content) == text.textSha1, "\(site): text differs")
        guard text.transform.count == 6, let run = Self.dominant(text.runs, shown: \.shown) else {
            Issue.record("\(site): live text without a transform or style runs in psd-tools")
            return
        }
        let sy = hypot(text.transform[2], text.transform[3])
        #expect(style.fontName == run.font, "\(site): font \(style.fontName), expected \(run.font)")
        let size = min(2000, max(1, run.size * sy))
        #expect(abs(Double(style.fontSize) - size) < 0.01, "\(site): size \(style.fontSize), expected \(size)")
        let alignment: TextAlignment = switch Self.dominant(text.paragraphs, shown: \.shown)?.justification ?? 0 {
        case 1, 4: .right
        case 2, 5: .center
        default: .left
        }
        #expect(style.alignment == alignment, "\(site): alignment \(style.alignment), expected \(alignment)")
    }

    private func check(_ smartObject: SmartObject, on layer: ImageLayer, _ site: String, _ tally: inout Tally) {
        guard let actual = layer.smartObject else {
            Issue.record("\(site): smart object imported without its settings")
            return
        }
        tally.smartObjects += 1
        #expect(actual.info.uniqueID == smartObject.uniqueId, "\(site): contents ID differs")
        #expect(actual.info.placedID == smartObject.placed, "\(site): placement ID differs")
        guard let quad = smartObject.quad else { return }
        let corners = actual.info.quad.documentQuad(for: layer.transform).corners
        let expected = stride(from: 0, to: 8, by: 2).map { CGPoint(x: quad[$0], y: quad[$0 + 1]) }
        for (corner, point) in zip(corners, expected) {
            #expect(abs(corner.x - point.x) < 0.01 && abs(corner.y - point.y) < 0.01,
                    "\(site): quad corner \(corner), expected \(point)")
        }
    }

    private func check(_ effects: Effects?, on layer: ImageLayer, _ site: String, _ tally: inout Tally) {
        // Folders, adjustments and placeholders keep effects only in their Photoshop data.
        let drawsPixels = !layer.isGroup && layer.adjustment == nil && !layer.isPhotoshopPlaceholder
        let expected = drawsPixels ? effects.map(Self.expected) ?? [:] : [:]
        var actual: [LayerEffectKind: Bool] = [:]
        for kind in layer.effects?.kinds ?? [] { actual[kind] = layer.effects?.isEnabled(kind) }
        if !actual.isEmpty { tally.effectLayers += 1 }
        #expect(actual == expected, "\(site): effects \(actual), expected \(expected)")
    }

    private func check(_ expected: ShapeLayer, on layer: ImageLayer, _ site: String, _ tally: inout Tally) {
        tally.shapeLayers += 1
        #expect((layer.liveShape != nil) == expected.live,
                "\(site): \(layer.liveShape == nil ? "pixels" : "live shape"), expected \(expected.live ? "live shape" : "pixels")")
        if let shape = layer.liveShape {
            tally.liveShapes += 1
            #expect(shape.style.kind.rawValue.lowercased() == expected.kind,
                    "\(site): live \(shape.style.kind.rawValue), expected \(expected.kind ?? "none")")
            return
        }
        guard !expected.items.isEmpty else { return }
        // Kept as pixels: the shape's description comes along, as Photoshop wrote it, to be written back.
        guard let block = layer.psdExtras?.block("vogk") else {
            Issue.record("\(site): shape data (vogk) not kept")
            return
        }
        let items = Self.originItems(Data(block))
        #expect(items == expected.items,
                "\(site): vogk origin types \(items.map(\.type)), expected \(expected.items.map(\.type))")
    }

    /// Each `vogk` item's `keyOriginType` and whether it is invalidated, read with Compositor's descriptor reader.
    static func originItems(_ data: Data) -> [Shape] {
        var offset = 4
        guard data.count >= 4, let root = try? PSDDescriptorReader.readBlock(data, at: &offset) else { return [] }
        return (root.list("keyDescriptorList") ?? []).compactMap { value in
            guard case .object(let item) = value else { return nil }
            return Shape(type: item.int("keyOriginType") ?? 0, invalidated: item.bool("keyShapeInvalidated") ?? false)
        }
    }
}
