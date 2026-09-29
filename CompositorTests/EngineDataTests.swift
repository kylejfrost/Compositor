import Foundation
import Testing
@testable import Compositor

/// Literal EngineData bytes: text as UTF-8, or explicit byte arrays.
private struct Bytes: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    var bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(stringLiteral value: String) { bytes = Array(value.utf8) }
    init(arrayLiteral elements: UInt8...) { bytes = elements }
}

/// Builds an EngineData string the way Photoshop writes it: `(` + FE FF + UTF-16BE with `\`,
/// `(` and `)` bytes escaped + `)`.
private func engineString(_ text: String) -> Bytes {
    var bytes: [UInt8] = [0x28, 0xFE, 0xFF]
    for unit in text.utf16 {
        for byte in [UInt8(unit >> 8), UInt8(unit & 0xFF)] {
            if byte == 0x5C || byte == 0x28 || byte == 0x29 { bytes.append(0x5C) }
            bytes.append(byte)
        }
    }
    bytes.append(0x29)
    return Bytes(bytes)
}

private func engine(_ parts: [Bytes]) -> Data {
    Data(parts.flatMap(\.bytes))
}

@Suite
struct EngineDataTests {
    /// A realistic but synthetic type-layer EngineData, in Photoshop's tabbed layout.
    private var template: Data {
        engine([
            "\n\n<<\n\t/EngineDict\n\t<<\n\t\t/Editor\n\t\t<<\n\t\t\t/Text ", engineString("Sample Headline\rSecond line\r"), "\n\t\t>>\n",
            "\t\t/ParagraphRun\n\t\t<<\n\t\t\t/DefaultRunData\n\t\t\t<<\n\t\t\t\t/ParagraphSheet\n\t\t\t\t<<\n\t\t\t\t\t/DefaultStyleSheet 0\n\t\t\t\t>>\n\t\t\t>>\n",
            "\t\t\t/RunArray [\n\t\t\t<<\n\t\t\t\t/ParagraphSheet\n\t\t\t\t<<\n\t\t\t\t\t/DefaultStyleSheet 0\n\t\t\t\t\t/Properties\n\t\t\t\t\t<<\n\t\t\t\t\t\t/Justification 2\n\t\t\t\t\t\t/FirstLineIndent 0.0\n\t\t\t\t\t>>\n\t\t\t\t>>\n\t\t\t\t/Adjustments\n\t\t\t\t<<\n\t\t\t\t\t/Axis [ 1.0 0.0 1.0 ]\n\t\t\t\t\t/XY [ 0.0 0.0 ]\n\t\t\t\t>>\n\t\t\t>>\n\t\t\t]\n",
            "\t\t\t/RunLengthArray [ 29 ]\n\t\t\t/IsJoinable 1\n\t\t>>\n",
            "\t\t/StyleRun\n\t\t<<\n\t\t\t/DefaultRunData\n\t\t\t<<\n\t\t\t\t/StyleSheet\n\t\t\t\t<<\n\t\t\t\t\t/StyleSheetData\n\t\t\t\t\t<<\n\t\t\t\t\t>>\n\t\t\t\t>>\n\t\t\t>>\n",
            "\t\t\t/RunArray [\n\t\t\t<<\n\t\t\t\t/StyleSheet\n\t\t\t\t<<\n\t\t\t\t\t/StyleSheetData\n\t\t\t\t\t<<\n",
            "\t\t\t\t\t\t/Font 1\n\t\t\t\t\t\t/FontSize 48.0\n\t\t\t\t\t\t/FauxBold false\n\t\t\t\t\t\t/AutoLeading false\n\t\t\t\t\t\t/Leading 57.6\n\t\t\t\t\t\t/Tracking -25\n\t\t\t\t\t\t/HorizontalScale .5\n\t\t\t\t\t\t/BaselineShift -.25\n",
            "\t\t\t\t\t\t/FillColor\n\t\t\t\t\t\t<<\n\t\t\t\t\t\t\t/Type 1\n\t\t\t\t\t\t\t/Values [ 1.0 .89804 .2 -1.0 ]\n\t\t\t\t\t\t>>\n",
            "\t\t\t\t\t>>\n\t\t\t\t>>\n\t\t\t>>\n\t\t\t<<\n\t\t\t\t/StyleSheet\n\t\t\t\t<<\n\t\t\t\t\t/StyleSheetData\n\t\t\t\t\t<<\n\t\t\t\t\t\t/Font 2\n\t\t\t\t\t\t/FontSize 48.0\n\t\t\t\t\t>>\n\t\t\t\t>>\n\t\t\t>>\n\t\t\t]\n",
            "\t\t\t/RunLengthArray [ 28 1 ]\n\t\t\t/IsJoinable 2\n\t\t>>\n",
            "\t\t/Rendered\n\t\t<<\n\t\t\t/Version 1\n\t\t\t/Shapes\n\t\t\t<<\n\t\t\t\t/WritingDirection 0\n\t\t\t\t/Children [\n\t\t\t\t<<\n\t\t\t\t\t/ShapeType 1\n\t\t\t\t\t/Procession 0\n\t\t\t\t\t/Lines\n\t\t\t\t\t<<\n\t\t\t\t\t\t/WritingDirection 0\n\t\t\t\t\t\t/Children [ ]\n\t\t\t\t\t>>\n",
            "\t\t\t\t\t/Cookie\n\t\t\t\t\t<<\n\t\t\t\t\t\t/Photoshop\n\t\t\t\t\t\t<<\n\t\t\t\t\t\t\t/ShapeType 1\n\t\t\t\t\t\t\t/BoxBounds [ 0.0 0.0 320.5 120.0 ]\n\t\t\t\t\t\t\t/Base\n\t\t\t\t\t\t\t<<\n\t\t\t\t\t\t\t\t/ShapeType 1\n\t\t\t\t\t\t\t\t/TransformPoint0 [ 1.0 0.0 ]\n\t\t\t\t\t\t\t>>\n\t\t\t\t\t\t\t/PointBase [ 0.0 0.0 ]\n\t\t\t\t\t\t>>\n\t\t\t\t\t>>\n\t\t\t\t>>\n\t\t\t\t]\n\t\t\t>>\n\t\t>>\n\t>>\n",
            "\t/ResourceDict\n\t<<\n\t\t/KinsokuSet [\n\t\t<<\n\t\t\t/Name ", engineString("PhotoshopKinsokuHard"), "\n\t\t\t/NoStart ", engineString("\u{3001}()\\"), "\n\t\t>>\n\t\t]\n",
            "\t\t/FontSet [\n\t\t<<\n\t\t\t/Name ", engineString("AdobeInvisFont"), "\n\t\t\t/Script 0\n\t\t\t/FontType 0\n\t\t\t/Synthetic 0\n\t\t>>\n",
            "\t\t<<\n\t\t\t/Name ", engineString("NoSuchSans-Bold"), "\n\t\t\t/Script 0\n\t\t\t/FontType 1\n\t\t\t/Synthetic 0\n\t\t>>\n",
            "\t\t<<\n\t\t\t/Name ", engineString("NoSuchSerif-Italic"), "\n\t\t\t/Script 0\n\t\t\t/FontType 1\n\t\t\t/Synthetic 0\n\t\t>>\n\t\t]\n",
            "\t\t/SuperscriptSize .583\n\t\t/SmallCapSize .7\n\t>>\n",
            "\t/DocumentResources\n\t<<\n\t\t/FontSet [ ]\n\t>>\n>>",
            [0x00, 0x00, 0x00]
        ])
    }

