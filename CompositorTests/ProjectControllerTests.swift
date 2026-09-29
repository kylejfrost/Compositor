import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Saving from the app (Task 4.10): Save As Photoshop is a working-format save, as in Photoshop. The document then
/// lives in the PSD, ⌘S keeps writing it, and a save that Photoshop can't hold exactly asks first.
@MainActor struct ProjectControllerTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectControllerTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func solid(_ width: Int, _ height: Int, _ rgba: [UInt8]) throws -> ImportedImage {
        let bytes = Array((0..<width * height).map { _ in rgba }.joined())
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ImportedImage(image: image, thumbnail: image, name: "Paint")
    }

    /// A 6×4 document with one opaque red pixel layer, unsaved.
    private func controller() throws -> ProjectController {
        let session = EditorSession()
        session.createDocument(width: 6, height: 4)
        session.insert(try solid(6, 4, [255, 0, 0, 255]))
        return ProjectController(session: session)
    }

    private func layerNames(_ url: URL) throws -> [String] {
        try PSDReader.read(from: url).layers.map(\.name)
    }

    @Test func savingAsPhotoshopMakesThePSDTheDocumentsFile() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try controller()
        let session = controller.session
        #expect(session.isModified)

        let url = root.appendingPathComponent("Poster.psd")
        let report = try #require(try await controller.saveDocument(to: url, format: .psd))
        #expect(report.warnings.isEmpty && report.layerRecordCount == 1)
        #expect(session.projectURL == url && session.documentFormat == .psd)
        #expect(!session.isModified)
        let written = try PSDReader.read(from: url)
        #expect(written.width == 6 && written.height == 4)
        #expect(written.layers.map(\.name) == ["Paint"])

        // ⌘S keeps writing the PSD, with no panel.
        session.insert(try solid(2, 2, [0, 0, 255, 255]))
        #expect(session.isModified)
        #expect(await controller.save())
        #expect(try layerNames(url) == ["Paint", "Paint"])
        #expect(session.projectURL == url && session.documentFormat == .psd && !session.isModified)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Poster.comp").path))

        // Saved as a project again, the document is a project: no report, and ⌘S writes the .comp.
        let project = root.appendingPathComponent("Poster.comp")
        #expect(try await controller.saveDocument(to: project, format: .comp) == nil)
        #expect(session.projectURL == project && session.documentFormat == .comp && !session.isModified)
        #expect(try await ProjectStore.shared.load(from: project).manifest.layers.count == 2)
    }

    /// A save Photoshop can't hold exactly (here, a Grain adjustment it has no layer for) lists what changes before
    /// writing anything, and writes only once agreed to.
    @Test func aLossyPhotoshopSaveAsksBeforeWriting() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try controller()
        let session = controller.session
        let url = root.appendingPathComponent("Poster.psd")
        try await controller.saveDocument(to: url, format: .psd)
        let before = try Data(contentsOf: url)

        var grain = LayerAdjustment(kind: .grain)
        grain.grain = GrainSettings(amount: 80, size: 1, roughness: 60, seed: 7)
        session.beginEdit("Add Grain")
        session.document?.layers.append(ImageLayer(id: UUID(), asset: nil, name: "Grain", isVisible: true,
                                                   transform: LayerTransform(origin: .zero, size: CGSize(width: 6, height: 4)),
                                                   adjustment: grain))
        session.endEdit()
        #expect(session.isModified)

        var asked: [[PSDWriteWarning]] = []
        controller.confirmPhotoshopReport = { warnings in asked.append(warnings); return false }
        #expect(await controller.save() == false)
        #expect(asked.count == 1)
        #expect(asked.first?.contains { $0.layerName == "Grain" && $0.lossy } == true)
        #expect(try Data(contentsOf: url) == before)
        #expect(session.isModified)

        controller.confirmPhotoshopReport = { warnings in asked.append(warnings); return true }
        #expect(await controller.save())
        #expect(asked.count == 2)
        #expect(try layerNames(url) == ["Paint", "Grain (rasterized)"])
        #expect(!session.isModified)
        // The document keeps its live adjustment: only the file holds pixels.
        #expect(session.document?.layers.last?.adjustment?.kind == .grain)
    }

    /// A save writes the plan its report was made from, unless the document changed while the report was up: then it
    /// is planned again, so the file is the document marked saved.
    @Test func aDocumentChangedWhileTheReportIsUpIsPlannedAgain() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try controller()
        let session = controller.session
        let url = root.appendingPathComponent("Poster.psd")
        try await controller.saveDocument(to: url, format: .psd)
        var grain = LayerAdjustment(kind: .grain)
        grain.grain = GrainSettings(amount: 80, size: 1, roughness: 60, seed: 7)
        session.beginEdit("Add Grain")
        session.document?.layers.append(ImageLayer(id: UUID(), asset: nil, name: "Grain", isVisible: true,
                                                   transform: LayerTransform(origin: .zero, size: CGSize(width: 6, height: 4)),
                                                   adjustment: grain))
        session.endEdit()
        controller.confirmPhotoshopReport = { _ in
            session.beginEdit("Rename")
            session.document?.layers[0].name = "Renamed"
            session.endEdit()
            return true
        }
        #expect(await controller.save())
        #expect(try layerNames(url) == ["Renamed", "Grain (rasterized)"])
        #expect(!session.isModified)
    }

    /// Nothing lossy: the save goes ahead without asking, even when the report has notes.
    @Test func aPhotoshopSaveWithoutLossyItemsDoesNotAsk() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try controller()
        let url = root.appendingPathComponent("Poster.psd")
        try await controller.saveDocument(to: url, format: .psd)
        controller.session.insert(try solid(2, 2, [0, 255, 0, 255]))
        var asked = false
        controller.confirmPhotoshopReport = { _ in asked = true; return false }
        #expect(await controller.save())
        #expect(!asked)
        #expect(try layerNames(url).count == 2)
    }
}
