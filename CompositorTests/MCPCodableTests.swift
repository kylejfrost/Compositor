import Foundation
import Testing
import MCP
@testable import Compositor

/// A settings value with every shape `decodeMerged` has to handle: a camelCase member, an array, a nested
/// struct, an optional nested struct, an optional scalar, a flat red/green/blue color, a nested struct that
/// stores its color flat beside other fields (as every effect does) and a nested color of just red/green/blue.
private struct Sample: MCPPatchable, Equatable {
    struct Inner: Codable, Equatable {
        var amount: Double = 1
        var label: String? = "inner"
    }
    struct Swatch: Codable, Equatable {
        var red: Double = 0
        var green: Double = 0
        var blue: Double = 0
        var opacity: Double = 1
    }
    struct Tint: Codable, Equatable {
        var red: Double = 0
        var green: Double = 0
        var blue: Double = 0
    }
    var title = "Sample"
    var fillAmount: Double = 0.5
    var points: [Double] = [1, 2, 3]
    var inner = Inner()
    var extra: Inner? = nil
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
    var swatch = Swatch()
    var tint = Tint()
    var isValid: Bool { (0...10).contains(inner.amount) && (0...1).contains(fillAmount) }
    static let mcpFieldRanges: [String: ClosedRange<Double>] = ["inner.amount": 0...10, "fill_amount": 0...1]
}

/// `MCPCodable.decodeMerged`: patches settings structs through their snake_case JSON form.
struct MCPCodableTests {
    /// The error `body` throws, which must be an `invalid_argument` tool error.
    private func invalidArgument(_ body: () throws -> Sample) -> MCPToolError? {
        do {
            let value = try body()
            Issue.record("Expected invalid_argument, got \(value)")
            return nil
        } catch let error as MCPToolError {
            #expect(error.code == .invalidArgument, "Expected invalid_argument, got \(error.code): \(error.message)")
            return error
        } catch {
            Issue.record("Expected an MCPToolError, got \(error)")
            return nil
        }
    }

    @Test func objectsMergeArraysReplaceAndNullDeletesOptionalMembers() throws {
        let merged = try MCPCodable.decodeMerged(Sample(), ["fill_amount": 0.25, "points": [9], "inner": ["amount": 4, "label": nil]])
        #expect(merged.fillAmount == 0.25)
        #expect(merged.points == [9])
        #expect(merged.inner == Sample.Inner(amount: 4, label: nil))
        #expect(merged.title == "Sample")
        #expect(try MCPCodable.decodeMerged(merged, [:]) == merged)
    }

