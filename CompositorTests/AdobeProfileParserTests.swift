import CryptoKit
import Foundation
import Testing
@testable import Compositor

struct AdobeProfileParserTests {
    static let uuid = "0123456789ABCDEF0123456789ABCDEF"
    static let look = ProfileFixture.hueSatMap(hue: 12, saturation: 4, value: 4, encoding: .sRGB, amount: 0...2) { v, h, s in
        (Float(h) * 2.5 - 12, 1 + Float(s) * 0.125, 1 - Float(v) * 0.0625)
    }
    static let warm = ProfileFixture.rgbTable(divisions: 9, primaries: .adobeRGB, gamma: .gamma22) { r, g, b in
        (r * 1.1 + 0.02, g, b * 0.85)
    }
    static let curve = [(0, 10), (64, 58), (128, 132), (192, 205), (255, 250)]

    static func full(elementForm: Bool = false, prefix: String = "crs") -> Data {
        ProfileFixture.xmp(grayscale: true, rgbTableAmount: 0.5, look: look, rgb: warm,
                           curves: ["ToneCurvePV2012": curve], elementForm: elementForm, prefix: prefix)
    }

    static func name(_ items: [(String, String)]) -> String {
        let lis = items.map { "<rdf:li xml:lang=\"\($0.0)\">\($0.1)</rdf:li>" }.joined()
        return "<crs:Name><rdf:Alt>\(lis)</rdf:Alt></crs:Name>"
    }

    @Test func attributeFormParsesEverything() throws {
        let profile = try AdobeProfileParser.profile(from: Self.full())
        #expect(profile.presetType == .look)
        #expect(profile.name == "Test Look")
        #expect(profile.uuid == Self.uuid)
        #expect(profile.group == "Tests")
        #expect(profile.support.isSuperset(of: [.amount, .color, .outputReferred]))
        #expect(profile.support.contains(.sceneReferred) && profile.support.contains(.normalDynamicRange))
        #expect(!profile.support.contains(.monochrome) && !profile.support.contains(.highDynamicRange))
        #expect(profile.convertToGrayscale)
        #expect(profile.rgbTableAmount == 0.5)
        #expect(profile.cameraModelRestriction == nil)
        #expect(!profile.requiresRGBTables)
        #expect(profile.tablesDecoded)
        #expect(profile.lookTable == Self.look)
        #expect(profile.rgbTable == Self.warm)
        let lookFingerprint = AdobeTableCodec.encodeTable(.look(Self.look)).fingerprint
        let rgbFingerprint = AdobeTableCodec.encodeTable(.rgb(Self.warm)).fingerprint
        #expect(profile.lookTableFingerprint == lookFingerprint)
        #expect(profile.rgbTableFingerprint == rgbFingerprint)
        #expect(profile.embeddedTables == [lookFingerprint, rgbFingerprint])
        #expect(profile.settings.toneCurves["ToneCurvePV2012"] == Self.curve.map { ProfileCurvePoint(x: $0.0, y: $0.1) })
        #expect(profile.settings.values == ["ConvertToGrayscale": "True", "RGBTableAmount": "0.5"])
        #expect(profile.settings.structured.isEmpty)
        #expect(profile.usability == .usable)
        #expect(profile.fidelity == .exact)
    }

    @Test func elementFormAndOtherPrefixParseTheSame() throws {
        let attributes = try AdobeProfileParser.profile(from: Self.full())
        #expect(try AdobeProfileParser.profile(from: Self.full(elementForm: true)) == attributes)
        #expect(try AdobeProfileParser.profile(from: Self.full(prefix: "cr")) == attributes)
        #expect(try AdobeProfileParser.profile(from: Self.full(elementForm: true, prefix: "cr")) == attributes)
    }

