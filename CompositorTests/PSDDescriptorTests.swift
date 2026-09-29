import Foundation
import CoreGraphics
import Testing
@testable import Compositor

@Suite
struct PSDDescriptorTests {
    private func rgbColor(_ red: Double, _ green: Double, _ blue: Double) -> PSDDescriptor {
        PSDDescriptor(classID: "RGBC", items: [("Rd  ", .double(red)), ("Grn ", .double(green)), ("Bl  ", .double(blue))])
    }

    private var sample: PSDDescriptor {
        PSDDescriptor(classID: "null", items: [
            ("Clr ", .object(rgbColor(255, 110, 0))),
            ("list", .list([
                .object(PSDDescriptor(classID: "null", items: [("enab", .bool(true))])),
                .object(PSDDescriptor(classID: "null", items: [("enab", .bool(false))]))
            ])),
            ("Sz  ", .unitFloat(unit: "#Pxl", value: 24))
        ])
    }

    @Test func encodedDescriptorReadsBackThroughEveryAccessor() throws {
        let data = PSDDescriptorWriter.block(sample)
        var offset = 0
        let read = try PSDDescriptorReader.readBlock(data, at: &offset)
        #expect(offset == data.count)
        #expect(read == sample)
        #expect(read.classID == "null")
        #expect(read.name == "")
        let color = try #require(read.rgb("Clr "))
        #expect(color.r == 255 && color.g == 110 && color.b == 0)
        #expect(read.object("Clr ")?.double("Grn ") == 110)
        let list = try #require(read.list("list"))
        #expect(list.count == 2)
        guard case .object(let first) = list[0], case .object(let second) = list[1] else {
            Issue.record("list items are not objects")
            return
        }
        #expect(first.bool("enab") == true)
        #expect(second.bool("enab") == false)
        let size = try #require(read.unit("Sz  "))
        #expect(size.unit == "#Pxl" && size.value == 24)
        #expect(read["missing"] == nil)
        #expect(read.double("Sz  ") == nil)
    }