    private func parse(_ text: String) throws -> EngineValue {
        try EngineDataParser.parse(Data(text.utf8))
    }

    private func expectMalformed(_ data: Data, at expected: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let value = try EngineDataParser.parse(data)
            Issue.record("parsed \(value) instead of throwing", sourceLocation: sourceLocation)
        } catch let error as EngineDataError {
            #expect(error == .malformed(offset: expected), sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Scalars and containers

    @Test func parsesDictionariesArraysAndScalars() throws {
        let value = try parse("<< /Int 42 /Neg -7 /Dbl 1.5 /Half .5 /NegQuarter -.25 /NegOne -1.0 /Yes true /No false /List [ 1 2.0 [ 3 ] << /A 1 >> ] /Empty << >> /None [ ] >>")
        #expect(value["Int"] == .integer(42))
        #expect(value["Neg"] == .integer(-7))
        #expect(value["Dbl"] == .number(1.5))
        #expect(value["Half"] == .number(0.5))
        #expect(value["NegQuarter"] == .number(-0.25))
        #expect(value["NegOne"] == .number(-1.0))
        #expect(value["Yes"] == .bool(true))
        #expect(value["No"] == .bool(false))
        #expect(value["List"] == .array([.integer(1), .number(2), .array([.integer(3)]), .dictionary([(key: "A", value: .integer(1))])]))
        #expect(value["Empty"] == .dictionary([]))
        #expect(value["None"] == .array([]))
        #expect(value["Missing"] == nil)
    }

    @Test func accessorsConvertOnlyMatchingCases() throws {
        let value = try parse("<< /I 3 /D 2.5 /B true /S (x y) /A [ 1 ] >>")
        #expect(value["I"]?.int == 3)
        #expect(value["I"]?.double == 3)
        #expect(value["D"]?.double == 2.5)
        #expect(value["D"]?.int == nil)
        #expect(value["B"]?.bool == true)
        #expect(value["I"]?.bool == nil)
        #expect(value["A"]?.array == [.integer(1)])
        #expect(value["I"]?.array == nil)
        #expect(value["I"]?.string == nil)
        #expect(value["S"]?.string == "x y")
        #expect(value.int == nil)
    }

    @Test func dictionariesKeepOrderAndDuplicatesAndLookupFindsTheFirst() throws {
        let value = try parse("<< /B 1 /A 2 /B 3 >>")
        guard case .dictionary(let items) = value else {
            Issue.record("top level is not a dictionary")
            return
        }
        #expect(items.map(\.key) == ["B", "A", "B"])
        #expect(value["B"] == .integer(1))
        #expect(value != (try parse("<< /A 2 /B 1 /B 3 >>")))
        #expect(value == (try parse("<<\n/B 1\n/A 2\n/B 3\n>>")))
    }

    @Test func equalityDistinguishesCases() {
        #expect(EngineValue.integer(1) != .number(1))
        #expect(EngineValue.string("a") != .tag("a"))
        #expect(EngineValue.array([.integer(1)]) != .array([.integer(1), .integer(1)]))
        #expect(EngineValue.dictionary([(key: "A", value: .integer(1))]) != .dictionary([(key: "A", value: .integer(2))]))
        #expect(EngineValue.dictionary([(key: "A", value: .integer(1))]) != .dictionary([(key: "B", value: .integer(1))]))
    }

    @Test func keysAcceptPunctuationAndMacRoman() throws {
        let value = try EngineDataParser.parse(Data([0x3C, 0x3C, 0x20, 0x2F, 0x61, 0x2D, 0x62, 0x2E, 0x63, 0x8E, 0x20, 0x31, 0x20, 0x3E, 0x3E]))
        #expect(value["a-b.c\u{E9}"] == .integer(1))
    }

    @Test func containersNeedNoSurroundingWhitespace() throws {
        let value = try parse("<</A[1 2]/B<</C true>>/D(x y)>>")
        #expect(value["A"] == .array([.integer(1), .integer(2)]))
        #expect(value[path: "B.C"] == .bool(true))
        #expect(value["D"] == .string("x y"))
    }

    @Test func whitespaceIncludesCarriageReturnsAndLeadingAndTrailingNULs() throws {
        let data = engine([[0x00, 0x0D, 0x0A, 0x09, 0x20], "<<\r/A\t1\r\n>>", [0x00, 0x00, 0x0A, 0x00]])
        #expect(try EngineDataParser.parse(data) == .dictionary([(key: "A", value: .integer(1))]))
    }

    @Test func offsetsAreRelativeToTheSliceStart() throws {
        let data = Data("xxxx<< /A 1 /B >>".utf8)
        do {
            _ = try EngineDataParser.parse(data[4...])
            Issue.record("did not throw")
        } catch let error as EngineDataError {
            #expect(error == .malformed(offset: 11))
        }
        #expect(try EngineDataParser.parse(Data("xx<< /A 1 >>".utf8)[2...])["A"] == .integer(1))
    }

    @Test func hugeIntegersBecomeDoubles() throws {
        let value = try parse("<< /Big 99999999999999999999999 /Small -99999999999999999999999 >>")
        #expect(value["Big"] == .number(Double("99999999999999999999999")!))
        #expect(value["Small"] == .number(-Double("99999999999999999999999")!))
        #expect(value["Big"]?.int == nil)
    }

    @Test func unknownBarewordsAndParenthesizedWordsAreTags() throws {
        let value = try parse("<< /A (hwid) /B --(.-0 /C null /D [ (fwid) (aalt) ] /E () >>")
        #expect(value["A"] == .tag("(hwid)"))
        #expect(value["B"] == .tag("--(.-0"))
        #expect(value["C"] == .tag("null"))
        #expect(value["D"] == .array([.tag("(fwid)"), .tag("(aalt)")]))
        #expect(value["E"] == .tag("()"))
    }

    @Test func nonMatchingNumberLikeBarewordsAreTags() throws {
        // Matches psd-tools: a bareword that almost looks numeric but doesn't fit the grammar
        // (a trailing dot with no fraction, a lone sign, exponent notation) is kept as a tag.
        let value = try parse("<< /Dot 1. /Sign - /Exp 1e5 >>")
        #expect(value["Dot"] == .tag("1."))
        #expect(value["Sign"] == .tag("-"))
        #expect(value["Exp"] == .tag("1e5"))
    }

    @Test func stringsMayContainGreaterThanGreaterThanBytes() throws {
        let latin = try EngineDataParser.parse(Data("<< /S (a >> b) /After 1 >>".utf8))
        #expect(latin["S"] == .string("a >> b"))
        #expect(latin["After"] == .integer(1))
        let utf16 = try EngineDataParser.parse(engine(["<< /S ", engineString("a >> b"), " /After 1 >>"]))
        #expect(utf16["S"] == .string("a >> b"))
        #expect(utf16["After"] == .integer(1))
    }

    @Test func namesInValuePositionAreTags() throws {
        let value = try parse("<< /Type /CoolTypeFont /List [ /A /B ] /Next 1 >>")
        #expect(value["Type"] == .tag("/CoolTypeFont"))
        #expect(value["List"] == .array([.tag("/A"), .tag("/B")]))
        #expect(value["Next"] == .integer(1))
        expectMalformed(Data("<< /A / >>".utf8), at: 6)
    }

    // MARK: Strings

    @Test func utf16StringsDecodeWithEscapesInsideCodeUnits() throws {
        // U+005C, U+0028, U+0029 put an escaped byte in the low half; U+5C28 and U+2829 put
        // escaped bytes in both halves; U+1F600 is a surrogate pair.
        let text = "a\\b(c)d\u{5C28}\u{2829}\u{29}\u{1F600}\r"
        let value = try EngineDataParser.parse(engine(["<< /Text ", engineString(text), " /After 1 >>"]))
        #expect(value["Text"] == .string(text))
        #expect(value["After"] == .integer(1))
    }

    @Test func emptyUTF16StringIsAnEmptyString() throws {
        #expect(try EngineDataParser.parse(engine(["<< /S ", engineString(""), " >>"]))["S"] == .string(""))
    }

    @Test func stringsWithoutABOMDecodeAsLatin1() throws {
        let value = try EngineDataParser.parse(engine(["<< /S (a b\\)c\\\\", [0xE9], ") >>"]))
        #expect(value["S"] == .string("a b)c\\\u{E9}"))
    }

    @Test func otherBackslashPairsAreKeptLiterally() throws {
        let value = try EngineDataParser.parse(engine(["<< /S (", [0xFE, 0xFF, 0x00, 0x5C, 0x6E, 0x00], ") >>"]))
        // Bytes 00 5C 6E 00 → U+005C U+6E00.
        #expect(value["S"] == .string("\\\u{6E00}"))
    }

    @Test func rawStringBytesAreRecoverable() throws {
        let data = engine(["<< /S ", [0x28, 0xFE, 0xFF, 0xD8, 0x3D, 0x00, 0x78, 0x29], " >>"])
        // A lone surrogate decodes lossily; the exact bytes remain available.
        let start = 6
        let raw = try EngineDataParser.stringBytes(in: data, at: start)
        #expect(raw.bytes == [0xFE, 0xFF, 0xD8, 0x3D, 0x00, 0x78])
        #expect(raw.end == data.count - 3)
        #expect(try EngineDataParser.parse(data)["S"] == .string("\u{FFFD}x"))
    }

    // MARK: Paths

    @Test func realisticTemplateResolvesPaths() throws {
        let value = try EngineDataParser.parse(template)
        #expect(value[path: "EngineDict.Editor.Text"]?.string == "Sample Headline\rSecond line\r")
        let paragraphs = try #require(value[path: "EngineDict.ParagraphRun.RunArray"]?.array)
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0][path: "ParagraphSheet.Properties.Justification"]?.int == 2)
        #expect(value[path: "EngineDict.ParagraphRun.RunArray.0.ParagraphSheet.Properties.Justification"] == .integer(2))
        #expect(value[path: "EngineDict.ParagraphRun.RunLengthArray"] == .array([.integer(29)]))