    @Test func localizedTextPrefersEnglish() throws {
        let english = Self.name([("fr", "Couleur"), ("x-default", "Colour"), ("en-US", "Color")])
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: english)).name == "Color")
        let plainEnglish = Self.name([("fr", "Couleur"), ("en", "Colour"), ("x-default", "Default")])
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: plainEnglish)).name == "Colour")
        let fallback = Self.name([("x-default", "Colour")])
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: fallback)).name == "Colour")
        let first = Self.name([("de", "Farbe")])
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: first)).name == "Farbe")
        let emptyEnglish = Self.name([("en-US", ""), ("x-default", "Colour")])
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: emptyEnglish)).name == "Colour")
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(group: "")).group == nil)
        #expect(throws: ProfileError.malformed("Name")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: Self.name([("x-default", "")])))
        }
    }

    @Test func entitiesAreDecoded() throws {
        let escaped = Self.name([("x-default", "B&amp;W 01")])
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(nameXML: escaped)).name == "B&W 01")
        let profile = try AdobeProfileParser.profile(from: ProfileFixture.xmp(name: "B&W <\"02\">", cameraModel: "A&B \"C\""))
        #expect(profile.name == "B&W <\"02\">")
        #expect(profile.cameraModelRestriction == "A&B \"C\"")
    }

    @Test func presetsAndOtherFilesAreRejected() throws {
        #expect(throws: ProfileError.notAProfile(presetType: "Normal")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(presetType: "Normal"))
        }
        #expect(throws: ProfileError.notAProfile(presetType: nil)) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(presetType: nil))
        }
        #expect(throws: ProfileError.malformed("XML")) { try AdobeProfileParser.profile(from: Data("hello".utf8)) }
        let noCRS = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:format=\"image/jpeg\"/>"
            + "</rdf:RDF></x:xmpmeta>"
        #expect(throws: ProfileError.notAProfile(presetType: nil)) { try AdobeProfileParser.profile(from: Data(noCRS.utf8)) }
        #expect(throws: ProfileError.malformed("UUID")) { try AdobeProfileParser.profile(from: ProfileFixture.xmp(uuid: "")) }
        #expect(throws: ProfileError.malformed("UUID")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(uuid: "0123456789ABCDEF0123456789ABCDEG"))
        }
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(uuid: "0123456789abcdef0123456789abcdef")).uuid == Self.uuid)
        #expect(throws: ProfileError.malformed("RGBTableAmount")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(rgbTableAmount: 2.5))
        }
        #expect(throws: ProfileError.malformed("RGBTableAmount")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(settings: ["RGBTableAmount": "half"]))
        }
        #expect(throws: ProfileError.tooLarge) {
            try AdobeProfileParser.profile(from: Data(count: AdobeProfileParser.maximumFileBytes + 1))
        }
    }

    @Test func externalEntitiesAreNotResolved() {
        let data = ProfileFixture.xmp(nameXML: Self.name([("x-default", "&xxe;")]),
                                      doctype: "<!DOCTYPE x:xmpmeta [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>")
        do {
            let profile = try AdobeProfileParser.profile(from: data)
            #expect(!profile.name.contains("root:"))
            #expect(!profile.settings.values.values.contains { $0.contains("root:") })
        } catch {
            #expect(error is ProfileError)
            #expect(!"\(error.localizedDescription)".contains("root:"))
        }
    }

    @Test func missingTableIsReportedNotThrown() throws {
        let profile = try AdobeProfileParser.profile(from: ProfileFixture.xmp(look: Self.look, embedTables: false))
        #expect(profile.lookTable == nil)
        #expect(profile.lookTableFingerprint == AdobeTableCodec.encodeTable(.look(Self.look)).fingerprint)
        #expect(profile.embeddedTables.isEmpty)
        #expect(profile.usability == .unsupported("a table it names isn't in the file"))
    }

    @Test func tamperedTableFailsOnlyWhenDecoding() throws {
        let original = AdobeTableCodec.encodeTable(.look(Self.look))
        let other = AdobeTableCodec.encodeTable(.look(ProfileFixture.hueSatMap(hue: 6, saturation: 2, value: 1)))
        let xml = String(decoding: ProfileFixture.xmp(look: Self.look), as: UTF8.self)
        #expect(xml.contains(original.text))
        let tampered = Data(xml.replacingOccurrences(of: original.text, with: other.text).utf8)
        #expect(throws: ProfileError.malformed("table fingerprint")) { try AdobeProfileParser.profile(from: tampered) }
        let listed = try AdobeProfileParser.profile(from: tampered, decodeTables: false)
        #expect(!listed.tablesDecoded)
        #expect(listed.lookTable == nil)
        #expect(listed.embeddedTables == [original.fingerprint])
        #expect(listed.usability == .usable)
    }

    @Test func tableOfTheWrongKindIsMalformed() {
        let rgb = AdobeTableCodec.encodeTable(.rgb(Self.warm))
        let extra = "\n  <crs:LookTable>\(rgb.fingerprint)</crs:LookTable><crs:Table_\(rgb.fingerprint)>\(rgb.text)</crs:Table_\(rgb.fingerprint)>"
        #expect(throws: ProfileError.malformed("table kind")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(extraDescriptionXML: extra))
        }
    }

    @Test func usabilityOrder() throws {
        func usability(_ data: Data) throws -> ProfileUsability { try AdobeProfileParser.profile(from: data).usability }
        #expect(try usability(ProfileFixture.xmp(outputReferred: false, cameraModel: "Nikon Z 8")) == .cameraSpecific("Nikon Z 8"))
        #expect(try usability(ProfileFixture.xmp(outputReferred: false)) == .rawOnly)
        #expect(try usability(ProfileFixture.xmp(outputReferred: false, look: Self.look, embedTables: false)) == .rawOnly)
        #expect(try usability(ProfileFixture.xmp(cameraModel: "")) == .usable)
        #expect(try usability(ProfileFixture.xmp(settings: ["RGBTables": "100"]))
                == .unsupported("it uses data stored in raw files (RGBTables)"))
        #expect(try usability(ProfileFixture.xmp(settings: ["ProfileToneCurve": "50"]))
                == .unsupported("it uses data stored in raw files (ProfileToneCurve)"))
        #expect(try usability(ProfileFixture.xmp(settings: ["ProfileGainTableMap": "0"])) == .usable)
        let requires = "<crs:RequiresRGBTables>True</crs:RequiresRGBTables>"
        #expect(try usability(ProfileFixture.xmp(extraDescriptionXML: requires)) == .unsupported("it needs a raw file's RGB tables"))
        #expect(try usability(ProfileFixture.xmp(look: Self.look, embedTables: false, extraDescriptionXML: requires))
                == .unsupported("a table it names isn't in the file"))
    }

    @Test func fidelityMatchesTheReferenceRules() throws {
        let settings = ["Clarity2012": "+10", "Contrast2012": "+8", "GrayMixerRed": "0", "SplitToningShadowHue": "40",
                        "Exposure2012": "+0.00", "ParametricShadowSplit": "25", "SaturationAdjustmentRed": "0",
                        "HueAdjustmentRed": "5", "SupportsFoo": "True"]
        let approximate = try AdobeProfileParser.profile(from: ProfileFixture.xmp(settings: settings))
        #expect(approximate.fidelity == .approximate(ignored: ["Clarity2012", "Contrast2012", "HueAdjustmentRed"]))
        #expect(approximate.settings.values["SupportsFoo"] == nil)
        #expect(approximate.settings.values["Clarity2012"] == "+10")

        let curvesAndGray = ProfileFixture.xmp(grayscale: true, curves: ["ToneCurvePV2012": Self.curve, "ToneCurvePV2012Red": [(0, 0), (255, 240)]])
        #expect(try AdobeProfileParser.profile(from: curvesAndGray).fidelity == .exact)

        let pointColors = "<crs:PointColors><rdf:Seq><rdf:li rdf:parseType=\"Resource\"><crs:SrcHue>1</crs:SrcHue></rdf:li></rdf:Seq></crs:PointColors>"
        let structured = try AdobeProfileParser.profile(from: ProfileFixture.xmp(extraDescriptionXML: pointColors))
        #expect(structured.settings.structured == ["PointColors"])
        #expect(structured.fidelity == .approximate(ignored: ["PointColors"]))

        let legacyCurve = try AdobeProfileParser.profile(from: ProfileFixture.xmp(curves: ["ToneCurve": [(0, 0), (255, 255)]]))
        #expect(legacyCurve.fidelity == .approximate(ignored: ["ToneCurve"]))
    }

    @Test func neutralValuesFollowTheReference() {
        #expect(ProfileDevelopSettings.isNeutral("Exposure2012", "+0.00"))
        #expect(ProfileDevelopSettings.isNeutral("Vibrance", "0"))
        #expect(!ProfileDevelopSettings.isNeutral("Vibrance", "+5"))
        #expect(!ProfileDevelopSettings.isNeutral("ToneCurveName2012", "Linear"))
        #expect(ProfileDevelopSettings.isNeutral("LuminanceAdjustmentBlue", "-0"))
        #expect(!ProfileDevelopSettings.isNeutral("GrayMixerBlue", "12"))
        #expect(ProfileDevelopSettings.isNeutral("ColorGradeMidtoneHue", "210"))
        #expect(ProfileDevelopSettings.isNeutral("PostCropVignetteStyle", "1"))
        #expect(ProfileDevelopSettings.implemented == ["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green",
                                                  "ToneCurvePV2012Blue", "ConvertToGrayscale", "RGBTableAmount"])
    }

    @Test func malformedCurvesThrow() throws {
        let semicolon = "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0; 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>"
        #expect(throws: ProfileError.malformed("ToneCurvePV2012")) {
            try AdobeProfileParser.profile(from: ProfileFixture.xmp(extraDescriptionXML: semicolon))
        }
        let cases: [[(Int, Int)]] = [[(10, 0), (5, 255)], [(0, 0)], [(0, 0), (256, 255)], [(0, 0), (0, 255)]]
        for points in cases {
            #expect(throws: ProfileError.malformed("ToneCurvePV2012")) {
                try AdobeProfileParser.profile(from: ProfileFixture.xmp(curves: ["ToneCurvePV2012": points]))
            }
        }
        let spaced = "<crs:ToneCurvePV2012Blue><rdf:Seq><rdf:li> 0 ,0 </rdf:li><rdf:li>\n255,  250</rdf:li></rdf:Seq></crs:ToneCurvePV2012Blue>"
        #expect(try AdobeProfileParser.profile(from: ProfileFixture.xmp(extraDescriptionXML: spaced)).settings
                .toneCurves["ToneCurvePV2012Blue"] == [ProfileCurvePoint(x: 0, y: 0), ProfileCurvePoint(x: 255, y: 250)])
    }

    @Test func digestAndIdentity() throws {
        let data = ProfileFixture.xmp(look: Self.look, rgb: Self.warm)
        let loaded = try LoadedProfile(data: data)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(loaded.digest.hex == hex)
        #expect(loaded.digest == ProfileDigest(of: data))
        #expect(loaded.digest.description == hex)
        #expect(loaded.data == data)
        #expect(ProfileDigest(hex: hex) == loaded.digest)
        #expect(ProfileDigest(hex: String(repeating: "a", count: 64)) != nil)
        #expect(ProfileDigest(hex: String(repeating: "A", count: 64)) == nil)
        #expect(ProfileDigest(hex: String(repeating: "a", count: 63)) == nil)
        #expect(ProfileDigest(hex: String(repeating: "a", count: 63) + "g") == nil)
        let json = try JSONEncoder().encode([loaded.digest])
        #expect(String(decoding: json, as: UTF8.self) == "[\"\(hex)\"]")
        #expect(try JSONDecoder().decode([ProfileDigest].self, from: json) == [loaded.digest])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([ProfileDigest].self, from: Data("[\"XYZ\"]".utf8)) }
        let lookFingerprint = AdobeTableCodec.encodeTable(.look(Self.look)).fingerprint
        let rgbFingerprint = AdobeTableCodec.encodeTable(.rgb(Self.warm)).fingerprint
        #expect(loaded.profile.identity == ProfileIdentity(uuid: Self.uuid, tables: [lookFingerprint, rgbFingerprint].sorted()))
        #expect(throws: ProfileError.notAProfile(presetType: "Normal")) { try LoadedProfile(data: ProfileFixture.xmp(presetType: "Normal")) }
        #expect(try LoadedProfile(data: ProfileFixture.xmp(outputReferred: false)).profile.usability == .rawOnly)
    }

    @Test func errorsDescribeThemselves() {
        #expect(ProfileError.notAProfile(presetType: "Normal").errorDescription == "This is a Lightroom or Camera Raw preset, not a profile.")
        #expect(ProfileError.notAProfile(presetType: nil).errorDescription == "This file isn't a Lightroom or Camera Raw profile.")
        #expect(ProfileError.malformed("UUID").errorDescription == "This isn't a valid Lightroom or Camera Raw profile (UUID).")
        #expect(ProfileError.cameraSpecific("Nikon Z 8").errorDescription == "This profile is made for raw photos from the Nikon Z 8.")
        #expect(ProfileError.notLoaded(name: "Vivid").errorDescription == "The profile “Vivid” isn't loaded.")
        // Cocoa's messages end in a period already.
        #expect(ProfileError.unreadable("The file “A.xmp” couldn’t be opened.").errorDescription
                == "The profile couldn't be read: The file “A.xmp” couldn’t be opened.")
        #expect(ProfileError.unreadable("No file at /tmp/A.xmp").errorDescription == "The profile couldn't be read: No file at /tmp/A.xmp.")
        #expect(ProfileError.malformed("The data isn’t in the correct format.").errorDescription
                == "This isn't a valid Lightroom or Camera Raw profile (The data isn’t in the correct format).")
        #expect(ProfileError.writeFailed("You don’t have permission.").errorDescription
                == "The profile couldn't be copied into Compositor's profile library: You don’t have permission.")
        #expect(ProfileError.writeFailed("Disk full").errorDescription
                == "The profile couldn't be copied into Compositor's profile library: Disk full.")
    }
}
