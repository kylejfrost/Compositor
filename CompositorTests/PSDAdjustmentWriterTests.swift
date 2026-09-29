import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Adjustment layers written as Photoshop's adjustment blocks (Task 4.9): fresh for layers Photoshop never saw, byte
/// for byte for imported layers whose settings are untouched, rewritten inside the file's own block once edited, and
/// the kinds Photoshop lacks rasterized only when a lossy save is allowed.
@MainActor
@Suite(.serialized)
struct PSDAdjustmentWriterTests {
    // MARK: Fixtures

    private static let canvas = CGSize(width: 8, height: 8)

    /// Four 4×4 opaque patches: red, gray, blue and skin, something every adjustment changes.
    private func patches() throws -> CGImage {
        let colors: [[UInt8]] = [[200, 40, 40, 255], [128, 128, 128, 255], [40, 60, 200, 255], [230, 180, 150, 255]]
        var bytes: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 { bytes += colors[(y / 4) * 2 + x / 4] }
        }
        return try image(8, 8, bytes)
    }

    /// Premultiplied RGBA pixels, top row first.
    private func image(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Premultiplied RGBA bytes of `image`, top row first.
    private func premultiplied(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in (0..<image.width * 4).map { bytes[y * context.bytesPerRow + $0] } }
    }

    private func pixelLayer(_ name: String, _ image: CGImage, parent: UUID? = nil) -> ImageLayer {
        ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: name), name: name, isVisible: true,
                   transform: LayerTransform(origin: .zero, size: CGSize(width: image.width, height: image.height)),
                   parentID: parent)
    }

    private func adjustmentLayer(_ adjustment: LayerAdjustment, name: String? = nil, parent: UUID? = nil) -> ImageLayer {
        ImageLayer(id: UUID(), asset: nil, name: name ?? adjustment.kind.rawValue, isVisible: true,
                   transform: LayerTransform(origin: .zero, size: Self.canvas), parentID: parent, adjustment: adjustment)
    }

    private func session(_ layers: [ImageLayer]) -> EditorSession {
        let session = EditorSession()
        session.document = CanvasDocument(width: Int(Self.canvas.width), height: Int(Self.canvas.height), layers: layers)
        session.activeLayerID = layers.last?.id
        return session
    }

    private func plan(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws -> PSDLayerRecordWriter.Plan {
        try PSDLayerRecordWriter.plan(try #require(session.psdWriteRequest()), options: options)
    }

    private func record(_ name: String, in plan: PSDLayerRecordWriter.Plan) throws -> PSDLayerRecord {
        try #require(plan.records.first { $0.name == name })
    }

    /// The file `session` is written as, opened again as the app opens a PSD.
    private func reopened(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws -> PSDImport {
        let data = try PSDWriter.data(for: try #require(session.psdWriteRequest()), options: options).data
        return try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
    }

    /// The adjustment block `adjustment` is written as, on a layer Photoshop never saw.
    private func block(of adjustment: LayerAdjustment) throws -> PSDTaggedBlock {
        let plan = try plan(session([pixelLayer("Base", try patches()), adjustmentLayer(adjustment, name: "Adjustment")]))
        return try #require(try record("Adjustment", in: plan).blocks.first)
    }

    /// An adjustment layer as Photoshop stores it: its settings block.
    private func adjustmentRecord(_ name: String, _ key: String, _ data: Data) -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: key, data: data)])
        return record
    }

    /// A session holding `records` above an opaque base, as Photoshop wrote them, opened as the app opens a PSD (into
    /// `target` when given).
    private func opened(_ records: [PSDRecord], into target: EditorSession? = nil) throws -> EditorSession {
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(origin: .zero, size: Self.canvas)
        base.image = try patches()
        let document = PSDDocument(width: Int(Self.canvas.width), height: Int(Self.canvas.height), resolution: 72,
                                   layers: [base] + records)
        let data = try PSDFixture.data(document, composite: try patches())
        let session = target ?? EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        return session
    }

    private func index(of name: String, in session: EditorSession) throws -> Int {
        try #require(session.document?.layers.firstIndex { $0.name == name })
    }

    private func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    private func i16(_ value: Int) -> [UInt8] { u16(Int(UInt16(bitPattern: Int16(value)))) }
    private func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value) }
    private func f32(_ value: Float) -> [UInt8] { u32(Int(value.bitPattern)) }
    private func padded(_ bytes: [UInt8]) -> Data { Data(bytes + Array(repeating: 0, count: (4 - bytes.count % 4) % 4)) }

    /// A `curv` curve: its point count, then each point as `(output, input)`.
    private func curve(_ points: [(x: Int, y: Int)]) -> [UInt8] {
        u16(points.count) + points.flatMap { u16($0.y) + u16($0.x) }
    }

    /// A `hue2` block with Photoshop's bands and no range adjusted.
    private func hueBlock(colorize: Bool, colorization: [Int], master: [Int]) -> Data {
        var bytes = u16(2) + [colorize ? 1 : 0, 0] + colorization.flatMap(i16) + master.flatMap(i16)
        for range in ColorRange.colorRanges {
            bytes += range.defaultBand.handles.flatMap { i16(Int($0)) } + [0, 0, 0].flatMap(i16)
        }
        return Data(bytes)
    }

    /// One layer's settings for each kind Photoshop has, every one away from its default; values the file holds
    /// exactly.
    private static func sample(_ kind: AdjustmentKind) -> LayerAdjustment {
        var adjustment = LayerAdjustment(kind: kind)
        switch kind {
        case .levels:
            adjustment.levels.ranges[0] = LevelRange(black: 10, gamma: 1.5, white: 240, outputBlack: 5, outputWhite: 250)
            adjustment.levels.ranges[1] = LevelRange(black: 0, gamma: 0.5, white: 255, outputBlack: 0, outputWhite: 255)
            adjustment.levels.ranges[3] = LevelRange(black: 20, gamma: 2.25, white: 200, outputBlack: 30, outputWhite: 220)
        case .curves:
            adjustment.curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 64, y: 40), CurvePoint(x: 192, y: 220),
                                             CurvePoint(x: 255, y: 255)]
            adjustment.curves.channels[2] = [CurvePoint(x: 0, y: 20), CurvePoint(x: 255, y: 235)]
        case .hsv:
            var settings = HueSaturationSettings(hue: 10, saturation: -20, lightness: 5)
            for range in ColorRange.colorRanges { settings.adjustments[range] = RangeAdjustment() }
            settings.adjustments[.reds] = RangeAdjustment(hue: 30, saturation: 15, lightness: -10)
            settings.adjustments[.blues] = RangeAdjustment(hue: -45, saturation: 0, lightness: 20)
            settings.bands[.greens] = HueBand(falloffStart: 80, rangeStart: 100, rangeEnd: 140, falloffEnd: 170)
            adjustment.hsvSettings = settings
        case .exposure:
            adjustment.exposure = ExposureSettings(exposure: 1.5, offset: -0.25, gamma: 0.5)
        case .colorBalance:
            adjustment.colorBalance = ColorBalanceSettings(
                shadowCyanRed: 10, shadowMagentaGreen: -20, shadowYellowBlue: 30, midCyanRed: -40, midMagentaGreen: 50,
                midYellowBlue: -60, highlightCyanRed: 70, highlightMagentaGreen: -80, highlightYellowBlue: 100,
                preserveLuminosity: false)
        case .blackWhite:
            adjustment.blackWhite = BlackWhiteSettings(reds: -50, yellows: 120, greens: 10, cyans: 250, blues: -200,
                                                       magentas: 300, tint: true, tintHue: 30, tintSaturation: 50)
        case .gradientMap:
            adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(red: 1, green: 0, blue: 0),
                                                         highlights: AdjustmentColor(red: 0, green: 0, blue: 1),
                                                         reversed: true)
        default:
            break
        }
        return adjustment
    }

    // MARK: Layers Photoshop never saw

    /// Every kind Photoshop has is written as an adjustment record (no pixels, empty channels, flags 0x18) whose first
    /// block is its settings, padded to 4 bytes, and reads back as the same settings.
    @Test(arguments: [AdjustmentKind.levels, .curves, .hsv, .exposure, .colorBalance, .invert, .blackWhite, .gradientMap])
    func everyKindPhotoshopHasReadsBackAsItWasWritten(kind: AdjustmentKind) throws {
        let adjustment = Self.sample(kind)
        let session = session([pixelLayer("Base", try patches()), adjustmentLayer(adjustment, name: "Adjustment")])
        let plan = try plan(session)
        #expect(plan.warnings.isEmpty)
        let written = try record("Adjustment", in: plan)
        #expect(written.rect == .zero && written.image == nil && written.channelIDs == [-1, 0, 1, 2] && written.flags == 0x18)
        #expect(written.blocks.first?.key == kind.psdKey && (written.blocks.first?.data.count ?? 1) % 4 == 0)
        #expect(written.blocks.filter { PSDReader.adjustmentKeys.contains($0.key) }.count == 1)

        let reopened = try reopened(session)
        #expect(reopened.conversions.allSatisfy { $0.layerName == "Adjustment" && !$0.message.contains("couldn’t be read") })
        let layer = try #require(reopened.layers.last)
        #expect(layer.name == "Adjustment" && layer.isVisible && !layer.isPhotoshopPlaceholder)
        let read = try #require(layer.adjustment)
        if kind == .blackWhite {
            // The tint goes through an RGB color, so its hue and saturation come back to within rounding.
            var tint = read.blackWhite
            #expect(abs(tint.tintHue - 30) < 1e-9 && abs(tint.tintSaturation - 50) < 1e-9)
            (tint.tintHue, tint.tintSaturation) = (30, 50)
            #expect(tint == adjustment.blackWhite)
        } else {
            #expect(read == adjustment)
        }
    }

    /// A layer's mask comes along as the record's user mask (-2), over the canvas.
    @Test func anAdjustmentLayersMaskIsWrittenWithIt() throws {
        var layer = adjustmentLayer(Self.sample(.levels), name: "Masked")
        let gray = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data((0..<64).map { $0 < 32 ? 255 : 0 }) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        layer.mask = LayerMask(asset: ImportedImage(image: gray, thumbnail: gray, name: "Layer Mask"), isEnabled: true,
                               placement: nil, isLinked: true)
        let written = try record("Masked", in: try plan(session([pixelLayer("Base", try patches()), layer])))
        #expect(written.channelIDs == [-1, 0, 1, 2, -2] && written.rect == .zero)
        #expect(written.mask?.rect == CGRect(origin: .zero, size: Self.canvas))
    }

    /// `levl`: version 2 and 29 records of `u16` input black, input white, output black, output white and gamma × 100:
    /// the composite, red, green and blue, then Photoshop's unused records at their defaults.
    @Test func levelsAreTwentyNineRecordsWithGammaTimesAHundred() throws {
        let levels = try block(of: Self.sample(.levels))
        let records = [[10, 240, 5, 250, 150], [0, 255, 0, 255, 50], [0, 255, 0, 255, 100], [20, 200, 30, 220, 225]]
            + Array(repeating: [0, 255, 0, 255, 100], count: 25)
        #expect(levels.key == "levl" && levels.data == Data(u16(2) + records.flatMap { $0.flatMap(u16) }))
    }

    /// `curv`: `u8 0 · u16 1 · u32` a bit for each of the four curves, each curve's points as `(output, input)`, then
    /// `Crv ` version 4 with each curve again after its channel index; padded to 4 bytes.
    @Test func curvesAreWrittenAsTheirCurvesThenCrv() throws {
        let written = try block(of: Self.sample(.curves))
        let curves: [[(x: Int, y: Int)]] = [[(0, 0), (64, 40), (192, 220), (255, 255)], [(0, 0), (255, 255)],
                                            [(0, 20), (255, 235)], [(0, 0), (255, 255)]]
        var expected: [UInt8] = [0] + u16(1) + u32(0x0F) + curves.flatMap(curve)
        expected += Array("Crv ".utf8) + u16(4) + u32(4)
        for (channel, points) in curves.enumerated() { expected += u16(channel) + curve(points) }
        #expect(written.key == "curv" && written.data == padded(expected))
    }

    /// Photoshop 2026 opens curves of at most 16 points (17 or more and it drops the adjustment): a longer curve is
    /// resampled evenly along Compositor's own curve, and the save says so.
    @Test func curvesWithMoreThanSixteenPointsAreResampledWithAWarning() throws {
        var adjustment = LayerAdjustment(kind: .curves)
        adjustment.curves.channels[1] = (0...24).map { index in
            let x = Double(index) * 255 / 24
            return CurvePoint(x: x, y: min(255, max(0, x + 20 * sin(x / 255 * 2 * .pi))))
        }
        // Sixteen points are written as they are.
        adjustment.curves.channels[2] = (0...15).map { CurvePoint(x: Double($0 * 17), y: Double(255 - $0 * 17)) }
        let session = session([pixelLayer("Base", try patches()), adjustmentLayer(adjustment, name: "Curves")])
        #expect(try plan(session).warnings == [PSDWriteWarning(layerName: "Curves",
            message: "Its Red curve has 25 points, more than the 16 Photoshop holds, so it was resampled to 16.", lossy: true)])
        let read = try #require(try reopened(session).layers.last?.adjustment?.curves)
        #expect(read.channels[1].map(\.x) == (0...15).map { Double($0 * 17) })
        #expect(read.channels[0] == adjustment.curves.channels[0] && read.channels[2] == adjustment.curves.channels[2])
        for x in stride(from: 0.0, through: 255, by: 5) {
            #expect(abs(read.value(x, channel: 1) - adjustment.curves.value(x, channel: 1)) <= 3)
        }
    }

    /// `hue2`: version 2, Colorize, the colorization values and Master, then each range's band and values. Without
    /// Colorize the colorization is Photoshop's starting one (0, 25, 0); with it, Master is 0 and the colorization is
    /// what Compositor shows as Master.
    @Test func hueSaturationIsWrittenWithEachRangesBandAndValues() throws {
        let hue = try block(of: Self.sample(.hsv))
        var expected = u16(2) + [0, 0] + [0, 25, 0].flatMap(i16) + [10, -20, 5].flatMap(i16)
        let bands: [ColorRange: [Int]] = [.reds: [315, 345, 15, 45], .yellows: [15, 45, 75, 105], .greens: [80, 100, 140, 170],
                                          .cyans: [135, 165, 195, 225], .blues: [195, 225, 255, 285],
                                          .magentas: [255, 285, 315, 345]]
        let values: [ColorRange: [Int]] = [.reds: [30, 15, -10], .blues: [-45, 0, 20]]
        for range in ColorRange.colorRanges {
            expected += (bands[range] ?? []).flatMap(i16) + (values[range] ?? [0, 0, 0]).flatMap(i16)
        }
        #expect(hue.key == "hue2" && hue.data == Data(expected))

        let colorized = LayerAdjustment(kind: .hsv, hsvSettings: HueSaturationSettings(hue: 200, saturation: 40, lightness: -10,
                                                                                       colorize: true))
        let header: [UInt8] = u16(2) + [1, 0] + [200, 40, -10].flatMap(i16) + [0, 0, 0].flatMap(i16)
        #expect(Array(try block(of: colorized).data.prefix(16)) == header)

        // Photoshop's colorization saturation is 0…100: a negative one is written as 0.
        let greyed = LayerAdjustment(kind: .hsv, hsvSettings: HueSaturationSettings(hue: 200, saturation: -40, lightness: -10,
                                                                                    colorize: true))
        #expect(Array(try block(of: greyed).data.prefix(10)) == u16(2) + [1, 0] + [200, 0, -10].flatMap(i16))

        // A hue is a turn: 300° is written as Photoshop's −60°.
        let turned = LayerAdjustment(kind: .hsv, hsvSettings: HueSaturationSettings(hue: 300, saturation: 0, lightness: 0))
        #expect(Array(try block(of: turned).data[10..<12]) == i16(-60))
    }

    /// Photoshop has no color range applied outside its band: the file applies it inside, and the save says so.
    @Test func anInvertedColorRangeIsWrittenInsideItsBandWithAWarning() throws {
        var settings = HueSaturationSettings()
        settings.range = .blues
        settings.invertRange = true
        settings.adjustments[.blues] = RangeAdjustment(hue: 40, saturation: 0, lightness: 0)
        let layer = adjustmentLayer(LayerAdjustment(kind: .hsv, hsvSettings: settings), name: "Hue")
        #expect(try plan(session([pixelLayer("Base", try patches()), layer])).warnings == [PSDWriteWarning(layerName: "Hue",
            message: "Photoshop can’t apply a color range outside its band, so the file applies the Blues settings inside it.")])
    }

    /// `expA` is version 1 and three `f32`; `blnc` nine `i16` and Preserve Luminosity; `nvrt` is empty.
    @Test func exposureColorBalanceAndInvertAreWrittenAsTheirBlocks() throws {
        let exposure = try block(of: Self.sample(.exposure))
        #expect(exposure.key == "expA" && exposure.data == padded(u16(1) + f32(1.5) + f32(-0.25) + f32(0.5)))
        #expect(exposure.data.count == 16)
        let balance = try block(of: Self.sample(.colorBalance))
        #expect(balance.key == "blnc" && balance.data == padded([10, -20, 30, -40, 50, -60, 70, -80, 100].flatMap(i16) + [0]))
        #expect(balance.data.count == 20)
        let invert = try block(of: LayerAdjustment(kind: .invert))
        #expect(invert.key == "nvrt" && invert.data.isEmpty)
    }

    /// `blwh`: `u32 16` and a descriptor of each color's percentage as a `long`, `useTint`, the tint as an `RGBC` color
    /// at full brightness, and Photoshop's preset fields: kind 1 (Default) at Photoshop's defaults, else 2 (Custom), as
    /// Photoshop 2026 reads them.
    @Test func blackAndWhiteIsWrittenAsItsDescriptor() throws {
        let blackWhite = try block(of: Self.sample(.blackWhite))
        #expect(blackWhite.key == "blwh" && blackWhite.data.count % 4 == 0)
        var offset = 0
        let descriptor = try PSDDescriptorReader.readBlock(blackWhite.data, at: &offset)
        #expect(blackWhite.data[offset...].allSatisfy { $0 == 0 })
        #expect(descriptor.classID.id == "null")
        #expect(descriptor.items.map(\.key.id) == ["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt", "useTint", "tintColor",
                                                   "bwPresetKind", "blackAndWhitePresetFileName"])
        #expect(["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"].map { descriptor[$0] }
                == [-50, 120, 10, 250, -200, 300].map { PSDDescriptorValue.integer($0) })
        #expect(descriptor["useTint"] == .bool(true) && descriptor["bwPresetKind"] == .integer(2)
                && descriptor["blackAndWhitePresetFileName"] == .string(""))
        var plain = LayerAdjustment(kind: .blackWhite)
        plain.blackWhite = BlackWhiteSettings()
        var defaultOffset = 0
        #expect(try PSDDescriptorReader.readBlock(try block(of: plain).data, at: &defaultOffset)["bwPresetKind"] == .integer(1))
        // Hue 30°, saturation 50% at full brightness.
        #expect(descriptor.object("tintColor")?.classID.id == "RGBC")
        let tint = try #require(descriptor.rgb("tintColor"))
        #expect(abs(tint.r - 255) < 1e-9 && abs(tint.g - 191.25) < 1e-9 && abs(tint.b - 127.5) < 1e-9)
    }

    /// `grdm`: version 1 (Classic), a two-stop gradient from the shadows color to the highlights color, opaque, with
    /// the fixed fields Photoshop writes after the stops; smoothness 0, the straight ramp Compositor draws.
    @Test func gradientMapIsWrittenAsATwoStopGradient() throws {
        let gradient = try block(of: Self.sample(.gradientMap))
        let name = Array("Custom".utf16)
        var expected = u16(1) + [1, 0] + u32(name.count) + name.flatMap { u16(Int($0)) } + u16(2)
        for (location, color) in [(0, [65535, 0, 0]), (4096, [0, 0, 65535])] {
            expected += u32(location) + u32(50) + u16(0) + (color + [0]).flatMap(u16) + u16(0)
        }
        expected += u16(2) + [0, 4096].flatMap { u32($0) + u32(50) + u16(255) }
        expected += [2, 0, 32, 0].flatMap(u16) + u32(0) + u16(0) + u16(0) + u32(2048) + u16(3)
            + [0, 0, 0, 0].flatMap(u16) + [100, 100, 100, 100].flatMap(u16) + u16(0)
        #expect(gradient.key == "grdm" && gradient.data == padded(expected))
    }

    // MARK: Layers the document was opened with

    /// An imported adjustment whose settings are what import made of its block writes that block back unchanged,
    /// whatever its padding or the fields Compositor doesn't read.
    @Test func untouchedImportedAdjustmentsKeepTheirBlocksByteForByte() throws {
        var levels = Data(u16(2))
        for index in 0..<29 { levels += Data([index, 250 - index, index % 3, 255, 100 + index].flatMap(u16)) }
        let curves = Data([0] + u16(1) + u32(0b0101) + curve([(0, 0), (128, 160), (255, 255)]) + curve([(0, 10), (255, 240)])
            + Array("Crv ".utf8) + u16(4) + u32(2) + u16(0) + curve([(0, 0), (128, 160), (255, 255)])
            + u16(2) + curve([(0, 10), (255, 240)]))
        let blocks: [(key: String, data: Data)] = [
            ("levl", levels), ("curv", curves),
            ("hue2", hueBlock(colorize: false, colorization: [40, 60, -10], master: [10, -20, 5])),
            ("expA", PSDFixture.exposureBlock(exposure: 0.5, offset: 0.05, gamma: 1.5)),
            ("blnc", PSDFixture.colorBalanceBlock(shadows: [1, 2, 3], midtones: [4, 5, 6], highlights: [7, 8, 9],
                                                  preserveLuminosity: true)),
            ("nvrt", Data()),
            ("blwh", PSDFixture.blackWhiteBlock(reds: 40, yellows: 60, greens: 40, cyans: 60, blues: 20, magentas: 80,
                                                tint: true, tintColor: (225, 211, 179))),
            ("grdm", PSDFixture.gradientMapBlock(stops: [(0, (65535, 0, 0)), (2048, (0, 65535, 0)), (4096, (0, 0, 65535))],
                                                 version: 3, method: "Perc")),
        ]
        let session = try opened(blocks.map { adjustmentRecord($0.key, $0.key, $0.data) })
        #expect(session.document?.layers.filter { $0.adjustment != nil }.count == blocks.count)
        let plan = try plan(session)
        #expect(plan.warnings.isEmpty)
        for (key, data) in blocks {
            #expect(try record(key, in: plan).blocks.filter { PSDReader.adjustmentKeys.contains($0.key) }
                    == [PSDTaggedBlock(key: key, data: data)])
        }
    }

    /// An edited Levels layer rewrites its four channels' records and keeps the rest of its block as the file had it.
    @Test func anEditedLevelsLayerKeepsTheRestOfItsBlock() throws {
        var levels = Data(u16(2))
        for index in 0..<29 { levels += Data([index, 250 - index, index % 3, 255, 100 + index].flatMap(u16)) }
        let session = try opened([adjustmentRecord("Levels", "levl", levels)])
        let index = try index(of: "Levels", in: session)
        session.document?.layers[index].adjustment?.levels.ranges[0].gamma = 2
        session.document?.layers[index].adjustment?.levels.ranges[2].white = 200
        var expected = levels
        expected.replaceSubrange(10..<12, with: u16(200))
        expected.replaceSubrange(24..<26, with: u16(200))
        #expect(try record("Levels", in: try plan(session)).blocks.first { $0.key == "levl" }?.data == expected)
    }

    /// Photoshop keeps Master and the colorization apart; Compositor shows one of them as Master, so an edit rewrites
    /// that one and keeps the other as the file had it.
    @Test(arguments: [false, true])
    func anEditedHueSaturationLayerKeepsTheHalfItDoesntShow(colorize: Bool) throws {
        let hue = hueBlock(colorize: colorize, colorization: [40, 60, -10], master: [10, -20, 5])
        let session = try opened([adjustmentRecord("Hue", "hue2", hue)])
        let index = try index(of: "Hue", in: session)
        session.document?.layers[index].adjustment?.hsvSettings?.adjustments[.master]?.hue = 25
        var expected = hue
        expected.replaceSubrange(colorize ? 4..<6 : 10..<12, with: i16(25))
        #expect(try record("Hue", in: try plan(session)).blocks.first { $0.key == "hue2" }?.data == expected)
    }

    /// Photoshop 4's `hue ` has the `hue2` layout; edited, it is written as `hue2` where it was.
    @Test func anEditedPhotoshop4HueSaturationBecomesHue2() throws {
        let hue = hueBlock(colorize: false, colorization: [0, 25, 0], master: [10, -20, 5])
        let session = try opened([adjustmentRecord("Hue", "hue ", hue)])
        let index = try index(of: "Hue", in: session)
        session.document?.layers[index].adjustment?.hsvSettings?.adjustments[.master]?.lightness = -30
        var expected = hue
        expected.replaceSubrange(14..<16, with: i16(-30))
        let original = try #require(session.document?.layers[index].psdExtras?.blocks.map(\.key))
        let blocks = try record("Hue", in: try plan(session)).blocks
        // In its place (the writer adds only the layer ID).
        #expect(blocks.map(\.key).filter { $0 != "lyid" } == original.map { $0 == "hue " ? "hue2" : $0 })
        #expect(blocks.first { $0.key == "hue2" }?.data == expected)
    }

    /// An edited Gradient Map changes the ends of the file's own gradient, keeping its method, name and the stops
    /// between them.
    @Test func anEditedGradientMapChangesTheEndsOfTheFilesGradient() throws {
        let gradient = PSDFixture.gradientMapBlock(stops: [(0, (65535, 0, 0)), (2048, (0, 65535, 0)), (4096, (0, 0, 65535))],
                                                   version: 3, method: "Perc")
        let session = try opened([adjustmentRecord("Gradient", "grdm", gradient)])
        let index = try index(of: "Gradient", in: session)
        session.document?.layers[index].adjustment?.gradientMap.highlights = AdjustmentColor(red: 1, green: 1, blue: 0)
        session.document?.layers[index].adjustment?.gradientMap.reversed = true
        // Header and method (8 bytes), the name "Custom" (4 + 12), the stop count (2), then 20-byte stops.
        var expected = gradient
        expected[2] = 1
        expected.replaceSubrange(76..<82, with: [65535, 65535, 0].flatMap(u16))
        #expect(try record("Gradient", in: try plan(session)).blocks.first { $0.key == "grdm" }?.data == expected)
    }

    /// An edited Black & White changes its values in the file's own descriptor, and is a Custom preset now (kind 2, no
    /// preset file); the tint color stays as the file had it until the tint's hue or saturation changes.
    @Test func anEditedBlackAndWhiteChangesItsValuesInTheFilesDescriptor() throws {
        let original = PSDFixture.blackWhiteBlock(reds: 40, yellows: 60, greens: 40, cyans: 60, blues: 20, magentas: 80,
                                                  tint: true, tintColor: (225, 211, 179))
        let session = try opened([adjustmentRecord("B&W", "blwh", original)])
        let index = try index(of: "B&W", in: session)
        func written() throws -> PSDDescriptor {
            let data = try #require(try record("B&W", in: try plan(session)).blocks.first { $0.key == "blwh" }?.data)
            var offset = 0
            return try PSDDescriptorReader.readBlock(data, at: &offset)
        }
        var offset = 0
        var expected = try PSDDescriptorReader.readBlock(original, at: &offset)
        session.document?.layers[index].adjustment?.blackWhite.reds = -30
        expected.items[0].value = .integer(-30)
        let kind = try #require(expected.items.firstIndex { $0.key.id == "bwPresetKind" })
        expected.items[kind].value = .integer(2)
        #expect(try written() == expected)

        session.document?.layers[index].adjustment?.blackWhite.tintHue = 200
        let tint = try #require(try written().rgb("tintColor"))
        // Hue 200°, the file's saturation (46 / 225) at full brightness.
        #expect(abs(tint.r - 255 * (1 - 46.0 / 225)) < 1e-9 && abs(tint.b - 255) < 1e-9)
        #expect(abs(tint.g - (255 - 255 * 46.0 / 225 / 3)) < 1e-9)
    }

    /// A Black & White from a preset file (kind 3 and its file name), edited, no longer is that preset.
    @Test func anEditedBlackAndWhitePresetIsCustom() throws {
        var offset = 0
        var preset = try PSDDescriptorReader.readBlock(PSDFixture.blackWhiteBlock(
            reds: 10, yellows: 60, greens: 40, cyans: 60, blues: 20, magentas: 80, tint: false, tintColor: (225, 211, 179)), at: &offset)
        preset.items = preset.items.map { item in
            switch item.key.id {
            case "bwPresetKind": (key: item.key, value: .integer(3))
            case "blackAndWhitePresetFileName": (key: item.key, value: .string("Sepia.blw"))
            default: item
            }
        }
        let session = try opened([adjustmentRecord("B&W", "blwh", padded(Array(PSDDescriptorWriter.block(preset))))])
        let index = try index(of: "B&W", in: session)
        session.document?.layers[index].adjustment?.blackWhite.greens = 55
        let data = try #require(try record("B&W", in: try plan(session)).blocks.first { $0.key == "blwh" }?.data)
        offset = 0
        let written = try PSDDescriptorReader.readBlock(data, at: &offset)
        #expect(written["bwPresetKind"] == .integer(2) && written["blackAndWhitePresetFileName"] == .string(""))
    }

    /// An adjustment's vector mask (`vmsk`, which Photoshop adds while a path is active) confines it in Photoshop, and
    /// holds fractions of the file's canvas; Compositor keeps it without drawing it. While the canvas is the file's it
    /// is written back byte for byte, with the record's 0x10 flag and no warning, a project round trip included. After
    /// Flip Canvas or Canvas Size it would confine the adjustment somewhere else, so it is left out (lossy, one warning
    /// a layer) and the flag stays. A placeholder (Brightness/Contrast, which Compositor can't apply) is treated alike.
    @Test func anAdjustmentsVectorMaskIsKeptWhileTheCanvasIsTheFiles() async throws {
        let vmsk = PSDFixture.vectorPathBlock(canvas: Self.canvas,
                                              subpaths: [PSDFixture.turnedCorners(of: CGRect(x: 2, y: 2, width: 4, height: 4), degrees: 0)])
        var levels = Data(u16(2))
        for index in 0..<29 { levels += Data([index, 250 - index, index % 3, 255, 100 + index].flatMap(u16)) }
        func masked(_ name: String, _ key: String, _ data: Data) -> PSDRecord {
            var record = adjustmentRecord(name, key, data)
            record.extras?.blocks.append(PSDTaggedBlock(key: "vmsk", data: vmsk))
            record.extras?.flags = 0x18
            return record
        }
        let session = try opened([masked("Levels", "levl", levels), masked("Brightness", "brit", Data([0, 20, 0, 10, 0, 127, 0, 0]))])
        let (levelsIndex, brightnessIndex) = (try index(of: "Levels", in: session), try index(of: "Brightness", in: session))
        #expect(session.document?.layers[levelsIndex].adjustment != nil)
        #expect(session.document?.layers[brightnessIndex].psdExtras?.placeholder == "adjustment:brit")
        func check(_ session: EditorSession, keeps: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let plan = try plan(session)
            for name in ["Levels", "Brightness"] {
                let written = try record(name, in: plan)
                #expect(written.blocks.filter { $0.key == "vmsk" }.map(\.data) == (keeps ? [vmsk] : []), sourceLocation: sourceLocation)
                #expect(written.flags & 0x10 != 0, sourceLocation: sourceLocation)
            }
            #expect(!plan.warnings.contains { $0.layerName == "Levels" && !$0.lossy }, sourceLocation: sourceLocation)
            #expect(plan.warnings.filter(\.lossy).map(\.layerName).sorted() == (keeps ? [] : ["Brightness", "Levels"]),
                    sourceLocation: sourceLocation)
        }
        try check(session, keeps: true)
        session.flipCanvas(horizontally: true)
        try check(session, keeps: false)
        session.flipCanvas(horizontally: true)
        try check(session, keeps: true)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDAdjustmentWriterTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Masked.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        try check(reopened, keeps: true)

        let resized = try await CanvasResizer.shared.resize(try #require(reopened.projectSnapshot()),
                                                            to: CanvasSizeOptions(width: 10, height: 8, anchor: 0))
        reopened.applyDocumentSize(resized, actionName: "Canvas Size")
        try check(reopened, keeps: false)
    }

    /// A fill layer (Solid Color, Gradient or Pattern) without a vector mask, which Compositor keeps only to write
    /// back, fills whatever canvas it is on: unlike a vector mask (`vmsk`, `vsms`, `vogk`), its block holds no place
    /// on the file's canvas. So Flip Canvas, Canvas Size, or a copy into a project of another size leave it byte for
    /// byte, with no lossy warning (only the merged image's note that Compositor doesn't draw it).
    @Test(arguments: ["SoCo", "GdFl", "PtFl"])
    func aFillLayerKeepsItsFillWhereverTheCanvasGoes(key: String) async throws {
        // Compositor keeps a fill block without reading it, so the solid color's descriptor stands in for all three.
        let fill = try #require(PSDVectorFixtures.rectangle()["SoCo"])
        var fillRecord = PSDRecord(id: UUID(), name: "Fill")
        fillRecord.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: key, data: fill)])
        let workspace = ProjectWorkspace()
        let session = try opened([fillRecord], into: workspace.current.session)
        let fillID = try #require(session.document?.layers.first { $0.name == "Fill" }?.id)
        let imported = session.document?.layers[try index(of: "Fill", in: session)].psdExtras
        // No vector mask, so no place on the file's canvas for import to record.
        #expect(imported?.placeholder == "fill:\(key)" && imported?.importedShapeCanvas == nil)
        func check(_ session: EditorSession, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let plan = try plan(session)
            #expect(try record("Fill", in: plan).blocks.filter { $0.key == key }.map(\.data) == [fill],
                    sourceLocation: sourceLocation)
            #expect(plan.warnings.map(\.layerName) == ["Fill"] && plan.warnings.map(\.lossy) == [false],
                    sourceLocation: sourceLocation)
        }
        try check(session)
        session.flipCanvas(horizontally: true)
        try check(session)
        let resized = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
                                                            to: CanvasSizeOptions(width: 10, height: 8, anchor: 0))
        session.applyDocumentSize(resized, actionName: "Canvas Size")
        try check(session)

        let target = workspace.addTab()
        target.session.createDocument(width: 12, height: 6)
        await workspace.copyLayer(fillID, into: target.id)
        #expect(target.session.document?.layers.map(\.name) == ["Fill"])
        try check(target.session)
    }

    // MARK: Kinds Photoshop lacks

    /// Every kind is either one Photoshop has, written as its adjustment block, or one it lacks, rasterized: the kinds
    /// the tests above and below take cover them all, so a new kind has to be placed in one group.
    @Test func everyKindIsWrittenAsAnAdjustmentOrRasterized() {
        let photoshop: Set<AdjustmentKind> = [.levels, .curves, .hsv, .exposure, .colorBalance, .invert, .blackWhite, .gradientMap]
        let compositorOnly: Set<AdjustmentKind> = [.grain, .gaussianBlur, .motionBlur, .addNoise, .profile]
        #expect(photoshop.isDisjoint(with: compositorOnly) && photoshop.union(compositorOnly) == Set(AdjustmentKind.allCases))
        #expect(Set(AdjustmentKind.allCases.filter { $0.psdKey == nil }) == compositorOnly)
    }

    /// Grain, Gaussian Blur, Motion Blur, Add Noise and Profile have no Photoshop adjustment layer: the document is
    /// refused unless a lossy save is allowed, which writes a pixel layer of the result instead and says so.
    @Test(arguments: [AdjustmentKind.grain, .gaussianBlur, .motionBlur, .addNoise, .profile])
    func kindsPhotoshopLacksAreRefusedUnlessALossySaveIsAllowed(kind: AdjustmentKind) throws {
        #expect(kind.psdKey == nil)
        let session = session([pixelLayer("Base", try patches()), adjustmentLayer(LayerAdjustment(kind: kind), name: "Effect")])
        let request = try #require(session.psdWriteRequest())
        #expect(throws: PSDWriteError.unsupportedAdjustment(layerName: "Effect", kind: kind)) {
            try PSDWriter.data(for: request)
        }
        let lossy = PSDWriteOptions(allowLossy: true)
        let written = try PSDWriter.data(for: request, options: lossy)
        #expect(written.report.warnings == [PSDWriteWarning(layerName: "Effect",
            message: "Photoshop has no \(kind.rawValue) adjustment, so it was saved as “Effect (rasterized)”, a pixel layer of its result on the layers below.",
            lossy: true)])
        let reopened = try PSDDocumentBuilder.makeImport(try PSDReader.read(written.data))
        let layer = try #require(reopened.layers.last)
        #expect(layer.name == "Effect (rasterized)" && layer.adjustment == nil && layer.asset != nil
                && !layer.isPhotoshopPlaceholder)
    }

    /// The rasterized layer stays where the adjustment was, inside its folder, and holds exactly what Compositor shows
    /// there: the adjustment applied to everything drawn below it (folders pass through), at the adjustment's opacity
    /// and blend in the record.
    @Test func aRasterizedAdjustmentHoldsItsResultWhereItWas() throws {
        let folderID = UUID()
        let folder = ImageLayer(id: folderID, asset: nil, name: "Folder", isVisible: true,
                                transform: LayerTransform(origin: .zero, size: Self.canvas), isGroup: true)
        var grain = LayerAdjustment(kind: .grain)
        grain.grain = GrainSettings(amount: 80, size: 1, roughness: 60, seed: 7)
        let inner = try image(2, 2, Array(repeating: [0, 200, 0, 255], count: 4).flatMap { $0 })
        var adjustment = adjustmentLayer(grain, name: "Grain", parent: folderID)
        adjustment.opacity = 0.5
        adjustment.blendMode = .multiply
        let session = session([pixelLayer("Base", try patches()), folder, pixelLayer("Inner", inner, parent: folderID),
                               adjustment])
        let request = try #require(session.psdWriteRequest())
        let plan = try PSDLayerRecordWriter.plan(request, options: PSDWriteOptions(allowLossy: true))
        #expect(plan.records.map(\.name) == ["Base", "</Layer group>", "Inner", "Grain (rasterized)", "Folder"])
        let written = try record("Grain (rasterized)", in: plan)
        #expect(written.sourceID == adjustment.id && written.flags & 0x10 == 0 && written.channelIDs == [-1, 0, 1, 2])
        #expect(written.rect == CGRect(origin: .zero, size: Self.canvas) && written.opacity == 128 && written.blendKey == "mul ")

        var below = request.snapshot.manifest
        below.layers.removeAll { $0.id == adjustment.id }
        let backdrop = try ImageExporter.composite(ProjectSnapshot(manifest: below, images: request.snapshot.images)).image
        let expected = try grain.apply(backdrop, region: CGRect(origin: .zero, size: Self.canvas))
        #expect(try premultiplied(try #require(written.image)) == premultiplied(expected))
    }

    /// A clipped adjustment Photoshop lacks is rasterized clipped to the same base.
    @Test func aRasterizedClippedAdjustmentStaysClipped() throws {
        let base = pixelLayer("Base", try patches())
        var blur = adjustmentLayer(LayerAdjustment(kind: .gaussianBlur), name: "Blur")
        blur.maskSourceID = base.id
        let plan = try plan(session([base, blur]), PSDWriteOptions(allowLossy: true))
        #expect(try record("Blur (rasterized)", in: plan).clipping == 1)
    }

    /// In a clipping stack Compositor applies an adjustment to the stack alone: the base, at normal blend and full
    /// opacity, its color divided by its alpha (black where it has none), and the layers stacked before the
    /// adjustment, drawn over it. The layers below the base never enter; the base's alpha, blend and opacity apply to
    /// the whole stack afterwards. Photoshop does the same with the clipped pixel layer, so the layer holds that
    /// result, opaque wherever the base has any pixels and empty elsewhere. Rasterized from the composite below, a
    /// Multiply base at 50% would be multiplied in twice, its backdrop would show through, and the blur would pull the
    /// backdrop into the base's edge. A hidden adjustment holds what showing it would draw.
    @Test(arguments: [true, false])
    func aRasterizedClippedAdjustmentHoldsItsResultOnItsStackAlone(visible: Bool) throws {
        func inBase(_ x: Int, _ y: Int) -> Bool { (1..<7).contains(x) && (1..<7).contains(y) }
        func inPaint(_ x: Int, _ y: Int) -> Bool { (3..<5).contains(x) && (3..<5).contains(y) }
        // A 6×6 yellow base with a soft (half-alpha) rim, Multiply at 50%, over the patches; a green patch clipped
        // to it; then the blur, clipped to it too.
        var square: [UInt8] = []
        for y in 0..<6 {
            for x in 0..<6 { square += (1..<5).contains(x) && (1..<5).contains(y) ? [255, 255, 0, 255] : [128, 128, 0, 128] }
        }
        var base = pixelLayer("Base", try image(6, 6, square))
        base.transform = LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 6, height: 6))
        base.blendMode = .multiply
        base.opacity = 0.5
        var paint = pixelLayer("Paint", try image(2, 2, Array(repeating: [0, 255, 0, 255], count: 4).flatMap { $0 }))
        paint.transform = LayerTransform(origin: CGPoint(x: 3, y: 3), size: CGSize(width: 2, height: 2))
        paint.maskSourceID = base.id
        var settings = LayerAdjustment(kind: .gaussianBlur)
        settings.gaussianRadius = 1
        var blur = adjustmentLayer(settings, name: "Blur")
        blur.maskSourceID = base.id
        blur.isVisible = visible
        let request = try #require(session([pixelLayer("Backdrop", try patches()), base, paint, blur]).psdWriteRequest())
        let plan = try PSDLayerRecordWriter.plan(request, options: PSDWriteOptions(allowLossy: true))
        let written = try record("Blur (rasterized)", in: plan)
        #expect(written.clipping == 1 && written.rect == CGRect(origin: .zero, size: Self.canvas))

        var stack: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 { stack += inPaint(x, y) ? [0, 255, 0, 255] : inBase(x, y) ? [255, 255, 0, 255] : [0, 0, 0, 255] }
        }
        let blurred = try premultiplied(try settings.apply(try image(8, 8, stack), region: CGRect(origin: .zero, size: Self.canvas)))
        let expected = (0..<64).flatMap { index -> [UInt8] in
            inBase(index % 8, index / 8) ? Array(blurred[index * 4 ..< index * 4 + 3]) + [255] : [0, 0, 0, 0]
        }
        #expect(try premultiplied(try #require(written.image)) == expected)

        // Clipped to its base, the pixel layer draws as the adjustment did.
        let rasterized = try PSDAdjustmentWriter.rasterizingUnwritable(request.snapshot, allowLossy: true).snapshot
        #expect(try premultiplied(try ImageExporter.composite(rasterized).image)
                == premultiplied(try ImageExporter.composite(request.snapshot).image))
    }

    /// In a folder, Compositor's stack is drawn with the folder's opacity in the base's alpha and in each stacked
    /// layer's, the adjustment's included; the rasterized layer, clipped to the base in the same folder, draws as the
    /// adjustment did.
    @Test func aRasterizedClippedAdjustmentInAFolderDrawsAsTheAdjustmentDid() throws {
        let folderID = UUID()
        let folder = ImageLayer(id: folderID, asset: nil, name: "Folder", isVisible: true,
                                transform: LayerTransform(origin: .zero, size: Self.canvas), isGroup: true, opacity: 0.5)
        var base = pixelLayer("Base", try image(4, 4, Array(repeating: [255, 255, 0, 255], count: 16).flatMap { $0 }),
                              parent: folderID)
        base.transform = LayerTransform(origin: CGPoint(x: 2, y: 2), size: CGSize(width: 4, height: 4))
        base.blendMode = .multiply
        base.opacity = 0.5
        var paint = pixelLayer("Paint", try image(2, 2, Array(repeating: [0, 255, 0, 255], count: 4).flatMap { $0 }),
                               parent: folderID)
        paint.transform = LayerTransform(origin: CGPoint(x: 3, y: 3), size: CGSize(width: 2, height: 2))
        paint.maskSourceID = base.id
        paint.opacity = 0.8
        var settings = LayerAdjustment(kind: .motionBlur)
        settings.resolvedMotionDistance = 3
        var blur = adjustmentLayer(settings, name: "Blur", parent: folderID)
        blur.maskSourceID = base.id
        let request = try #require(session([pixelLayer("Backdrop", try patches()), folder, base, paint, blur]).psdWriteRequest())
        let plan = try PSDLayerRecordWriter.plan(request, options: PSDWriteOptions(allowLossy: true))
        #expect(try record("Blur (rasterized)", in: plan).clipping == 1)
        let rasterized = try PSDAdjustmentWriter.rasterizingUnwritable(request.snapshot, allowLossy: true).snapshot
        #expect(try premultiplied(try ImageExporter.composite(rasterized).image)
                == premultiplied(try ImageExporter.composite(request.snapshot).image))
    }

    // MARK: The merged image

    /// A placeholder Photoshop shows (an adjustment or fill Compositor can't draw) is missing from the merged image,
    /// which Compositor renders; the save says so. One Photoshop hides isn't.
    @Test func aShownPlaceholderIsNotedAsMissingFromTheMergedImage() throws {
        var hidden = adjustmentRecord("Hidden", "brit", Data(count: 8))
        hidden.isVisible = false
        let session = try opened([adjustmentRecord("Brightness", "brit", Data(count: 8)), hidden])
        #expect(session.document?.layers.filter(\.isPhotoshopPlaceholder).count == 2)
        #expect(try plan(session).warnings == [PSDWriteWarning(layerName: "Brightness",
            message: "Compositor can’t draw this Photoshop layer, so the file’s merged image, which apps without layers show, leaves it out. Photoshop draws it from the layer.")])
    }
}