        let styles = try #require(value[path: "EngineDict.StyleRun.RunArray"]?.array)
        #expect(styles.count == 2)
        let first = try #require(styles[0][path: "StyleSheet.StyleSheetData"])
        #expect(first["Font"]?.int == 1)
        #expect(first["FontSize"]?.double == 48)
        #expect(first["AutoLeading"]?.bool == false)
        #expect(first["Leading"]?.double == 57.6)
        #expect(first["Tracking"]?.double == -25)
        #expect(first["HorizontalScale"]?.double == 0.5)
        #expect(first["BaselineShift"]?.double == -0.25)
        #expect(first[path: "FillColor.Type"]?.int == 1)
        #expect(first[path: "FillColor.Values"]?.array?.compactMap(\.double) == [1, 0.89804, 0.2, -1])
        #expect(value[path: "EngineDict.StyleRun.RunArray.1.StyleSheet.StyleSheetData.Font"]?.int == 2)
        #expect(value[path: "EngineDict.StyleRun.RunLengthArray"]?.array?.compactMap(\.int) == [28, 1])

        let shape = try #require(value[path: "EngineDict.Rendered.Shapes.Children.0"])
        #expect(shape["ShapeType"]?.int == 1)
        #expect(shape[path: "Cookie.Photoshop.ShapeType"]?.int == 1)
        #expect(shape[path: "Cookie.Photoshop.PointBase"] == .array([.number(0), .number(0)]))
        #expect(shape[path: "Cookie.Photoshop.BoxBounds"]?.array?.compactMap(\.double) == [0, 0, 320.5, 120])