    @Test func aMemberThePatchIntroducesStartsFromTheTemplate() throws {
        let template = Sample(extra: Sample.Inner(amount: 5, label: "template"))
        let merged = try MCPCodable.decodeMerged(Sample(), ["extra": ["amount": 2]], template: template)
        #expect(merged.extra == Sample.Inner(amount: 2, label: "template"))
        // Without a template the new member has only what the patch gives, so a required field is missing.
        let error = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["extra": ["label": "x"]]) }
        #expect(error?.message.contains("extra.amount") == true, "\(String(describing: error?.message))")
        // Removing an optional member works whether or not it was there.
        #expect(try MCPCodable.decodeMerged(Sample(extra: Sample.Inner()), ["extra": nil]).extra == nil)
        #expect(try MCPCodable.decodeMerged(Sample(), ["extra": nil]) == Sample())
    }

    @Test func colorShorthandExpandsToRedGreenBlue() throws {
        let hex = try MCPCodable.decodeMerged(Sample(), ["color": "#ff8000"])
        #expect(hex.red == 1 && hex.green == 128.0 / 255 && hex.blue == 0)
        let object = try MCPCodable.decodeMerged(Sample(), ["color": ["r": 0, "g": 1, "b": 0.5]])
        #expect(object.red == 0 && object.green == 1 && object.blue == 0.5)
        let error = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["color": "red"]) }
        #expect(error?.message.contains("color") == true)
    }

    @Test func onlyAWholeColorIsShorthand() throws {
        // A nested color of just red/green/blue takes the shorthand whole, and its own fields merge one by one.
        let tint = try MCPCodable.decodeMerged(Sample(), ["tint": ["r": 1, "g": 0.5]])
        #expect(tint.tint == Sample.Tint(red: 1, green: 0.5, blue: 0))
        #expect(try MCPCodable.decodeMerged(Sample(), ["tint": "#00ff00"]).tint == Sample.Tint(red: 0, green: 1, blue: 0))
        #expect(try MCPCodable.decodeMerged(tint, ["tint": ["blue": 1]]).tint == Sample.Tint(red: 1, green: 0.5, blue: 1))
        // A struct that stores its color flat beside other fields takes its color as `color`, keeping the rest.
        let swatch = try MCPCodable.decodeMerged(Sample(), ["swatch": ["color": ["r": 1], "opacity": 0.5]])
        #expect(swatch.swatch == Sample.Swatch(red: 1, green: 0, blue: 0, opacity: 0.5))

        // Stray r/g/b beside another field are unknown fields, not a color that drops the other field.
        let mixed = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["swatch": ["r": 1, "g": 0, "b": 0, "opacity": 0.5]]) }
        #expect(mixed?.details["field"] == .string("swatch.b"), "\(String(describing: mixed?.message))")
        #expect(mixed?.hint?.contains("color") == true, "\(String(describing: mixed?.hint))")
        let tintMixed = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["tint": ["r": 1, "opacity": 0.5]]) }
        #expect(tintMixed?.details["field"] == .string("tint.opacity"), "\(String(describing: tintMixed?.message))")
        // A color value can't carry other fields either.
        let colorMixed = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["swatch": ["color": ["r": 1, "opacity": 0.5]]]) }
        #expect(colorMixed?.details["field"] == .string("swatch.color.opacity"), "\(String(describing: colorMixed?.message))")
        #expect(invalidArgument { try MCPCodable.decodeMerged(Sample(), ["color": [:]]) } != nil)
        // A whole struct given as a color is a type error, not "set its color".
        let whole = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["swatch": "#ff0000"]) }
        #expect(whole?.details["field"] == .string("swatch"), "\(String(describing: whole?.message))")
        // `color` where nothing stores a color is unknown; with red/green/blue too it says the color twice.
        let noColor = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["inner": ["color": "#ffffff"]]) }
        #expect(noColor?.details["field"] == .string("inner.color"), "\(String(describing: noColor?.message))")
        let twice = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["color": "#ff0000", "red": 0.5]) }
        #expect(twice?.details["field"] == .string("color"), "\(String(describing: twice?.message))")
        let nullColor = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["swatch": ["color": nil]]) }
        #expect(nullColor?.details["field"] == .string("swatch.color"), "\(String(describing: nullColor?.message))")
    }

    @Test func nullOnAFieldTheModelLacksIsUnknown() throws {
        let top = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["nope": nil]) }
        #expect(top?.message.contains("Unknown field 'nope'") == true, "\(String(describing: top?.message))")
        #expect(top?.hint?.contains("extra") == true, "An unset optional member is still a field: \(String(describing: top?.hint))")
        let nested = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["inner": ["lable": nil]]) }
        #expect(nested?.details["field"] == .string("inner.lable"), "\(String(describing: nested?.message))")
        // Removing a real optional member or field that is already unset still works, with or without a template.
        let unset = try MCPCodable.decodeMerged(Sample(), ["inner": ["label": nil]])
        #expect(try MCPCodable.decodeMerged(unset, ["inner": ["label": nil], "extra": nil]) == unset)
    }

    @Test func outOfRangeNamesTheFieldAndItsRange() throws {
        let error = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["inner": ["amount": 11]]) }
        #expect(error?.message.contains("inner.amount") == true && error?.message.contains("0–10") == true,
                "\(String(describing: error?.message))")
        #expect(error?.details["field"] == .string("inner.amount"))
        let fraction = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["fill_amount": 1.5]) }
        #expect(fraction?.message.contains("fill_amount") == true && fraction?.message.contains("0–1") == true,
                "\(String(describing: fraction?.message))")
    }

    @Test func wrongTypesUnknownFieldsAndRequiredNullsNameTheField() throws {
        let type = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["inner": ["amount": "lots"]]) }
        #expect(type?.message.contains("inner.amount") == true, "\(String(describing: type?.message))")
        let unknown = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["inner": ["amont": 3]]) }
        #expect(unknown?.message.contains("inner.amont") == true, "\(String(describing: unknown?.message))")
        let required = invalidArgument { try MCPCodable.decodeMerged(Sample(), ["title": nil]) }
        #expect(required?.message.contains("title") == true, "\(String(describing: required?.message))")
        let notObject = invalidArgument { try MCPCodable.decodeMerged(Sample(), "size") }
        #expect(notObject != nil)
    }
}