    @Test func everyTruncationThrows() throws {
        let data = PSDDescriptorWriter.block(sample)
        for length in 0 ..< data.count {
            var offset = 0
            #expect(throws: PSDError.truncated) {
                try PSDDescriptorReader.readBlock(data.prefix(length), at: &offset)
            }
        }
    }

    @Test func solidColorBlockMatchesPhotoshopBytes() throws {
        let soCo = PSDDescriptor(classID: "null", items: [("Clr ", .object(rgbColor(0, 110, 255)))])
        let expected = try #require(PSDVectorFixtures.circle()["SoCo"])
        #expect(PSDDescriptorWriter.block(soCo) == expected)
        var offset = 0
        #expect(try PSDDescriptorReader.readBlock(expected, at: &offset) == soCo)
    }

    @Test func photoshopStrokeStyleParsesAndReencodesExactly() throws {
        let bytes = try #require(PSDVectorFixtures.rectangle()["vstk"])
        var offset = 0
        let stroke = try PSDDescriptorReader.readBlock(bytes, at: &offset)
        #expect(stroke.classID == "strokeStyle")
        #expect(stroke.int("strokeStyleVersion") == 2)
        #expect(stroke.bool("strokeEnabled") == true)
        #expect(stroke.bool("fillEnabled") == true)
        #expect(stroke.enumValue("strokeStyleLineCapType") == "strokeStyleButtCap")
        #expect(stroke.enumValue("strokeStyleBlendMode") == "Nrml")
        #expect(stroke.list("strokeStyleLineDashSet")?.isEmpty == true)
        #expect(stroke.unit("strokeStyleOpacity")?.unit == "#Prc")
        let content = try #require(stroke.object("strokeStyleContent"))
        #expect(content.classID == "solidColorLayer")
        let color = try #require(content.rgb("Clr "))
        #expect(color.r == 255 && color.g == 255 && color.b == 0)
        let reencoded = PSDDescriptorWriter.block(stroke)
        #expect(reencoded == bytes.prefix(offset))
        #expect(bytes.suffix(from: offset).allSatisfy { $0 == 0 })
    }

    @Test func everyValueTypeRoundTrips() throws {
        let nested = PSDDescriptor(name: "Layer 1", classID: "someLongClassID", items: [("Nm  ", .string("Ünïcødé ✓"))])
        let descriptor = PSDDescriptor(name: "", classID: "Test", items: [
            ("obj1", .object(nested)),
            ("VlLs", .list([.integer(1), .string("two"), .list([.bool(true)])])),
            ("doub", .double(-0.5)),
            ("untF", .unitFloat(unit: "#Ang", value: 90)),
            ("unFl", .unitFloats(unit: "#Pxl", values: [1, 2.5, -3])),
            ("TEXT", .string("Hello")),
            ("empt", .string("")),
            ("enum", .enumerated(type: "BlnM", value: "Nrml")),
            ("longEnumerationKey", .enumerated(type: "strokeStyleLineCapType", value: "strokeStyleButtCap")),
            ("long", .integer(-42)),
            ("comp", .largeInteger(Int64.max)),
            ("bool", .bool(false)),
            ("type", .classRef(name: "", id: "Lyr ")),
            ("alis", .alias(Data([1, 2, 3]))),
            ("tdta", .rawData(Data([0xDE, 0xAD, 0xBE, 0xEF, 0]))),
            ("Pth ", .path(Data([9, 8, 7]))),
            ("GlbO", .globalObject(PSDDescriptor(classID: "null", items: [("xx", .double(1))]))),
            ("GlbC", .globalClass(name: "", id: "Lyr ")),
            ("bad ", .unicodeUnits([0x41, 0xD800, 0])),
            ("noNul", .unicodeUnits([0x41, 0x42])),
        ])
        let data = PSDDescriptorWriter.bare(descriptor)
        var offset = 0
        let read = try PSDDescriptorReader.read(data, at: &offset)
        #expect(offset == data.count)
        #expect(read == descriptor)
        #expect(read.object("obj1")?.name == "Layer 1")
        #expect(read.object("GlbO")?.double("xx") == 1)
        #expect(read.string("noNul") == "AB")
        #expect(read.object("obj1")?.string("Nm  ") == "Ünïcødé ✓")
        #expect(read.int("long") == -42)
        #expect(read.int("comp") == Int(Int64.max))
        #expect(read.string("TEXT") == "Hello")
        #expect(read.enumValue("enum") == "Nrml")
        #expect(read["tdta"] == .rawData(Data([0xDE, 0xAD, 0xBE, 0xEF, 0])))
        #expect(read["unFl"] == .unitFloats(unit: "#Pxl", values: [1, 2.5, -3]))

        let versioned = PSDDescriptorWriter.block2(descriptor, version: 1)
        #expect(Array(versioned.prefix(8)) == [0, 0, 0, 1, 0, 0, 0, 16])
        var versionOffset = 4
        #expect(try PSDDescriptorReader.readBlock(versioned, at: &versionOffset) == descriptor)
    }

    @Test func textCarriesATrailingNulAndFourCharacterKeysHaveZeroLength() throws {
        let data = PSDDescriptorWriter.bare(PSDDescriptor(classID: "null", items: [("Txt ", .string("Hi"))]))
        let expected: [UInt8] = [
            0, 0, 0, 1, 0, 0,                   // name: one NUL character
            0, 0, 0, 0] + Array("null".utf8) + [ // classID, length 0
            0, 0, 0, 1,                         // one item
            0, 0, 0, 0] + Array("Txt ".utf8) + Array("TEXT".utf8) + [
            0, 0, 0, 3, 0, 0x48, 0, 0x69, 0, 0  // "Hi" + NUL
        ]
        #expect(Array(data) == expected)
    }

    @Test func referencesAndObjectArraysSurviveUnchanged() throws {
        var body = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { body.append(contentsOf: $0) } }
        func key(_ string: String) { u32(0); body.append(contentsOf: Array(string.utf8)) }
        func unicode(_ string: String) {
            let units = Array(string.utf16) + [0]
            u32(UInt32(units.count))
            for unit in units { body.append(UInt8(unit >> 8)); body.append(UInt8(unit & 0xFF)) }
        }
        unicode(""); key("null"); u32(2)
        key("null"); body.append(contentsOf: Array("obj ".utf8)); u32(3)
        body.append(contentsOf: Array("Clss".utf8)); unicode(""); key("Dcmn")
        body.append(contentsOf: Array("Enmr".utf8)); unicode(""); key("Lyr "); key("Ordn"); key("Trgt")
        body.append(contentsOf: Array("prop".utf8)); unicode(""); key("Prpr"); key("Lefx")
        key("ObAr"); body.append(contentsOf: Array("ObAr".utf8)); u32(1)
        unicode(""); key("null"); u32(1); key("Hrzn"); body.append(contentsOf: Array("UnFl".utf8))
        body.append(contentsOf: Array("#Pxl".utf8)); u32(2)
        withUnsafeBytes(of: (1.0).bitPattern.bigEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: (2.0).bitPattern.bigEndian) { body.append(contentsOf: $0) }
        var offset = 0
        let read = try PSDDescriptorReader.read(body, at: &offset)
        #expect(offset == body.count)
        guard case .reference(let items)? = read["null"] else {
            Issue.record("reference not parsed")
            return
        }
        #expect(items.count == 3)
        #expect(items.first == .referenceItem(type: "Clss", data: Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0] + Array("Dcmn".utf8))))
        if case .objectArray = read["ObAr"] {} else { Issue.record("object array not parsed") }
        #expect(PSDDescriptorWriter.bare(read) == body)
    }

    @Test func nestingBeyondTheDepthLimitThrows() throws {
        var descriptor = PSDDescriptor(classID: "null", items: [("enab", .bool(true))])
        for _ in 0 ..< 100 { descriptor = PSDDescriptor(classID: "null", items: [("next", .object(descriptor))]) }
        let data = PSDDescriptorWriter.block(descriptor)
        var offset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.readBlock(data, at: &offset) }

        var list = PSDDescriptorValue.bool(true)
        for _ in 0 ..< 100 { list = .list([list]) }
        let listData = PSDDescriptorWriter.bare(PSDDescriptor(classID: "null", items: [("deep", list)]))
        var listOffset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.read(listData, at: &listOffset) }

        var shallow = PSDDescriptor(classID: "null", items: [("enab", .bool(true))])
        for _ in 0 ..< 30 { shallow = PSDDescriptor(classID: "null", items: [("next", .object(shallow))]) }
        var shallowOffset = 0
        #expect(try PSDDescriptorReader.readBlock(PSDDescriptorWriter.block(shallow), at: &shallowOffset) == shallow)
    }

    @Test func hostileCountsAndTypesThrowWithoutAllocating() throws {
        func header(count: UInt32) -> Data {
            var data = Data([0, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            data.append(contentsOf: Array("null".utf8))
            withUnsafeBytes(of: count.bigEndian) { data.append(contentsOf: $0) }
            return data
        }
        var huge = header(count: .max)
        huge.append(Data(count: 64))
        var offset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.readBlock(huge, at: &offset) }

        var hugeList = header(count: 1)
        hugeList.append(contentsOf: [0, 0, 0, 0] + Array("listVlLs".utf8) + [0xFF, 0xFF, 0xFF, 0xFF])
        hugeList.append(Data(count: 32))
        offset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.readBlock(hugeList, at: &offset) }

        var hugeKey = header(count: 1)
        hugeKey.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF, 1, 2, 3])
        offset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.readBlock(hugeKey, at: &offset) }

        var unknown = header(count: 1)
        unknown.append(contentsOf: [0, 0, 0, 0] + Array("abcdXXXX".utf8) + [0, 0, 0, 0])
        offset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.readBlock(unknown, at: &offset) }

        var wrongVersion = PSDDescriptorWriter.block(sample)
        wrongVersion[3] = 15
        offset = 0
        #expect(throws: PSDError.truncated) { try PSDDescriptorReader.readBlock(wrongVersion, at: &offset) }
    }

    @Test func slicedDataReadsRelativeToItsStart() throws {
        var data = Data([1, 2, 3])
        data.append(PSDDescriptorWriter.block(sample))
        let slice = data.dropFirst(3)
        var offset = 0
        #expect(try PSDDescriptorReader.readBlock(slice, at: &offset) == sample)
        #expect(offset == slice.count)
    }

    @Test func malformedShapeDescriptorsFallBackInsteadOfThrowing() throws {
        var extra = PSDVectorFixtures.circle()
        extra["SoCo"] = extra["SoCo"]?.prefix(30)
        extra["vstk"] = Data([0, 0, 0, 16, 0xFF])
        extra["vogk"] = Data([0, 0, 0, 1, 0, 0, 0, 16, 0])
        #expect(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas) == nil)
        #expect(try PSDVector.raster(extra: extra, canvas: PSDVectorFixtures.canvas) == nil)
    }

    /// Photoshop writes some four-character terms (`warp`, `view`) as stringIDs with an explicit
    /// length of 4; they must not be rewritten as charIDs (length 0).
    @Test func explicitLengthFourCharacterKeysReencodeExactly() throws {
        var body = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { body.append(contentsOf: $0) } }
        func stringID(_ string: String) { u32(UInt32(string.utf8.count)); body.append(contentsOf: Array(string.utf8)) }
        func charID(_ string: String) { u32(0); body.append(contentsOf: Array(string.utf8)) }
        func code(_ string: String) { body.append(contentsOf: Array(string.utf8)) }
        func double(_ value: Double) { withUnsafeBytes(of: value.bitPattern.bigEndian) { body.append(contentsOf: $0) } }
        u32(16)
        u32(1); body.append(contentsOf: [0, 0])      // name: one NUL
        stringID("warp")                             // class ID "warp", explicit length 4
        u32(5)
        stringID("warpStyle"); code("enum"); stringID("warpStyle"); stringID("warpNone")
        stringID("warpValue"); code("doub"); double(0)
        stringID("warpPerspective"); code("doub"); double(0)
        stringID("warpPerspectiveOther"); code("doub"); double(0)
        stringID("warpRotate"); code("enum"); charID("Ornt"); charID("Hrzn")
        var offset = 0
        let warp = try PSDDescriptorReader.readBlock(body, at: &offset)
        #expect(offset == body.count)
        #expect(warp.classID.id == "warp" && warp.classID.explicitLength)
        #expect(warp.classID != "warp")
        #expect(warp.enumValue("warpStyle") == "warpNone")
        #expect(warp.enumValue("warpRotate") == "Hrzn")
        #expect(PSDDescriptorWriter.block(warp) == body)

        var view = PSDDescriptor(classID: PSDKey("view", explicitLength: true), items: [
            (PSDKey("view", explicitLength: true), .integer(1)), ("Nm  ", .string("x"))
        ])
        let viewData = PSDDescriptorWriter.bare(view)
        #expect(Array(viewData[6 ..< 10]) == [0, 0, 0, 4])
        var viewOffset = 0
        #expect(try PSDDescriptorReader.read(viewData, at: &viewOffset) == view)
        view.classID = "view"
        #expect(Array(PSDDescriptorWriter.bare(view)[6 ..< 10]) == [0, 0, 0, 0])
    }

    @Test func shortKeysAndLoneSurrogatesSurvive() throws {
        let trnf = PSDDescriptor(classID: "Trnf", items: [("xx", .double(1)), ("tx", .double(-2))])
        let data = PSDDescriptorWriter.bare(trnf)
        var offset = 0
        let read = try PSDDescriptorReader.read(data, at: &offset)
        #expect(read == trnf)
        #expect(read.double("tx") == -2)

        var text = PSDDescriptorWriter.bare(PSDDescriptor(classID: "null", items: [("Txt ", .string("A"))]))
        // Replace "A" with a lone high surrogate: the raw units must survive.
        let at = text.count - 4
        text[at] = 0xD8; text[at + 1] = 0x00
        var textOffset = 0
        let odd = try PSDDescriptorReader.read(text, at: &textOffset)
        #expect(odd["Txt "] == .unicodeUnits([0xD800, 0]))
        #expect(PSDDescriptorWriter.bare(odd) == text)
    }

    /// Every descriptor fixture parses and re-encodes to the same bytes.
    @Test func photoshopFixturesReencodeByteIdentically() throws {
        for fixture in [PSDVectorFixtures.circle(), PSDVectorFixtures.rectangle()] {
            for key in ["SoCo", "vstk"] {
                let bytes = try #require(fixture[key])
                var offset = 0
                let descriptor = try PSDDescriptorReader.readBlock(bytes, at: &offset)
                #expect(PSDDescriptorWriter.block(descriptor) == bytes.prefix(offset), "\(key)")
                #expect(bytes.suffix(from: offset).allSatisfy { $0 == 0 }, "\(key) padding")
            }
        }
        let encoded = PSDDescriptorWriter.block(sample)
        var offset = 0
        #expect(PSDDescriptorWriter.block(try PSDDescriptorReader.readBlock(encoded, at: &offset)) == encoded)
    }
}