        let fonts = try #require(value[path: "ResourceDict.FontSet"]?.array)
        #expect(fonts.compactMap { $0["Name"]?.string } == ["AdobeInvisFont", "NoSuchSans-Bold", "NoSuchSerif-Italic"])
        #expect(fonts.compactMap { $0["FontType"]?.int } == [0, 1, 1])
        #expect(fonts.compactMap { $0["Script"]?.int } == [0, 0, 0])
        #expect(fonts.compactMap { $0["Synthetic"]?.int } == [0, 0, 0])
        #expect(value[path: "ResourceDict.KinsokuSet.0.NoStart"]?.string == "\u{3001}()\\")
        #expect(value[path: "ResourceDict.SuperscriptSize"]?.double == 0.583)
        #expect(value[path: "DocumentResources.FontSet"] == .array([]))
    }

    @Test func pathLookupMissesReturnNil() throws {
        let value = try EngineDataParser.parse(template)
        #expect(value[path: "EngineDict.Nope"] == nil)
        #expect(value[path: "EngineDict.StyleRun.RunArray.2"] == nil)
        #expect(value[path: "EngineDict.StyleRun.RunArray.-1"] == nil)
        #expect(value[path: "EngineDict.Editor.Text.More"] == nil)
        #expect(value[path: "EngineDict..Editor"] == nil)
        #expect(value[path: ""] == value)
    }

    // MARK: Limits and malformed input

    @Test func depthIsLimitedTo64() throws {
        let ok = String(repeating: "<< /A ", count: 63) + "<< >>" + String(repeating: " >>", count: 63)
        _ = try parse(ok)
        let okArrays = "<< /A " + String(repeating: "[ ", count: 63) + String(repeating: "] ", count: 63) + ">>"
        _ = try parse(okArrays)
        let deepPrefix = String(repeating: "<< /A ", count: 64)
        let deep = deepPrefix + "<< >>" + String(repeating: " >>", count: 64)
        #expect(throws: EngineDataError.depth(offset: deepPrefix.utf8.count)) { try parse(deep) }
        let deepArraysPrefix = "<< /A " + String(repeating: "[ ", count: 63)
        let deepArrays = "<< /A " + String(repeating: "[ ", count: 64) + String(repeating: "] ", count: 64) + ">>"
        #expect(throws: EngineDataError.depth(offset: deepArraysPrefix.utf8.count)) { try parse(deepArrays) }
        let hostile = String(repeating: "[", count: 1_000_000)
        #expect(throws: EngineDataError.self) { try parse("<< /A " + hostile) }
    }

    @Test func unterminatedStringsThrowWithTheirOffset() {
        let utf16 = engine(["<< /S (", [0xFE, 0xFF, 0x00, 0x41, 0x5C, 0x29], " >>"])
        #expect(throws: EngineDataError.unterminatedString(offset: 6)) { try EngineDataParser.parse(utf16) }
        let latin = Data("<< /A 1 /S (abc >>".utf8)
        #expect(throws: EngineDataError.unterminatedString(offset: 11)) { try EngineDataParser.parse(latin) }
        let trailingEscape = engine(["<< /S (", [0xFE, 0xFF, 0x5C]])
        #expect(throws: EngineDataError.unterminatedString(offset: 6)) { try EngineDataParser.parse(trailingEscape) }
    }

    @Test func oddUTF16LengthIsMalformedAtTheString() {
        expectMalformed(engine(["<< /S (", [0xFE, 0xFF, 0x00, 0x41, 0x42], ") >>"]), at: 6)
    }

    @Test func malformedInputsThrowWithOffsets() {
        expectMalformed(Data(), at: 0)
        expectMalformed(Data("  \n".utf8), at: 3)
        expectMalformed(Data("[ 1 ]".utf8), at: 0)
        expectMalformed(Data("<< /A 1".utf8), at: 7)          // unterminated dictionary
        expectMalformed(Data("<< /A [ 1 2".utf8), at: 11)     // unterminated array
        expectMalformed(Data("<< /A >>".utf8), at: 6)         // key without a value
        expectMalformed(Data("<< 5 >>".utf8), at: 3)          // value in key position
        expectMalformed(Data("<< / 1 >>".utf8), at: 3)        // empty key
        expectMalformed(Data("<< /A ] >>".utf8), at: 6)       // stray array end
        expectMalformed(Data("<< /A 1 ] >>".utf8), at: 8)
        expectMalformed(Data("<< /A [ >> ] >>".utf8), at: 8)
        expectMalformed(Data("<< /A < >>".utf8), at: 6)       // lone angle bracket
        expectMalformed(Data("<< /A ) >>".utf8), at: 6)
        expectMalformed(Data("<< /A 1 >> junk".utf8), at: 11) // trailing content
        expectMalformed(Data("<< /A 1 >> <<>>".utf8), at: 11)
    }

    @Test func everyTruncationOfTheTemplateThrowsWithoutCrashing() {
        let bytes = [UInt8](template)
        let closing = bytes.lastIndex(of: 0x3E)! + 1
        for length in 0 ..< closing {
            #expect(throws: EngineDataError.self) { try EngineDataParser.parse(Data(bytes[0 ..< length])) }
        }
        for length in closing ... bytes.count {
            #expect((try? EngineDataParser.parse(Data(bytes[0 ..< length]))) != nil)
        }
    }

    @Test func randomBytesNeverCrash() {
        var generator = SplitMix64(seed: 0xE9_61_4E_D4_7A)
        let alphabet = Array("<>[]()/\\ \n\t0123456789.-truefalsAZ".utf8) + [0x00, 0xFE, 0xFF]
        for _ in 0 ..< 2_000 {
            let count = Int.random(in: 0 ..< 200, using: &generator)
            var bytes: [UInt8] = [0x3C, 0x3C]
            for _ in 0 ..< count { bytes.append(alphabet.randomElement(using: &generator)!) }
            _ = try? EngineDataParser.parse(Data(bytes))
        }
        let template = [UInt8](template)
        for _ in 0 ..< 500 {
            var bytes = template
            for _ in 0 ..< 4 {
                bytes[Int.random(in: 0 ..< bytes.count, using: &generator)] = UInt8.random(in: 0 ... 255, using: &generator)
            }
            _ = try? EngineDataParser.parse(Data(bytes))
        }
    }

    @Test func largeFlatInputParses() throws {
        let items = String(repeating: "1.5 -2 ", count: 200_000)
        let value = try parse("<< /A [ \(items)] >>")
        #expect(value["A"]?.array?.count == 400_000)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
