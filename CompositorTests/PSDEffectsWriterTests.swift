import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Layer effects written as Photoshop's `lfx2` (Task 4.5): fresh for layers Photoshop never saw, byte for byte for
/// imported layers whose effects are untouched, and rewritten inside the file's own descriptor once edited.
@MainActor
@Suite(.serialized)
struct PSDEffectsWriterTests {
    // MARK: Fixtures

    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        return try #require(context.makeImage())
    }

    private func pixelLayer(_ name: String, _ image: CGImage, size: CGSize? = nil, effects: LayerEffects? = nil) -> ImageLayer {
        var layer = ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: name), name: name,
                               isVisible: true, transform: LayerTransform(origin: CGPoint(x: 8, y: 8),
                                   size: size ?? CGSize(width: image.width, height: image.height)))
        layer.effects = effects
        return layer
    }

    private func session(_ layers: [ImageLayer]) -> EditorSession {
        let session = EditorSession()
        session.document = CanvasDocument(width: 96, height: 96, layers: layers)
        session.activeLayerID = layers.last?.id
        return session
    }

    /// A pixel layer as Photoshop stored it, with `blocks`.
    private func raster(_ name: String, _ blocks: [PSDTaggedBlock]) throws -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        record.bounds = CGRect(x: 20, y: 16, width: 24, height: 24)
        record.image = try image(24, 24)
        record.extras = PSDLayerExtras(blocks: blocks)
        return record
    }

    /// A session holding `records` as Photoshop wrote them, opened as the app opens a PSD.
    private func opened(_ records: [PSDRecord], resources: [PSDImageResource] = []) throws -> EditorSession {
        var document = PSDDocument(width: 64, height: 64, resolution: 72, layers: records)
        document.extras = PSDDocumentExtras(resources: resources)
        let data = try PSDFixture.data(document, composite: try image(64, 64))
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        return session
    }

    private func planned(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws -> [PSDLayerRecord] {
        try PSDLayerRecordWriter.plan(try #require(session.psdWriteRequest()), options: options).records
    }

    private func record(_ name: String, in records: [PSDLayerRecord]) throws -> PSDLayerRecord {
        try #require(records.first { $0.name == name })
    }

    private func index(of name: String, in session: EditorSession) throws -> Int {
        try #require(session.document?.layers.firstIndex { $0.name == name })
    }

    /// The `lfx2` descriptor, after its `u32` version.
    private func descriptor(_ lfx2: Data?) throws -> PSDDescriptor {
        let data = try #require(lfx2)
        var offset = 4
        return try PSDDescriptorReader.readBlock(data, at: &offset)
    }

    private func version(_ lfx2: Data) -> UInt32 { lfx2.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    /// Each item as `key:type`, enumerations and objects with their type or class.
    private func signature(_ descriptor: PSDDescriptor) -> [String] {
        descriptor.items.map { item in
            let type = switch item.value {
            case .object(let object): "Objc(\(object.classID.id))"
            case .unitFloat(let unit, _): "UntF(\(unit))"
            case .enumerated(let type, _): "enum(\(type.id))"
            case .bool: "bool"
            case .integer: "long"
            case .double: "doub"
            case .string: "TEXT"
            case .list: "VlLs"
            default: "other"
            }
            return "\(item.key.id):\(type)"
        }
    }

    /// Every key and class ID in `descriptor`, nested ones included, has the length form Photoshop gives it: four
    /// characters as a charID (length 0), anything else with its length.
    private func photoshopKeyForms(_ descriptor: PSDDescriptor) -> Bool {
        func check(_ value: PSDDescriptorValue) -> Bool {
            switch value {
            case .object(let object): photoshopKeyForms(object)
            case .list(let values): values.allSatisfy(check)
            case .enumerated(let type, let value): !type.explicitLength && !value.explicitLength
            default: true
            }
        }
        return descriptor.classID.explicitLength == (descriptor.classID.id.count != 4)
            && descriptor.items.allSatisfy { $0.key.explicitLength == ($0.key.id.count != 4) && check($0.value) }
    }

    private func number(_ descriptor: PSDDescriptor?, _ key: String) -> Double? {
        switch descriptor?[key] {
        case .unitFloat(_, let value)?, .double(let value)?: value
        case .integer(let value)?: Double(value)
        default: nil
        }
    }

    private func entries(_ descriptor: PSDDescriptor, _ key: String) -> [PSDDescriptor] {
        (descriptor.list(key) ?? []).compactMap(object)
    }

    /// `descriptor` with the values of `changes` in place of its own.
    private func replacing(_ descriptor: PSDDescriptor?, _ changes: [(key: String, value: PSDDescriptorValue)]) throws -> PSDDescriptor {
        var result = try #require(descriptor)
        for change in changes {
            let index = try #require(result.items.firstIndex { $0.key.id == change.key })
            result.items[index].value = change.value
        }
        return result
    }

    /// The object `value` holds.
    private func object(_ value: PSDDescriptorValue) -> PSDDescriptor? {
        if case .object(let object) = value { object } else { nil }
    }

    private let common = ["enab:bool", "present:bool", "showInDialog:bool", "Md  :enum(BlnM)", "Clr :Objc(RGBC)",
                          "Opct:UntF(#Prc)"]

    private var everyKind: LayerEffects {
        LayerEffects(
            stroke: StrokeEffect(enabled: true, size: 3, red: 0, green: 0.5, blue: 1, opacity: 0.25, inside: true),
            shadow: ShadowEffect(enabled: true, angle: 270, distance: 12, blur: 6, red: 1, green: 0, blue: 0.5, opacity: 0.75),
            colorOverlay: ColorOverlayEffect(enabled: true, red: 0.25, green: 0.75, blue: 0, opacity: 0.5),
            innerShadow: InnerShadowEffect(enabled: true, angle: -45, distance: 4, blur: 2, red: 0, green: 0, blue: 1,
                                           opacity: 1),
            outerGlow: OuterGlowEffect(enabled: true, size: 9, red: 1, green: 1, blue: 0, opacity: 0.5),
            innerGlow: InnerGlowEffect(enabled: true, size: 7, red: 1, green: 0.5, blue: 0, opacity: 0.25))
    }

    // MARK: Fresh effects

    @Test func everyKindIsWrittenWithPhotoshopsKeysTypesAndValues() throws {
        let lfx2 = PSDEffectsWriter.lfx2(everyKind, scale: 1)
        #expect(version(lfx2) == 0)
        let root = try descriptor(lfx2)
        #expect(root.name == "" && root.classID.id == "null")
        #expect(photoshopKeyForms(root))
        #expect(signature(root) == ["Scl :UntF(#Prc)", "masterFXSwitch:bool", "DrSh:Objc(DrSh)", "IrSh:Objc(IrSh)",
                                    "OrGl:Objc(OrGl)", "IrGl:Objc(IrGl)", "SoFi:Objc(SoFi)", "FrFX:Objc(FrFX)",
                                    "numModifyingFX:long"])
        #expect(number(root, "Scl ") == 100 && root.bool("masterFXSwitch") == true && root.int("numModifyingFX") == 0)

        let shadowSettings = ["uglg:bool", "lagl:UntF(#Ang)", "Dstn:UntF(#Pxl)", "Ckmt:UntF(#Pxl)", "blur:UntF(#Pxl)",
                              "Nose:UntF(#Prc)", "AntA:bool", "TrnS:Objc(ShpC)"]
        let drop = try #require(root.object("DrSh")), inner = try #require(root.object("IrSh"))
        let glow = try #require(root.object("OrGl")), overlay = try #require(root.object("SoFi"))
        let stroke = try #require(root.object("FrFX")), innerGlow = try #require(root.object("IrGl"))
        #expect(signature(drop) == common + shadowSettings + ["layerConceals:bool"])
        #expect(signature(inner) == common + shadowSettings)
        #expect(signature(glow) == common + ["GlwT:enum(BETE)", "Ckmt:UntF(#Pxl)", "blur:UntF(#Pxl)", "Nose:UntF(#Prc)",
                                             "ShdN:UntF(#Prc)", "AntA:bool", "TrnS:Objc(ShpC)", "Inpr:UntF(#Prc)"])
        #expect(signature(innerGlow) == signature(glow) + ["glwS:enum(IGSr)"])
        #expect(signature(overlay) == common)
        #expect(signature(stroke) == common + ["Styl:enum(FStl)", "PntT:enum(FrFl)", "Sz  :UntF(#Pxl)", "overprint:bool"])

        for entry in [drop, inner, glow, innerGlow, overlay, stroke] {
            #expect(entry.name == "")
            #expect(entry.bool("enab") == true && entry.bool("present") == true && entry.bool("showInDialog") == true)
            #expect(entry["Md  "] == PSDDescriptorValue.enumerated(type: "BlnM", value: "Nrml"))
            #expect(signature(try #require(entry.object("Clr "))) == ["Rd  :doub", "Grn :doub", "Bl  :doub"])
        }
        // Colors 0…255, opacity in percent.
        #expect(drop.rgb("Clr ")?.r == 255 && drop.rgb("Clr ")?.g == 0 && drop.rgb("Clr ")?.b == 127.5)
        #expect(number(drop, "Opct") == 75 && number(overlay, "Opct") == 50 && number(stroke, "Opct") == 25)
        #expect(overlay.rgb("Clr ")?.r == 63.75 && overlay.rgb("Clr ")?.g == 191.25)
        // Shadows: the angle wrapped to ±180°, Photoshop's defaults for what Compositor doesn't model.
        #expect(drop.bool("uglg") == false && number(drop, "lagl") == -90 && number(inner, "lagl") == -45)
        #expect(number(drop, "Dstn") == 12 && number(drop, "blur") == 6 && number(inner, "Dstn") == 4 && number(inner, "blur") == 2)
        #expect(number(drop, "Ckmt") == 0 && number(drop, "Nose") == 0 && drop.bool("AntA") == false)
        #expect(drop.bool("layerConceals") == true)
        let contour = try #require(drop.object("TrnS"))
        #expect(signature(contour) == ["Nm  :TEXT", "Crv :VlLs"] && contour.string("Nm  ") == "Linear")
        #expect(entries(contour, "Crv ").map(signature) == [["Hrzn:doub", "Vrtc:doub"], ["Hrzn:doub", "Vrtc:doub"]])
        #expect(entries(contour, "Crv ").map { [number($0, "Hrzn"), number($0, "Vrtc")] } == [[0, 0], [255, 255]])
        #expect(entries(contour, "Crv ").allSatisfy { $0.classID.id == "CrPt" } && contour.classID.id == "ShpC")
        #expect(inner.object("TrnS") == contour)
        // Outer glow: its size is `blur`, softer technique, range 50%.
        #expect(number(glow, "blur") == 9 && glow["GlwT"] == PSDDescriptorValue.enumerated(type: "BETE", value: "SfBL"))
        #expect(number(glow, "Ckmt") == 0 && number(glow, "Nose") == 0 && number(glow, "ShdN") == 0 && number(glow, "Inpr") == 50)
        #expect(glow.object("TrnS") == contour && glow.bool("AntA") == false)
        // Inner glow: the same, glowing in from the edges.
        #expect(number(innerGlow, "blur") == 7 && number(innerGlow, "Opct") == 25 && innerGlow.rgb("Clr ")?.g == 127.5)
        #expect(innerGlow["glwS"] == PSDDescriptorValue.enumerated(type: "IGSr", value: "SrcE"))
        // Stroke: inside or outside, a solid color.
        #expect(stroke["Styl"] == PSDDescriptorValue.enumerated(type: "FStl", value: "InsF"))
        #expect(stroke["PntT"] == PSDDescriptorValue.enumerated(type: "FrFl", value: "SClr"))
        #expect(number(stroke, "Sz  ") == 3 && stroke.bool("overprint") == false)
        var outside = everyKind
        outside.stroke?.inside = false
        #expect(try descriptor(PSDEffectsWriter.lfx2(outside, scale: 1)).object("FrFX")?["Styl"]
                    == PSDDescriptorValue.enumerated(type: "FStl", value: "OutF"))

        // Photoshop's reader, as Compositor has it, reads the same effects back.
        let read = try PSDEffectsReader.parse(lfx2, globalLightAngle: nil)
        var expected = everyKind
        expected.shadow?.angle = -90
        #expect(read.effects == expected)
        #expect(read.notes.isEmpty)
    }

    @Test func onlyTheKindsALayerHasAreWritten() throws {
        let root = try descriptor(PSDEffectsWriter.lfx2(LayerEffects(colorOverlay: ColorOverlayEffect()), scale: 1))
        #expect(root.items.map(\.key.id) == ["Scl ", "masterFXSwitch", "SoFi", "numModifyingFX"])
    }

    @Test func hiddenEffectsAreWrittenDisabledButPresent() throws {
        var effects = everyKind
        effects.shadow?.enabled = false
        effects.stroke?.enabled = false
        let root = try descriptor(PSDEffectsWriter.lfx2(effects, scale: 1))
        #expect(root.bool("masterFXSwitch") == true)
        for key in ["DrSh", "FrFX"] {
            #expect(root.object(key)?.bool("enab") == false && root.object(key)?.bool("present") == true, "\(key)")
        }
        for key in ["IrSh", "OrGl", "IrGl", "SoFi"] {
            #expect(root.object(key)?.bool("enab") == true && root.object(key)?.bool("present") == true, "\(key)")
        }
        #expect(try PSDEffectsReader.parse(PSDEffectsWriter.lfx2(effects, scale: 1), globalLightAngle: nil).effects.visible.kinds
                    == [.colorOverlay, .innerShadow, .outerGlow, .innerGlow])
    }

    // MARK: New layers

    @Test func aNewLayerGetsItsEffectsBeforeItsNameAndSizesInDocumentPixels() throws {
        let effects = everyKind
        let plain = pixelLayer("Plain", try image(10, 10))
        let styled = pixelLayer("Styled", try image(10, 10), effects: effects)
        // Drawn at twice its pixels' size: Compositor draws effects in those pixels, so the file's are twice as big.
        let scaled = pixelLayer("Scaled", try image(10, 10), size: CGSize(width: 20, height: 20), effects: effects)
        let records = try planned(session([plain, styled, scaled]))
        #expect(try record("Plain", in: records).blocks.map(\.key) == ["luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        let written = try record("Styled", in: records)
        #expect(written.blocks.map(\.key) == ["lfx2", "luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        #expect(written.blocks.first?.data == PSDEffectsWriter.lfx2(effects, scale: 1))
        let root = try descriptor(try record("Scaled", in: records).blocks.first { $0.key == "lfx2" }?.data)
        #expect(number(root.object("FrFX"), "Sz  ") == 6)
        #expect(number(root.object("DrSh"), "Dstn") == 24 && number(root.object("DrSh"), "blur") == 12)
        #expect(number(root.object("IrSh"), "Dstn") == 8 && number(root.object("IrSh"), "blur") == 4)
        #expect(number(root.object("OrGl"), "blur") == 18)
        #expect(number(root.object("DrSh"), "lagl") == -90 && number(root.object("DrSh"), "Opct") == 75)
    }

    // MARK: Imported layers

    private let lrFX = Data([0, 2, 0, 0, 0, 0])

    /// A shadow using the global light, with the settings Compositor doesn't model away from Photoshop's defaults.
    private var photoshopShadow: PSDDescriptorValue {
        PSDFixture.effect("DrSh", blendMode: "Mltp", [
            (key: "Clr ", value: PSDFixture.effectColor(0, 0, 0)),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: 75)),
            (key: "uglg", value: .bool(true)),
            (key: "lagl", value: .unitFloat(unit: "#Ang", value: 120)),
            (key: "Dstn", value: .unitFloat(unit: "#Pxl", value: 5)),
            (key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 3)),
            (key: "blur", value: .unitFloat(unit: "#Pxl", value: 7)),
            (key: "Nose", value: .unitFloat(unit: "#Prc", value: 10)),
            (key: "AntA", value: .bool(true)),
            (key: "TrnS", value: .object(PSDDescriptor(classID: "ShpC", items: [(key: "Nm  ", value: .string("Cone"))]))),
            (key: "layerConceals", value: .bool(false)),
        ])
    }

    private var photoshopGlow: PSDDescriptorValue {
        PSDFixture.effect("OrGl", blendMode: "Scrn", [
            (key: "Clr ", value: PSDFixture.effectColor(255, 255, 190)),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: 75)),
            (key: "GlwT", value: .enumerated(type: "BETE", value: "PrBL")),
            (key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 20)),
            (key: "blur", value: .unitFloat(unit: "#Pxl", value: 5)),
        ])
    }

    /// Photoshop's effects on "Badge": a global-light shadow, a centered stroke too wide for Compositor, a precise
    /// glow and a bevel Compositor lacks, plus the legacy `lrFX` and an `lmfx`.
    private func badge(masterFXSwitch: Bool = true) throws -> (session: EditorSession, lfx2: Data, lmfx: Data) {
        let lfx2 = PSDFixture.effectsBlock([
            (key: "DrSh", value: photoshopShadow),
            (key: "FrFX", value: PSDFixture.strokeEffect(style: "CtrF", size: 800, color: (0, 0, 255))),
            (key: "OrGl", value: photoshopGlow),
            (key: "ebbl", value: PSDFixture.effect("ebbl")),
            (key: "numModifyingFX", value: .integer(1)),
        ], masterFXSwitch: masterFXSwitch)
        let lmfx = PSDFixture.effectsBlock([(key: "DrSh", value: photoshopShadow)])
        let session = try opened([try raster("Badge", [PSDTaggedBlock(key: "lfx2", data: lfx2),
                                                      PSDTaggedBlock(key: "lrFX", data: lrFX),
                                                      PSDTaggedBlock(key: "lmfx", data: lmfx)])],
                                 resources: [PSDFixture.globalLightAngleResource(30)])
        return (session, lfx2, lmfx)
    }

    @Test func untouchedImportedEffectsAreWrittenBackByteForByte() throws {
        let (session, lfx2, lmfx) = try badge()
        let index = try index(of: "Badge", in: session)
        #expect(session.document?.layers[index].effects?.shadow?.angle == 30)
        // Moving a layer doesn't change its effects.
        session.document?.layers[index].transform.origin.x += 5
        let blocks = try record("Badge", in: try planned(session)).blocks
        #expect(blocks.map(\.key).filter { PSDLayerExtras.effectKeys.contains($0) } == ["lfx2", "lrFX", "lmfx"])
        #expect(blocks.first { $0.key == "lfx2" }?.data == lfx2)
        #expect(blocks.first { $0.key == "lrFX" }?.data == lrFX)
        #expect(blocks.first { $0.key == "lmfx" }?.data == lmfx)
    }

    @Test func editedEffectsRewriteOnlyWhatChangedInsideTheFilesOwnDescriptor() throws {
        let (session, lfx2, _) = try badge()
        let original = try descriptor(lfx2)
        let index = try index(of: "Badge", in: session)
        let imported = try #require(session.document?.layers[index].effects)
        #expect(imported.stroke?.size == StrokeEffect.maxSize && imported.stroke?.inside == false)
        let untouched = try record("Badge", in: try planned(session)).blocks.map(\.key)

        session.document?.layers[index].effects?.shadow?.red = 1
        session.document?.layers[index].effects?.stroke?.opacity = 0.5
        let blocks = try record("Badge", in: try planned(session)).blocks
        // The legacy block and `lmfx` would describe the old effects, so they go; `lfx2` stays where it was.
        #expect(blocks.map(\.key) == untouched.filter { $0 != "lrFX" && $0 != "lmfx" })
        let lfx2Data = try #require(blocks.first { $0.key == "lfx2" }?.data)
        #expect(version(lfx2Data) == 0)
        let edited = try descriptor(lfx2Data)
        // Only the changed values: the blend mode, choke, noise, contour, global light, centered stroke and its
        // width beyond Compositor's range stay, and so do the glow and the bevel.
        #expect(edited.items.map(\.key.id) == original.items.map(\.key.id))
        #expect(edited.object("DrSh") == (try replacing(original.object("DrSh"), [(key: "Clr ", value: PSDFixture.effectColor(255, 0, 0))])))
        #expect(edited.object("FrFX") == (try replacing(original.object("FrFX"), [(key: "Opct", value: .unitFloat(unit: "#Prc", value: 50))])))
        for key in ["Scl ", "masterFXSwitch", "OrGl", "ebbl", "numModifyingFX"] {
            #expect(edited[key] == original[key], "\(key)")
        }

        // Changing a value import approximated writes Compositor's.
        session.document?.layers[index].effects?.shadow?.angle = 45
        session.document?.layers[index].effects?.stroke?.inside = true
        session.document?.layers[index].effects?.stroke?.size = 4
        session.document?.layers[index].effects?.outerGlow?.size = 9
        session.document?.layers[index].effects?.outerGlow?.enabled = false
        let again = try descriptor(try record("Badge", in: try planned(session)).blocks.first { $0.key == "lfx2" }?.data)
        #expect(again.object("DrSh") == (try replacing(original.object("DrSh"), [
            (key: "Clr ", value: PSDFixture.effectColor(255, 0, 0)), (key: "uglg", value: .bool(false)),
            (key: "lagl", value: .unitFloat(unit: "#Ang", value: 45)),
        ])))
        #expect(again.object("FrFX") == (try replacing(original.object("FrFX"), [
            (key: "Styl", value: .enumerated(type: "FStl", value: "InsF")),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: 50)), (key: "Sz  ", value: .unitFloat(unit: "#Pxl", value: 4)),
        ])))
        #expect(again.object("OrGl") == (try replacing(original.object("OrGl"), [
            (key: "enab", value: .bool(false)), (key: "blur", value: .unitFloat(unit: "#Pxl", value: 9)),
        ])))

        // The file reads back as the document shows it.
        let request = try #require(session.psdWriteRequest())
        let reread = try PSDReader.read(try PSDWriter.data(for: request).data)
        #expect(reread.layers.first { $0.name == "Badge" }?.effects == session.document?.layers[index].effects)
    }

    @Test func aScaledImportedLayerRewritesItsSizes() throws {
        let (session, lfx2, _) = try badge()
        let original = try descriptor(lfx2)
        let index = try index(of: "Badge", in: session)
        session.document?.layers[index].transform.size = CGSize(width: 48, height: 48)
        let blocks = try record("Badge", in: try planned(session)).blocks
        #expect(!blocks.contains { $0.key == "lrFX" || $0.key == "lmfx" })
        let edited = try descriptor(blocks.first { $0.key == "lfx2" }?.data)
        #expect(edited.object("DrSh") == (try replacing(original.object("DrSh"), [
            (key: "Dstn", value: .unitFloat(unit: "#Pxl", value: 10)), (key: "blur", value: .unitFloat(unit: "#Pxl", value: 14)),
        ])))
        // Compositor draws the 500 px it imported at twice the size.
        #expect(edited.object("FrFX") == (try replacing(original.object("FrFX"), [(key: "Sz  ", value: .unitFloat(unit: "#Pxl", value: 1000))])))
        #expect(edited.object("OrGl") == (try replacing(original.object("OrGl"), [(key: "blur", value: .unitFloat(unit: "#Pxl", value: 10))])))
    }

    @Test func removedEffectsLeaveTheLayerAndAddedOnesJoinTheFilesEffects() throws {
        let lfx2 = PSDFixture.effectsBlock([
            (key: "dropShadowMulti", value: .list([PSDFixture.shadowEffect(distance: 4),
                                                   PSDFixture.shadowEffect(present: false, distance: 9)])),
            (key: "solidFillMulti", value: .list([])),
            // A gradient stroke, which Compositor doesn't show, blended with Multiply.
            (key: "FrFX", value: .object(try replacing(object(PSDFixture.strokeEffect(paint: "GrFl", size: 7)), [
                (key: "Md  ", value: .enumerated(type: "BlnM", value: "Mltp")),
            ]))),
            (key: "numModifyingFX", value: .integer(1)),
        ])
        let session = try opened([try raster("Badge", [PSDTaggedBlock(key: "lfx2", data: lfx2)])])
        let original = try descriptor(lfx2)
        let index = try index(of: "Badge", in: session)
        #expect(session.document?.layers[index].effects?.kinds == [.shadow])

        let stroke = StrokeEffect(enabled: true, size: 2, red: 1, green: 0, blue: 0, opacity: 1, inside: true)
        let overlay = ColorOverlayEffect(enabled: true, red: 0, green: 1, blue: 0, opacity: 0.5)
        let inner = InnerShadowEffect(enabled: false, angle: 60, distance: 3, blur: 2, red: 0, green: 0, blue: 0, opacity: 0.5)
        session.document?.layers[index].effects = LayerEffects(stroke: stroke, colorOverlay: overlay, innerShadow: inner)
        let edited = try descriptor(try record("Badge", in: try planned(session)).blocks.first { $0.key == "lfx2" }?.data)
        let fresh = try descriptor(PSDEffectsWriter.lfx2(try #require(session.document?.layers[index].effects), scale: 1))

        // The removed shadow is no longer present; Photoshop's other shadow entry stays as it was.
        let shadows = entries(edited, "dropShadowMulti"), originalShadows = entries(original, "dropShadowMulti")
        #expect(shadows.count == 2 && shadows[1] == originalShadows[1])
        #expect(shadows[0] == (try replacing(originalShadows[0], [(key: "present", value: .bool(false))])))
        // An added kind joins the file's list for it, or is added before `numModifyingFX`.
        #expect(entries(edited, "solidFillMulti") == [try #require(fresh.object("SoFi"))])
        #expect(edited.items.map(\.key.id) == ["Scl ", "masterFXSwitch", "dropShadowMulti", "solidFillMulti", "FrFX", "IrSh",
                                               "numModifyingFX"])
        #expect(edited.object("IrSh") == fresh.object("IrSh"))
        // A stroke Compositor couldn't show was no stroke to Compositor, so its stroke is new: a fresh entry, drawn
        // with a normal blend and a solid color as Compositor draws it, takes the gradient stroke's place.
        let replaced = try #require(edited.object("FrFX"))
        #expect(replaced == fresh.object("FrFX"))
        #expect(replaced["Md  "] == PSDDescriptorValue.enumerated(type: "BlnM", value: "Nrml"))
        #expect(replaced["PntT"] == PSDDescriptorValue.enumerated(type: "FrFl", value: "SClr"))

        let reread = try PSDEffectsReader.parse(PSDDescriptorWriter.block2(edited, version: 0), globalLightAngle: nil)
        #expect(reread.effects == session.document?.layers[index].effects)
    }

    /// An entry as Photoshop keeps one for a kind the layer doesn't use: off, not present, hidden from its dialog, at
    /// Photoshop's own defaults (shadows Multiply, a glow Screen).
    private func photoshopDefault(_ value: PSDDescriptorValue) throws -> PSDDescriptorValue {
        .object(try replacing(object(value), [(key: "enab", value: .bool(false)), (key: "present", value: .bool(false)),
                                              (key: "showInDialog", value: .bool(false))]))
    }

    @Test func anEffectAddedWherePhotoshopKeptOnlyItsDefaultsIsWrittenFresh() throws {
        // A layer that has been through Photoshop: a stroke, and Photoshop's hidden defaults for other kinds.
        let lfx2 = PSDFixture.effectsBlock([
            (key: "dropShadowMulti", value: .list([try photoshopDefault(PSDFixture.shadowEffect())])),
            (key: "innerShadowMulti", value: .list([try photoshopDefault(PSDFixture.shadowEffect("IrSh"))])),
            (key: "OrGl", value: try photoshopDefault(PSDFixture.outerGlowEffect())),
            (key: "FrFX", value: PSDFixture.strokeEffect(size: 4, color: (0, 0, 255))),
            (key: "numModifyingFX", value: .integer(1)),
        ])
        let session = try opened([try raster("Badge", [PSDTaggedBlock(key: "lfx2", data: lfx2),
                                                      PSDTaggedBlock(key: "lrFX", data: lrFX)])])
        let original = try descriptor(lfx2)
        let index = try index(of: "Badge", in: session)
        #expect(session.document?.layers[index].effects?.kinds == [.stroke])

        // A white inner shadow, a red drop shadow and a glow, added in Compositor.
        session.document?.layers[index].effects?.shadow = ShadowEffect(enabled: true, angle: 45, distance: 6, blur: 4,
                                                                       red: 1, green: 0, blue: 0, opacity: 0.8)
        session.document?.layers[index].effects?.innerShadow = InnerShadowEffect(enabled: true, angle: 90, distance: 2,
                                                                                 blur: 3, red: 1, green: 1, blue: 1,
                                                                                 opacity: 1)
        session.document?.layers[index].effects?.outerGlow = OuterGlowEffect(enabled: true, size: 7, red: 0, green: 1,
                                                                             blue: 0, opacity: 0.5)
        let effects = try #require(session.document?.layers[index].effects)
        let edited = try descriptor(try record("Badge", in: try planned(session)).blocks.first { $0.key == "lfx2" }?.data)
        let fresh = try descriptor(PSDEffectsWriter.lfx2(effects, scale: 1))

        // Each takes the place of Photoshop's hidden entry as a fresh one: a normal blend, shown in the dialog, as
        // Compositor draws it, not Photoshop's Multiply or Screen.
        #expect(edited.items.map(\.key.id) == original.items.map(\.key.id))
        #expect(entries(edited, "dropShadowMulti") == [try #require(fresh.object("DrSh"))])
        #expect(entries(edited, "innerShadowMulti") == [try #require(fresh.object("IrSh"))])
        #expect(edited.object("OrGl") == fresh.object("OrGl"))
        for entry in entries(edited, "dropShadowMulti") + entries(edited, "innerShadowMulti") + [edited.object("OrGl")].compactMap({ $0 }) {
            #expect(entry["Md  "] == PSDDescriptorValue.enumerated(type: "BlnM", value: "Nrml"), "\(entry.classID.id)")
            #expect(entry.bool("showInDialog") == true && entry.bool("present") == true && entry.bool("enab") == true)
        }
        // The stroke import read is untouched.
        #expect(edited.object("FrFX") == original.object("FrFX"))

        let reread = try PSDEffectsReader.parse(PSDDescriptorWriter.block2(edited, version: 0), globalLightAngle: nil)
        #expect(reread.effects == effects)
    }

    @Test func showingAnEffectWhileEffectsWereOffInPhotoshopKeepsTheOthersHidden() throws {
        let (session, lfx2, _) = try badge(masterFXSwitch: false)
        let original = try descriptor(lfx2)
        let index = try index(of: "Badge", in: session)
        #expect(session.document?.layers[index].effects?.visible.isEmpty == true)
        // Still off: only the changed value is written.
        session.document?.layers[index].effects?.shadow?.opacity = 0.5
        let hidden = try descriptor(try record("Badge", in: try planned(session)).blocks.first { $0.key == "lfx2" }?.data)
        #expect(hidden.bool("masterFXSwitch") == false)
        #expect(hidden.object("DrSh") == (try replacing(original.object("DrSh"), [(key: "Opct", value: .unitFloat(unit: "#Prc", value: 50))])))

        session.document?.layers[index].effects?.shadow?.enabled = true
        let shown = try descriptor(try record("Badge", in: try planned(session)).blocks.first { $0.key == "lfx2" }?.data)
        #expect(shown.bool("masterFXSwitch") == true)
        #expect(shown.object("DrSh")?.bool("enab") == true)
        for key in ["FrFX", "OrGl", "ebbl"] {
            #expect(shown.object(key)?.bool("enab") == false, "\(key)")
        }
        let reread = try PSDEffectsReader.parse(PSDDescriptorWriter.block2(shown, version: 0), globalLightAngle: 30)
        #expect(reread.effects == session.document?.layers[index].effects)
        #expect(!reread.notes.contains { $0.contains("Bevel") })
    }

    @Test func foldersAdjustmentsAndPlaceholdersKeepTheirStoredEffects() throws {
        let lfx2 = PSDFixture.effectsBlock([(key: "DrSh", value: PSDFixture.shadowEffect())])
        let effectBlocks = [PSDTaggedBlock(key: "lfx2", data: lfx2), PSDTaggedBlock(key: "lrFX", data: lrFX)]
        var folder = PSDRecord(id: UUID(), name: "Folder")
        folder.isGroup = true
        folder.extras = PSDLayerExtras(blocks: effectBlocks)
        var levels = Data([0, 2])
        for _ in 0..<29 { levels.append(contentsOf: [0, 0, 0, 255, 0, 0, 0, 255, 1, 0]) }
        var adjustment = PSDRecord(id: UUID(), name: "Levels")
        adjustment.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "levl", data: levels)] + effectBlocks)
        var placeholder = PSDRecord(id: UUID(), name: "Brightness")
        placeholder.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "brit", data: Data(count: 12))] + effectBlocks)
        let session = try opened([folder, adjustment, placeholder])
        let records = try planned(session)
        for name in ["Folder", "Levels", "Brightness"] {
            let blocks = try record(name, in: records).blocks
            #expect(blocks.filter { PSDLayerExtras.effectKeys.contains($0.key) } == effectBlocks, "\(name)")
        }
    }

    /// Effects Photoshop draws and Compositor doesn't (a kind it lacks, a second entry of a kind) stay on the layer,
    /// but the merged image Compositor renders leaves them out: a note says so for a layer that shows.
    @Test func effectsCompositorDoesntDrawAreNotedForTheMergedImage() throws {
        let lfx2 = PSDFixture.effectsBlock([
            (key: "DrSh", value: PSDFixture.shadowEffect()),
            (key: "ebbl", value: PSDFixture.effect("ebbl")),
            (key: "ChFX", value: PSDFixture.effect("ChFX", enabled: false)),
        ])
        let off = PSDFixture.effectsBlock([(key: "ebbl", value: PSDFixture.effect("ebbl"))], masterFXSwitch: false)
        var hidden = try raster("Hidden", [PSDTaggedBlock(key: "lfx2", data: lfx2)])
        hidden.isVisible = false
        let session = try opened([try raster("Bevel", [PSDTaggedBlock(key: "lfx2", data: lfx2)]), hidden,
                                  try raster("Off", [PSDTaggedBlock(key: "lfx2", data: off)])])
        let warnings = try PSDLayerRecordWriter.plan(try #require(session.psdWriteRequest()), options: .init()).warnings
        #expect(warnings.map(\.layerName) == ["Bevel"])
        #expect(warnings.first?.message.contains("Bevel & Emboss") == true && warnings.first?.message.contains("Satin") == false)
        #expect(warnings.map(\.lossy) == [false])
    }

    @Test func withoutPhotoshopDataEffectsAreWrittenFresh() throws {
        let (session, _, _) = try badge()
        let index = try index(of: "Badge", in: session)
        let effects = try #require(session.document?.layers[index].effects)
        let blocks = try record("Badge", in: try planned(session, PSDWriteOptions(preserveExtras: false))).blocks
        #expect(blocks.filter { PSDLayerExtras.effectKeys.contains($0.key) } == [PSDTaggedBlock(key: "lfx2", data: PSDEffectsWriter.lfx2(effects, scale: 1))])
        #expect(blocks.first?.key == "lfx2")
    }

    @Test func effectsAddedToAnImportedLayerWithoutAnyAreWrittenFresh() throws {
        let session = try opened([try raster("Badge", [PSDTaggedBlock(key: "lmfx", data: Data([0, 0, 0, 0]))])])
        let index = try index(of: "Badge", in: session)
        let effects = LayerEffects(shadow: ShadowEffect())
        session.document?.layers[index].effects = effects
        let blocks = try record("Badge", in: try planned(session)).blocks
        #expect(blocks.filter { PSDLayerExtras.effectKeys.contains($0.key) } == [PSDTaggedBlock(key: "lfx2", data: PSDEffectsWriter.lfx2(effects, scale: 1))])
        #expect(blocks.firstIndex { $0.key == "lfx2" }.map { $0 + 1 } == blocks.firstIndex { $0.key == "luni" })
    }
}
