import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// Document (tab) and layer selectors: how every MCP tool addresses its target.
@MainActor struct MCPSelectorTests {
    /// Root: "Logo", folder "Footer" containing "Logo" and "A/B" (a name with a slash).
    struct Fixture {
        let document: CanvasDocument
        let rootLogo: UUID
        let footer: UUID
        let nestedLogo: UUID
        let slashed: UUID
    }

    static func fixture() -> Fixture {
        let rootLogo = UUID(), footer = UUID(), nestedLogo = UUID(), slashed = UUID()
        let box = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let layers = [
            ImageLayer(id: rootLogo, asset: nil, name: "Logo", isVisible: true, transform: box),
            ImageLayer(id: nestedLogo, asset: nil, name: "Logo", isVisible: true, transform: box, parentID: footer),
            ImageLayer(id: slashed, asset: nil, name: "A/B", isVisible: true, transform: box, parentID: footer),
            ImageLayer(id: footer, asset: nil, name: "Footer", isVisible: true, transform: box, isGroup: true),
        ]
        return Fixture(document: CanvasDocument(width: 64, height: 64, layers: layers),
                       rootLogo: rootLogo, footer: footer, nestedLogo: nestedLogo, slashed: slashed)
    }

    // MARK: Layer selectors

    @Test func folderPathResolvesToTheNestedLayer() throws {
        let f = Self.fixture()
        let layer = try MCPSelectors.layer(.string("Footer/Logo"), in: f.document)
        #expect(layer.id == f.nestedLogo)
    }

    @Test func bareNameWithTwoMatchesIsAmbiguousWithCandidates() throws {
        let f = Self.fixture()
        do {
            _ = try MCPSelectors.layer(.string("Logo"), in: f.document)
            Issue.record("Expected an ambiguous error")
        } catch let error as MCPToolError {
            #expect(error.code == .ambiguous)
            let candidates = error.details["candidates"]?.arrayValue ?? []
            #expect(candidates.count == 2)
            let ids = Set(candidates.compactMap { $0.objectValue?["id"]?.stringValue })
            #expect(ids == [f.rootLogo.uuidString, f.nestedLogo.uuidString])
            let paths = Set(candidates.compactMap { $0.objectValue?["path"]?.stringValue })
            #expect(paths == ["Logo", "Footer/Logo"])
            #expect(candidates.allSatisfy { $0.objectValue?["kind"]?.stringValue == "raster" })
        }
    }

    @Test func uuidResolves() throws {
        let f = Self.fixture()
        #expect(try MCPSelectors.layer(.string(f.rootLogo.uuidString), in: f.document).id == f.rootLogo)
        #expect(try MCPSelectors.layer(.string(f.footer.uuidString.lowercased()), in: f.document).id == f.footer)
    }

    @Test func activeSelectorUsesTheActiveLayer() throws {
        let f = Self.fixture()
        #expect(try MCPSelectors.layer(.string("@active"), in: f.document, active: f.slashed).id == f.slashed)
        #expect(throws: MCPToolError.self) { try MCPSelectors.layer(.string("@active"), in: f.document, active: nil) }
    }

    @Test func escapedSlashMatchesANameContainingASlash() throws {
        let f = Self.fixture()
        let slashed = try #require(f.document.layers.first { $0.id == f.slashed })
        let path = MCPSelectors.path(of: slashed, in: f.document)
        #expect(path == #"Footer/A\/B"#)
        #expect(try MCPSelectors.layer(.string(path), in: f.document).id == f.slashed)
        #expect(try MCPSelectors.layer(.string(#"A\/B"#), in: f.document).id == f.slashed)
    }

