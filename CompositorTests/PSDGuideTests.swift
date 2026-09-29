import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Photoshop guides (resource 1032) import into a new document; light angle/altitude (1037/1049), alpha channel
/// names (1006/1045) and the ICC profile description (1039) decode through `PSDResources` (Task 2.6).
@MainActor
@Suite(.serialized)
struct PSDGuideTests {
    private func colorImage(width: Int = 2, height: Int = 2) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func layer(_ name: String = "Layer") throws -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        record.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        record.image = try colorImage()
        return record
    }

    private func file(resources: [PSDImageResource], resolution: Double = 72) throws -> Data {
        let extras = PSDDocumentExtras(resources: resources)
        return try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: resolution, layers: [try layer()], extras: extras),
                                   composite: try colorImage(width: 4, height: 2))
    }

    // MARK: Guides

    @Test func guidesAt64AndOneThirdThreeAndAHalfRoundTripWithTheRightAxes() throws {
        let resource = PSDFixture.guidesResource(vertical: [64], horizontal: [33.5])
        let document = try PSDReader.read(try file(resources: [resource]))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.guides.count == 2)
        let vertical = try #require(imported.guides.first { $0.axis == .vertical })
        let horizontal = try #require(imported.guides.first { $0.axis == .horizontal })
        #expect(vertical.position == 64)
        #expect(horizontal.position == 33.5)

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Guides")
        #expect(session.document?.guides.count == 2)
        #expect(session.document?.guides.contains { $0.axis == .vertical && $0.position == 64 } == true)
        #expect(session.document?.guides.contains { $0.axis == .horizontal && $0.position == 33.5 } == true)
    }

    @Test func insertingIntoAnExistingDocumentAddsNoGuides() throws {
        let resource = PSDFixture.guidesResource(vertical: [64], horizontal: [33.5])
        let document = try PSDReader.read(try file(resources: [resource]))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(!imported.guides.isEmpty)

        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        try session.insertPhotoshop(imported, named: "Guides")
        #expect(session.document?.guides.isEmpty == true)
    }

    @Test func resolutionFlowsThroughToTheDocument() throws {
        let document = try PSDReader.read(try file(resources: [], resolution: 300))
        #expect(document.resolution == 300)
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.resolution == 300)
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Guides")
        #expect(session.document?.resolution == 300)
    }

    @Test func guidesOutsideAMillionPixelsAreDropped() {
        let resource = PSDFixture.guidesResource(vertical: [2_000_000], horizontal: [-2_000_000])
        #expect(PSDResources.parseGuides(resource.data).isEmpty)
        // Not malformed: the header and every entry read cleanly, they just land out of range.
        #expect(!PSDResources.guidesAreMalformed(resource.data))
    }

    @Test func aGuideCountLargerThanTheDataIsCapped() {
        var resource = PSDFixture.guidesResource(vertical: [64], horizontal: [33.5])
        // Claim ten guides while only two fit in the data that follows.
        resource.data.replaceSubrange(12..<16, with: [0, 0, 0, 10])
        let guides = PSDResources.parseGuides(resource.data)
        #expect(guides.count == 2)
        #expect(!PSDResources.guidesAreMalformed(resource.data))
    }

    @Test func anUnsupportedGuideVersionImportsNoGuidesWithANote() throws {
        var resource = PSDFixture.guidesResource(vertical: [64], horizontal: [])
        resource.data.replaceSubrange(0..<4, with: [0, 0, 0, 2])
        #expect(PSDResources.parseGuides(resource.data).isEmpty)
        #expect(PSDResources.guidesAreMalformed(resource.data))

        let document = try PSDReader.read(try file(resources: [resource]))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.guides.isEmpty)
        #expect(imported.conversions.contains { $0.message.contains("guides") })
    }

    @Test func aTruncatedGuideHeaderNeverFailsTheImport() throws {
        let resource = PSDImageResource(id: 1032, name: "", data: Data([0, 0, 0, 1]))
        #expect(PSDResources.parseGuides(resource.data).isEmpty)
        #expect(PSDResources.guidesAreMalformed(resource.data))
        let document = try PSDReader.read(try file(resources: [resource]))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.guides.isEmpty)
    }

    // MARK: Light, alpha names, ICC description

    @Test func globalLightAngleAndAltitudeDecode() throws {
        let resources = [PSDFixture.globalLightAngleResource(120), PSDFixture.globalLightAltitudeResource(30)]
        let document = try PSDReader.read(try file(resources: resources))
        #expect(document.extras?.globalLightAngle == 120)
        #expect(document.extras?.globalLightAltitude == 30)
    }

    @Test func unicodeAlphaNamesWinOverPascalNames() throws {
        let resources = [PSDFixture.alphaChannelNamesResource(["Mask"]),
                          PSDFixture.unicodeAlphaChannelNamesResource(["Alpha 1", "Alpha 2"])]
        let document = try PSDReader.read(try file(resources: resources))
        #expect(document.extras?.alphaChannelNames == ["Alpha 1", "Alpha 2"])
    }

    @Test func pascalAlphaNamesAreUsedWhenNoUnicodeNamesArePresent() throws {
        let document = try PSDReader.read(try file(resources: [PSDFixture.alphaChannelNamesResource(["Mask", "Fringe"])]))
        #expect(document.extras?.alphaChannelNames == ["Mask", "Fringe"])
    }

    @Test func iccProfileDescriptionDecodesTheDescTag() throws {
        let document = try PSDReader.read(try file(resources: [PSDFixture.iccProfileResource(description: "Test RGB")]))
        #expect(document.extras?.iccProfileDescription == "Test RGB")
    }

    @Test func iccDescriptionIsNilWhenAbsentOrTooShort() {
        #expect(PSDResources.iccDescription(Data()) == nil)
        #expect(PSDResources.iccDescription(Data(count: 100)) == nil)
    }

    // MARK: Resolution-mismatch note

    @Test func resolutionMismatchNoteOnlyFiresWhenPpiDiffers() {
        #expect(PSDDocumentBuilder.resolutionMismatchNote(fileName: "A.psd", importedResolution: 72, existingResolution: 72) == nil)
        let note = PSDDocumentBuilder.resolutionMismatchNote(fileName: "A.psd", importedResolution: 300, existingResolution: 72)
        #expect(note?.message == "Placed at pixel size; the file was 300 ppi.")
        #expect(note?.layerName == "A.psd")
    }
}