/// A settings value with enum members: an enum value, a dictionary keyed by an enum (which `Codable` writes as an
/// array alternating key and value) and an array whose elements have a range, as adjustment settings have.
private struct Toned: MCPPatchable, Equatable {
    enum Tone: String, Codable, CaseIterable { case deepShadows = "Deep Shadows", highlights = "Highlights" }
    struct Amount: Codable, Equatable {
        var level: Double = 0
        var boost: Double = 0
    }
    var tone: Tone = .highlights
    var amounts: [Tone: Amount] = [.highlights: Amount(level: 1)]
    var curve: [Double] = [0, 1]
    var isValid: Bool {
        amounts.values.allSatisfy { (0...10).contains($0.level) } && curve.allSatisfy { (0...1).contains($0) } && curve.first == 0
    }
    var mcpInvalidReason: String? { curve.first == 0 ? nil : "The curve must start at 0." }
    static let mcpFieldRanges: [String: ClosedRange<Double>] = [
        "amounts.deep_shadows.level": 0...10, "amounts.highlights.level": 0...10, "curve[]": 0...1,
    ]
    static let mcpEnumMembers: [String: [String]] = ["tone": Tone.allCases.map(\.rawValue), "amounts.*": Tone.allCases.map(\.rawValue)]
}

/// `MCPCodable` with enum members: agents see and send each by its snake_case name, and an enum-keyed dictionary
/// as an object.
struct MCPCodableEnumTests {
    private let everyAmount = Toned(amounts: [.deepShadows: Toned.Amount(), .highlights: Toned.Amount()])

    private func invalidArgument(_ body: () throws -> Toned) -> MCPToolError? {
        do {
            let value = try body()
            Issue.record("Expected invalid_argument, got \(value)")
            return nil
        } catch let error as MCPToolError {
            #expect(error.code == .invalidArgument, "Expected invalid_argument, got \(error.code): \(error.message)")
            return error
        } catch {
            Issue.record("Expected an MCPToolError, got \(error)")
            return nil
        }
    }

    @Test func enumsReadBySnakeCaseNames() throws {
        #expect(MCPCodable.enumName("Black & White") == "black_white")
        #expect(MCPCodable.enumName("Hue/Saturation") == "hue_saturation")
        #expect(MCPCodable.enumName("RGB") == "rgb")
        let form = try MCPCodable.agentForm(Toned()).objectValue
        #expect(form?["tone"] == .string("highlights"))
        #expect(MCPValues.number(form?["amounts"]?.objectValue?["highlights"]?.objectValue?["level"]) == 1, "\(String(describing: form))")
    }

    @Test func enumValuesAndKeysMatchLoosely() throws {
        let merged = try MCPCodable.decodeMerged(Toned(), ["tone": "DEEP shadows", "amounts": ["Deep Shadows": ["level": 3]]],
                                                 template: everyAmount)
        #expect(merged.tone == .deepShadows)
        #expect(merged.amounts == [.deepShadows: Toned.Amount(level: 3, boost: 0), .highlights: Toned.Amount(level: 1)])
        // An entry merges field by field, and null removes it.
        let boosted = try MCPCodable.decodeMerged(merged, ["amounts": ["highlights": ["boost": 2], "deep_shadows": nil]])
        #expect(boosted.amounts == [.highlights: Toned.Amount(level: 1, boost: 2)])
        let twice = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["amounts": ["highlights": ["level": 2], "Highlights": ["level": 3]]]) }
        #expect(twice?.message.contains("twice") == true, "\(String(describing: twice?.message))")
    }

    @Test func unknownNamesAndBadEntriesNameTheField() throws {
        let key = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["amounts": ["midtones": ["level": 1]]], template: everyAmount) }
        #expect(key?.details["field"] == .string("amounts.midtones"), "\(String(describing: key?.message))")
        #expect(key?.hint?.contains("deep_shadows") == true, "\(String(describing: key?.hint))")
        let value = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["tone": "midtones"]) }
        #expect(value?.details["field"] == .string("tone") && value?.message.contains("deep_shadows, highlights") == true,
                "\(String(describing: value?.message))")
        let type = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["amounts": ["highlights": ["level": "high"]]]) }
        #expect(type?.details["field"] == .string("amounts.highlights.level"), "\(String(describing: type?.message))")
        let range = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["amounts": ["highlights": ["level": 11]]]) }
        #expect(range?.details["field"] == .string("amounts.highlights.level") && range?.message.contains("0–10") == true,
                "\(String(describing: range?.message))")
    }

    @Test func arrayElementsHaveRangesAndTheModelExplainsTheRest() throws {
        let element = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["curve": [0, 2]]) }
        #expect(element?.details["field"] == .string("curve[1]") && element?.message.contains("0–1") == true,
                "\(String(describing: element?.message))")
        let reason = invalidArgument { try MCPCodable.decodeMerged(Toned(), ["curve": [0.5, 1]]) }
        #expect(reason?.message == "The curve must start at 0.", "\(String(describing: reason?.message))")
    }
}