    @Test func literalNameWithABackslashResolves() throws {
        let id = UUID()
        let box = LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4))
        let document = CanvasDocument(width: 8, height: 8, layers: [
            ImageLayer(id: id, asset: nil, name: #"a\b"#, isVisible: true, transform: box),
        ])
        #expect(try MCPSelectors.layer(.string(#"a\b"#), in: document).id == id)
    }

    @Test func pathAndLiteralNameMatchingDifferentLayersIsAmbiguous() throws {
        let folder = UUID(), child = UUID(), literal = UUID()
        let box = LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4))
        let document = CanvasDocument(width: 8, height: 8, layers: [
            ImageLayer(id: child, asset: nil, name: "Y", isVisible: true, transform: box, parentID: folder),
            ImageLayer(id: folder, asset: nil, name: "X", isVisible: true, transform: box, isGroup: true),
            ImageLayer(id: literal, asset: nil, name: "X/Y", isVisible: true, transform: box),
        ])
        do {
            _ = try MCPSelectors.layer(.string("X/Y"), in: document)
            Issue.record("Expected ambiguous")
        } catch let error as MCPToolError {
            #expect(error.code == .ambiguous)
            let ids = Set((error.details["candidates"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue })
            #expect(ids == [child.uuidString, literal.uuidString])
        }
        // Escaping picks the literal name; the folder path alone picks the child.
        #expect(try MCPSelectors.layer(.string(#"X\/Y"#), in: document).id == literal)
    }

    @Test func duplicateTabTitlesAreAmbiguous() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        let base = FileManager.default.temporaryDirectory
        workspace.tabs[0].session.projectURL = base.appendingPathComponent("one/Same.comp")
        workspace.tabs[1].session.projectURL = base.appendingPathComponent("two/Same.comp")
        do {
            _ = try MCPSelectors.tab(.string("Same"), in: workspace)
            Issue.record("Expected ambiguous")
        } catch let error as MCPToolError {
            #expect(error.code == .ambiguous)
            #expect(error.details["candidates"]?.arrayValue?.count == 2)
        }
        try await MCPTestSupport.call("get_document", ["document": "Same"], in: workspace, expectError: "ambiguous")
    }

    /// Two tabs can hold the same document id (a .comp opened again after its tab was saved elsewhere, or a Finder
    /// copy): that id is ambiguous, listing both, rather than silently the first tab. A tab id stays exact.
    @Test func aDocumentIDTwoTabsShareIsAmbiguous() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        let first = workspace.tabs[0], second = workspace.tabs[1]
        second.session.document = first.session.document
        let shared = try #require(first.session.document?.id)
        do {
            _ = try MCPSelectors.tab(.string(shared.uuidString), in: workspace)
            Issue.record("Expected ambiguous")
        } catch let error as MCPToolError {
            #expect(error.code == .ambiguous)
            let candidates = error.details["candidates"]?.arrayValue?.compactMap { $0.objectValue?["tab_id"]?.stringValue }
            #expect(candidates == [first.id.uuidString, second.id.uuidString])
        }
        try await MCPTestSupport.call("close_document", ["document": .string(shared.uuidString), "discard_changes": true],
                                      in: workspace, expectError: "ambiguous")
        #expect(workspace.tabs.count == 2)
        #expect(try MCPSelectors.tab(.string(second.id.uuidString), in: workspace) === second)
    }

    @Test func unknownLayerIsNotFound() {
        let f = Self.fixture()
        do {
            _ = try MCPSelectors.layer(.string("Nope"), in: f.document)
            Issue.record("Expected not_found")
        } catch let error as MCPToolError {
            #expect(error.code == .notFound)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func layersAcceptsAnArrayOrASingleSelector() throws {
        let f = Self.fixture()
        let many = try MCPSelectors.layers(.array([.string("Footer/Logo"), .string(f.rootLogo.uuidString), .string("Footer/Logo")]), in: f.document)
        #expect(many.map(\.id) == [f.nestedLogo, f.rootLogo])
        let one = try MCPSelectors.layers(.string("Footer"), in: f.document)
        #expect(one.map(\.id) == [f.footer])
    }

    @Test func ambiguousLayerThroughAToolReturnsCandidates() async throws {
        let workspace = MCPTestSupport.workspace()
        workspace.current.session.document?.layers = Self.fixture().document.layers
        let result = try await MCPTestSupport.call("rename_layer", ["layer": "Logo", "name": "X"], in: workspace, expectError: "ambiguous")
        let candidates = result["error"]?.objectValue?["details"]?.objectValue?["candidates"]?.arrayValue
        #expect(candidates?.count == 2)
    }

    // MARK: Document selectors

    @Test func tabSelectorAcceptsIndexCurrentTitleAndIDs() async throws {
        let workspace = MCPTestSupport.workspace()
        let first = workspace.current
        try await MCPTestSupport.call("new_document", ["width": 32, "height": 32], in: workspace)
        let second = workspace.current
        #expect(first !== second)
        #expect(try MCPSelectors.tab(nil, in: workspace) === second)
        #expect(try MCPSelectors.tab(.string("@current"), in: workspace) === second)
        #expect(try MCPSelectors.tab(.int(0), in: workspace) === first)
        #expect(try MCPSelectors.tab(.string(first.id.uuidString), in: workspace) === first)
        let documentID = try #require(first.session.document?.id)
        #expect(try MCPSelectors.tab(.string(documentID.uuidString), in: workspace) === first)
        #expect(try MCPSelectors.tab(.string(second.title), in: workspace) === second)
        #expect(throws: MCPToolError.self) { try MCPSelectors.tab(.int(7), in: workspace) }
    }

    @Test func mutatingToolTargetsTheSelectedDocumentOnly() async throws {
        let workspace = MCPTestSupport.workspace()
        let first = workspace.current
        let firstDocument = try #require(first.session.document?.id)
        try await MCPTestSupport.call("new_document", ["width": 32, "height": 32], in: workspace)
        let second = workspace.current
        let firstCount = first.session.document?.layers.count ?? 0
        let secondCount = second.session.document?.layers.count ?? 0

        let result = try await MCPTestSupport.call("add_blank_layer", ["document": .string(firstDocument.uuidString), "name": "Only here"], in: workspace)

        #expect(first.session.document?.layers.count == firstCount + 1)
        #expect(first.session.document?.layers.contains { $0.name == "Only here" } == true)
        #expect(second.session.document?.layers.count == secondCount)
        #expect(workspace.current === second, "Targeting another document must not switch tabs")
        #expect(result["undo"]?.objectValue?["count"]?.intValue == first.session.history.undoCount)
    }
}
