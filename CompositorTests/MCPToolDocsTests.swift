import Foundation
import Testing
import MCP
@testable import Compositor

/// docs/mcp.md's tool reference is the one `MCPToolDocs.reference()` generates from the registry. With
/// `COMPOSITOR_WRITE_DOCS=1` (`TEST_RUNNER_COMPOSITOR_WRITE_DOCS=1` to xcodebuild, which passes `TEST_RUNNER_`-prefixed
/// variables on without the prefix) the test writes it there; otherwise it fails when the page and the registry differ.
@MainActor struct MCPToolDocsTests {
    @Test func theToolReferenceInTheDocsIsTheRegistrys() throws {
        let page = try String(contentsOf: MCPToolDocs.pageURL, encoding: .utf8)
        let generated = MCPToolDocs.reference()
        let updated = try #require(MCPToolDocs.replacingReference(in: page, with: generated),
                                   "docs/mcp.md needs the markers \(MCPToolDocs.begin) and \(MCPToolDocs.end)")
        if ProcessInfo.processInfo.environment["COMPOSITOR_WRITE_DOCS"] == "1" {
            if updated != page { try updated.write(to: MCPToolDocs.pageURL, atomically: true, encoding: .utf8) }
            return
        }
        #expect(updated == page,
                "docs/mcp.md's tool reference differs from the registry: run the suite with TEST_RUNNER_COMPOSITOR_WRITE_DOCS=1")
    }

    /// docs/mcp.md's table of error codes lists exactly the codes tools return (`MCPErrorCode`), so a code added or
    /// renamed in one place can't go missing from the other.
    @Test func theErrorCodeTableListsEveryCode() throws {
        let page = try String(contentsOf: MCPToolDocs.pageURL, encoding: .utf8)
        let section = try #require(page.components(separatedBy: "\n## Error codes\n").dropFirst().first?
            .components(separatedBy: "\n## ").first, "docs/mcp.md has no Error codes section")
        let table = try #require(section.components(separatedBy: "| `code` |").dropFirst().first?
            .components(separatedBy: "\n\n").first, "The Error codes section has no code table")
        let codes = table.split(separator: "\n").compactMap { row -> String? in
            guard row.hasPrefix("| `") else { return nil }
            return row.dropFirst(3).split(separator: "`").first.map(String.init)
        }
        #expect(codes.count == Set(codes).count, "\(codes)")
        #expect(Set(codes) == Set(MCPErrorCode.allCases.map(\.rawValue)), "\(codes)")
    }

    /// Every tool has its line, and each line names one tool.
    @Test func theReferenceListsEveryToolOnce() {
        let lines = MCPToolDocs.reference().split(separator: "\n").filter { $0.hasPrefix("- `") }
        let named = lines.compactMap { $0.dropFirst(3).split(separator: "`").first.map(String.init) }
        #expect(named == MCPToolRegistry.tools.map(\.name))
    }
}
