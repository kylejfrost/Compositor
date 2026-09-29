import CoreGraphics
import Foundation
import MCP
import Testing
@testable import Compositor

/// Photoshop layer effects (`lfx2`) import as live Compositor effects; what Compositor can't show is noted, and the
/// `lfx2`/`lrFX` bytes stay in the layer's Photoshop data.
@MainActor
@Suite(.serialized)
struct PSDEffectsImportTests {
    private func close(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }
    private func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }

    private func parse(_ effects: [(key: String, value: PSDDescriptorValue)], masterFXSwitch: Bool = true,
                       globalLightAngle: Double? = nil) throws -> PSDEffectsReader.Result {
        try PSDEffectsReader.parse(PSDFixture.effectsBlock(effects, masterFXSwitch: masterFXSwitch),
                                   globalLightAngle: globalLightAngle)
    }

    private func raster(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        return try #require(context.makeImage())
    }

    /// A one-layer file (a pixel layer, or an empty folder) whose layer carries `blocks`, read and converted.
    private func importing(_ blocks: [PSDTaggedBlock], folder: Bool = false, fillOpacity: Double = 1,
                           resources: [PSDImageResource] = []) throws -> PSDImport {
        var record = PSDRecord(id: UUID(), name: folder ? "Folder" : "Badge")
        record.fillOpacity = fillOpacity
        if folder {
            record.isGroup = true
        } else {
            record.bounds = CGRect(x: 20, y: 16, width: 24, height: 24)
            record.image = try raster(width: 24, height: 24)
        }
        record.extras = PSDLayerExtras(blocks: blocks)
        var document = PSDDocument(width: 64, height: 64, resolution: 72, layers: [record])
        document.extras = PSDDocumentExtras(resources: resources)
        let data = try PSDFixture.data(document, composite: try raster(width: 64, height: 64))
        return try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
    }

    // MARK: Mapping

    @Test func singleDropShadowMapsAngleDistanceBlurColorAndOpacity() throws {
        let result = try parse([(key: "DrSh", value: PSDFixture.shadowEffect(angle: 30, distance: 12, blur: 7,
                                                                             color: (255, 0, 51), opacity: 60))],
                               globalLightAngle: 90)
        let shadow = try #require(result.effects.shadow)
        #expect(shadow.isEnabled)
        #expect(close(shadow.angle, 30) && close(shadow.distance, 12) && close(shadow.blur, 7))
        #expect(close(shadow.red, 1) && close(shadow.green, 0) && close(shadow.blue, 0.2))
        #expect(close(shadow.opacity, 0.6))
        #expect(result.effects.kinds == [.shadow])
        // Photoshop multiplies the red shadow into what lies below; Compositor draws it as Normal.
        #expect(result.notes == ["The drop shadow’s blend mode isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."])
    }

    @Test func dropShadowMultiWithTheFirstDisabledPicksTheSecond() throws {
        let result = try parse([(key: "dropShadowMulti", value: .list([
            PSDFixture.shadowEffect(enabled: false, distance: 3),
            PSDFixture.shadowEffect(distance: 9, blur: 4),
        ]))])
        let shadow = try #require(result.effects.shadow)
        #expect(shadow.isEnabled)
        #expect(close(shadow.distance, 9) && close(shadow.blur, 4))
        // A hidden extra shadow isn't a visible loss.
        #expect(result.notes.isEmpty)
    }

    @Test func extraEnabledEntriesInAMultiListAreNoted() throws {
        let result = try parse([(key: "frameFXMulti", value: .list([
            PSDFixture.strokeEffect(size: 4),
            PSDFixture.strokeEffect(size: 8),
            PSDFixture.strokeEffect(size: 12),
        ]))])
        #expect(close(result.effects.stroke?.size, 4))
        #expect(result.notes.count == 1)
        #expect(result.notes.first?.contains("one stroke") == true)
        #expect(result.notes.first?.contains("2 more") == true)
    }

    @Test func multiListWithEveryEntryHiddenImportsTheFirstHidden() throws {
        let result = try parse([(key: "innerShadowMulti", value: .list([
            PSDFixture.shadowEffect("IrSh", enabled: false, distance: 2),
            PSDFixture.shadowEffect("IrSh", enabled: false, distance: 6),
        ]))])
        let inner = try #require(result.effects.innerShadow)
        #expect(!inner.isEnabled)
        #expect(close(inner.distance, 2))
        #expect(result.notes.isEmpty)
    }

    @Test func effectsNotPresentAreLeftOut() throws {
        let result = try parse([(key: "DrSh", value: PSDFixture.shadowEffect(present: false))])
        #expect(result.effects.isEmpty)
        #expect(result.notes.isEmpty)
    }

    @Test func strokeStyleChoosesTheSide() throws {
        let inside = try parse([(key: "FrFX", value: PSDFixture.strokeEffect(style: "InsF", size: 6, color: (0, 255, 0), opacity: 50))])
        let insideStroke = try #require(inside.effects.stroke)
        #expect(insideStroke.inside && insideStroke.isEnabled)
        #expect(close(insideStroke.size, 6) && close(insideStroke.green, 1) && close(insideStroke.red, 0))
        #expect(close(insideStroke.opacity, 0.5))
        #expect(inside.notes.isEmpty)

        let outside = try parse([(key: "FrFX", value: PSDFixture.strokeEffect(style: "OutF", size: 25))])
        #expect(outside.effects.stroke?.inside == false)
        // lfx2 sizes are final document pixels: `Scl ` isn't multiplied in.
        #expect(close(outside.effects.stroke?.size, 25))
        #expect(outside.notes.isEmpty)

        let centered = try parse([(key: "FrFX", value: PSDFixture.strokeEffect(style: "CtrF", size: 5))])
        #expect(centered.effects.stroke?.inside == false)
        #expect(close(centered.effects.stroke?.size, 5))
        #expect(centered.notes.count == 1)
        #expect(centered.notes.first?.contains("centered") == true)
    }

    @Test func strokeScaleIsNotMultipliedIn() throws {
        let data = PSDFixture.effectsBlock([(key: "FrFX", value: PSDFixture.strokeEffect(size: 25))], scale: 416)
        let result = try PSDEffectsReader.parse(data, globalLightAngle: nil)
        #expect(close(result.effects.stroke?.size, 25))
    }

    @Test func gradientOrPatternStrokeIsSkippedWithANote() throws {
        for (paint, word) in [("GrFl", "gradient"), ("Ptrn", "pattern")] {
            let result = try parse([(key: "FrFX", value: PSDFixture.strokeEffect(paint: paint)),
                                    (key: "SoFi", value: PSDFixture.colorOverlayEffect())])
            #expect(result.effects.stroke == nil)
            #expect(result.effects.colorOverlay != nil)
            #expect(result.notes.count == 1)
            #expect(result.notes.first?.contains(word) == true)
        }
    }

    @Test func solidFillBecomesAColorOverlay() throws {
        let result = try parse([(key: "SoFi", value: PSDFixture.colorOverlayEffect(color: (0, 0, 255), opacity: 40))])
        let overlay = try #require(result.effects.colorOverlay)
        #expect(overlay.isEnabled)
        #expect(close(overlay.red, 0) && close(overlay.green, 0) && close(overlay.blue, 1))
        #expect(close(overlay.opacity, 0.4))
        #expect(result.effects.kinds == [.colorOverlay])
        #expect(result.notes.isEmpty)

        let multi = try parse([(key: "solidFillMulti", value: .list([PSDFixture.colorOverlayEffect(color: (0, 255, 0))]))])
        #expect(close(multi.effects.colorOverlay?.green, 1))
    }

    @Test func innerShadowAndOuterGlowMap() throws {
        let result = try parse([
            (key: "IrSh", value: PSDFixture.shadowEffect("IrSh", angle: -45, distance: 4, blur: 3, color: (0, 0, 0), opacity: 30)),
            (key: "OrGl", value: PSDFixture.outerGlowEffect(size: 18, color: (255, 255, 0), opacity: 90)),
        ])
        let inner = try #require(result.effects.innerShadow)
        #expect(close(inner.angle, -45) && close(inner.distance, 4) && close(inner.blur, 3) && close(inner.opacity, 0.3))
        let glow = try #require(result.effects.outerGlow)
        #expect(close(glow.size, 18) && close(glow.red, 1) && close(glow.green, 1) && close(glow.blue, 0))
        #expect(close(glow.opacity, 0.9))
        // The black inner shadow multiplies just as Normal draws it; the yellow glow's Screen doesn't.
        #expect(result.notes == ["The outer glow’s blend mode isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."])
    }

    @Test func innerGlowMapsItsSizeColorAndOpacity() throws {
        let result = try parse([(key: "IrGl", value: PSDFixture.innerGlowEffect(size: 14, color: (255, 255, 255), opacity: 60))])
        let glow = try #require(result.effects.innerGlow)
        #expect(glow.isEnabled && close(glow.size, 14) && close(glow.opacity, 0.6))
        #expect(close(glow.red, 1) && close(glow.green, 1) && close(glow.blue, 1))
        // White screened draws as Normal does, and an edge glow is what Compositor draws.
        #expect(result.notes.isEmpty)

        let center = try parse([(key: "IrGl", value: PSDFixture.innerGlowEffect(color: (255, 255, 255), source: "SrcC"))])
        #expect(center.effects.innerGlow != nil)
        #expect(center.notes == ["The inner glow’s center source isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."])
        let wide = try parse([(key: "IrGl", value: PSDFixture.innerGlowEffect(size: 900, color: (255, 255, 255)))])
        #expect(close(wide.effects.innerGlow?.size, InnerGlowEffect.maxSize))
        #expect(wide.notes.contains { $0.contains("inner glow’s size") })
    }

    @Test func masterSwitchOffDisablesEveryEffect() throws {
        let result = try parse([
            (key: "DrSh", value: PSDFixture.shadowEffect()),
            (key: "FrFX", value: PSDFixture.strokeEffect()),
            (key: "SoFi", value: PSDFixture.colorOverlayEffect()),
            (key: "IrSh", value: PSDFixture.shadowEffect("IrSh")),
            (key: "OrGl", value: PSDFixture.outerGlowEffect()),
            (key: "IrGl", value: PSDFixture.innerGlowEffect()),
        ], masterFXSwitch: false)
        #expect(result.effects.kinds == LayerEffectKind.allCases)
        #expect(LayerEffectKind.allCases.allSatisfy { !result.effects.isEnabled($0) })
        #expect(result.effects.visible.isEmpty)
        #expect(result.notes.isEmpty)
    }

    @Test func bevelIsNotedAndTheRestImports() throws {
        let result = try parse([
            (key: "DrSh", value: PSDFixture.shadowEffect(distance: 8)),
            (key: "ebbl", value: PSDFixture.effect("ebbl")),
            (key: "FrFX", value: PSDFixture.strokeEffect(size: 2)),
        ])
        #expect(close(result.effects.shadow?.distance, 8))
        #expect(close(result.effects.stroke?.size, 2))
        #expect(result.notes.count == 1)
        #expect(result.notes.first?.contains("Bevel & Emboss") == true)
    }

    @Test func unsupportedKindsAreNotedOnlyWhenShown() throws {
        let shown = try parse([
            (key: "GrFl", value: PSDFixture.effect("GrFl")),
            (key: "patternFill", value: PSDFixture.effect("patternFill")),
            (key: "ChFX", value: PSDFixture.effect("ChFX")),
        ])
        #expect(shown.effects.isEmpty)
        for name in ["Gradient Overlay", "Pattern Overlay", "Satin"] {
            #expect(shown.notes.contains { $0.contains(name) }, "\(name)")
        }
        let hidden = try parse([(key: "ebbl", value: PSDFixture.effect("ebbl", enabled: false)),
                                (key: "gradientFillMulti", value: .list([PSDFixture.effect("GrFl", enabled: false)]))])
        #expect(hidden.notes.isEmpty)
    }

    @Test func globalLightUsesResource1037Angle() throws {
        let global = try parse([(key: "DrSh", value: PSDFixture.shadowEffect(useGlobalLight: true, angle: 120))],
                               globalLightAngle: 30)
        #expect(close(global.effects.shadow?.angle, 30))
        let local = try parse([(key: "DrSh", value: PSDFixture.shadowEffect(useGlobalLight: false, angle: 120))],
                              globalLightAngle: 30)
        #expect(close(local.effects.shadow?.angle, 120))
        let noResource = try parse([(key: "IrSh", value: PSDFixture.shadowEffect("IrSh", useGlobalLight: true, angle: 75))])
        #expect(close(noResource.effects.innerShadow?.angle, 75))

        let block = PSDFixture.effectsBlock([(key: "DrSh", value: PSDFixture.shadowEffect(useGlobalLight: true, angle: 120))])
        let imported = try importing([PSDTaggedBlock(key: "lfx2", data: block)],
                                     resources: [PSDFixture.globalLightAngleResource(30)])
        #expect(close(imported.layers.first?.effects?.shadow?.angle, 30))
    }

    @Test func valuesBeyondCompositorRangesAreClampedWithANote() throws {
        let result = try parse([
            (key: "FrFX", value: PSDFixture.strokeEffect(size: 800)),
            (key: "DrSh", value: PSDFixture.shadowEffect(distance: 6000, blur: 20)),
        ])
        #expect(close(result.effects.stroke?.size, StrokeEffect.maxSize))
        #expect(close(result.effects.shadow?.distance, ShadowEffect.maxDistance))
        #expect(close(result.effects.shadow?.blur, 20))
        #expect(result.effects.isValid)
        #expect(result.notes.count == 2)
        #expect(result.notes.contains { $0.contains("stroke") && $0.contains("500") })
        #expect(result.notes.contains { $0.contains("drop shadow") && $0.contains("5000") })
    }

    /// What Compositor's effects don't model and would show differently (a blend mode other than Normal, spread or
    /// choke, noise, a contour that isn't linear, the Precise glow technique) is noted once per effect that shows.
    @Test func unmodeledSettingsThatShowAreNoted() throws {
        func with(_ effect: PSDDescriptorValue, _ changes: [(key: String, value: PSDDescriptorValue)]) -> PSDDescriptorValue {
            guard case .object(var descriptor) = effect else { return effect }
            for change in changes {
                if let index = descriptor.items.firstIndex(where: { $0.key.id == change.key }) {
                    descriptor.items[index].value = change.value
                } else {
                    descriptor.items.append((key: PSDKey(change.key), value: change.value))
                }
            }
            return .object(descriptor)
        }
        let cone = PSDDescriptorValue.object(PSDDescriptor(classID: "ShpC", items: [
            (key: "Nm  ", value: .string("Cone")),
            (key: "Crv ", value: .list([(0.0, 0.0), (128.0, 255.0), (255.0, 0.0)].map { point -> PSDDescriptorValue in
                .object(PSDDescriptor(classID: "CrPt", items: [(key: "Hrzn", value: .double(point.0)),
                                                                 (key: "Vrtc", value: .double(point.1))]))
            })),
        ]))
        let result = try parse([
            (key: "DrSh", value: with(PSDFixture.shadowEffect(color: (255, 0, 0)), [
                (key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 10)),
                (key: "Nose", value: .unitFloat(unit: "#Prc", value: 5)),
                (key: "TrnS", value: cone),
            ])),
            (key: "IrSh", value: with(PSDFixture.shadowEffect("IrSh"), [(key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 4))])),
            (key: "OrGl", value: with(PSDFixture.outerGlowEffect(color: (255, 255, 255)),
                                      [(key: "GlwT", value: .enumerated(type: "BETE", value: "PrBL"))])),
            (key: "FrFX", value: with(PSDFixture.strokeEffect(), [(key: "Md  ", value: .enumerated(type: "BlnM", value: "Ovrl"))])),
            (key: "SoFi", value: PSDFixture.colorOverlayEffect()),
        ])
        #expect(result.effects.kinds.count == 5)
        #expect(result.notes.count == 4)
        #expect(result.notes.contains("The drop shadow’s blend mode, spread, noise and contour aren’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."))
        #expect(result.notes.contains("The inner shadow’s choke isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."))
        #expect(result.notes.contains("The outer glow’s Precise technique isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."))
        #expect(result.notes.contains("The stroke’s blend mode isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept."))

        // Multiply in black and Screen in white draw just as Normal does; an effect that doesn't show isn't noted.
        let quiet = try parse([
            (key: "DrSh", value: PSDFixture.shadowEffect()),
            (key: "OrGl", value: PSDFixture.outerGlowEffect(color: (255, 255, 255))),
            (key: "IrSh", value: with(PSDFixture.shadowEffect("IrSh", enabled: false, color: (0, 0, 255)),
                                      [(key: "Nose", value: .unitFloat(unit: "#Prc", value: 20))])),
        ])
        #expect(quiet.effects.kinds.count == 3)
        #expect(quiet.notes.isEmpty)
    }

    @Test func malformedEffectsDataThrows() {
        #expect(throws: (any Error).self) { try PSDEffectsReader.parse(Data([0, 0, 0, 0]), globalLightAngle: nil) }
        #expect(throws: (any Error).self) { try PSDEffectsReader.parse(Data(), globalLightAngle: nil) }
    }

    // MARK: Import

    @Test func importedLayerGetsLiveEffectsAndKeepsItsBlocks() throws {
        let lfx2 = PSDFixture.effectsBlock([
            (key: "dropShadowMulti", value: .list([PSDFixture.shadowEffect(distance: 5, blur: 3)])),
            (key: "frameFXMulti", value: .list([PSDFixture.strokeEffect(style: "InsF", size: 2, color: (255, 255, 255))])),
        ])
        let lrFX = Data([0, 2, 0, 0, 0, 0])
        let imported = try importing([PSDTaggedBlock(key: "lfx2", data: lfx2), PSDTaggedBlock(key: "lrFX", data: lrFX)],
                                     fillOpacity: 128.0 / 255)
        let layer = try #require(imported.layers.first)
        let effects = try #require(layer.effects)
        #expect(effects.kinds == [.stroke, .shadow])
        #expect(effects.stroke?.inside == true && close(effects.stroke?.size, 2))
        #expect(close(effects.shadow?.distance, 5))
        #expect(layer.psdExtras?.importedEffects == effects)
        #expect(layer.psdExtras?.block("lfx2") == lfx2)
        #expect(layer.psdExtras?.block("lrFX") == lrFX)
        #expect(imported.conversions.isEmpty)
        // Fill is kept apart: the effects draw at the layer's opacity, its own pixels at its Fill as well.
        #expect(abs(layer.fillOpacity - 0.5) < 0.01)
        #expect(layer.effectiveOpacity(in: [layer.id: layer]) == 1)
        #expect(abs(layer.pixelOpacity(in: [layer.id: layer]) - 0.5) < 0.01)
    }

    @Test func effectNotesReachTheConversionReport() throws {
        let lfx2 = PSDFixture.effectsBlock([(key: "DrSh", value: PSDFixture.shadowEffect()),
                                            (key: "ebbl", value: PSDFixture.effect("ebbl"))])
        let imported = try importing([PSDTaggedBlock(key: "lfx2", data: lfx2)])
        #expect(imported.layers.first?.effects?.shadow != nil)
        #expect(imported.conversions.count == 1)
        #expect(imported.conversions.first?.layerName == "Badge")
        #expect(imported.conversions.first?.message.contains("Bevel & Emboss") == true)
    }

    @Test func folderWithEffectsIsNotedAndGetsNone() throws {
        let lfx2 = PSDFixture.effectsBlock([(key: "DrSh", value: PSDFixture.shadowEffect())])
        let imported = try importing([PSDTaggedBlock(key: "lfx2", data: lfx2)], folder: true)
        let folder = try #require(imported.layers.first)
        #expect(folder.isGroup)
        #expect(folder.effects == nil)
        #expect(folder.psdExtras?.importedEffects == nil)
        #expect(folder.psdExtras?.block("lfx2") == lfx2)
        #expect(imported.conversions.count == 1)
        #expect(imported.conversions.first?.message.contains("folder") == true)
    }

    @Test func unreadableEffectsAreNotedAndKept() throws {
        let broken = Data([0, 0, 0, 0, 0, 0, 0, 16, 0xFF])
        let imported = try importing([PSDTaggedBlock(key: "lfx2", data: broken)])
        let layer = try #require(imported.layers.first)
        #expect(layer.effects == nil)
        #expect(layer.psdExtras?.block("lfx2") == broken)
        #expect(imported.conversions.count == 1)
        #expect(imported.conversions.first?.message.contains("couldn’t be read") == true)
    }

    @Test func getLayerReportsImportedEffects() throws {
        let lfx2 = PSDFixture.effectsBlock([(key: "SoFi", value: PSDFixture.colorOverlayEffect(color: (0, 0, 255), opacity: 40))])
        let imported = try importing([PSDTaggedBlock(key: "lfx2", data: lfx2)])
        let document = CanvasDocument(width: imported.width, height: imported.height, layers: imported.layers)
        let layer = try #require(imported.layers.first)
        let value = MCPValues.layerDetail(layer, in: document, full: true)
        let overlay = try #require(value.objectValue?["effects"]?.objectValue?["color_overlay"]?.objectValue)
        #expect(close(MCPValues.number(overlay["blue"]), 1))
        #expect(close(MCPValues.number(overlay["opacity"]), 0.4))
        #expect(overlay["enabled"]?.boolValue == true)
    }
}
