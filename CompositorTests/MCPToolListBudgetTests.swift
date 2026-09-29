import Foundation
import Testing
import MCP
@testable import Compositor

/// What every agent reads before its first call stays small and says what it must: the `initialize` instructions and
/// the `tools/list` result.
@MainActor struct MCPToolListBudgetTests {
    /// The most bytes `tools/list` may take, as the server encodes it. Clients put the whole list in the model's context.
    static let toolListBudget = 120_000
    /// The most bytes the instructions may take.
    static let instructionsBudget = 4096

    @Test func theToolListFitsItsBudget() throws {
        let bytes = try JSONEncoder().encode(ListTools.Result(tools: MCPToolRegistry.tools)).count
        #expect(bytes < Self.toolListBudget, "tools/list is \(bytes) bytes")
    }

    /// Each description leads with one sentence that says what the tool does, short enough to scan (and the line
    /// docs/mcp.md gives the tool); detail follows it.
    @Test func everyDescriptionLeadsWithOneShortSentence() {
        for tool in MCPToolRegistry.tools {
            let description = tool.description ?? ""
            let summary = MCPToolDocs.summary(of: description)
            #expect(!summary.isEmpty && summary.hasSuffix("."), "\(tool.name): \(description)")
            #expect(summary.count <= 200, "\(tool.name)'s first sentence is \(summary.count) characters: \(summary)")
        }
    }

    @Test func theInstructionsFitAndCoverEveryDomain() {
        let instructions = MCPToolRegistry.instructions
        #expect(instructions.utf8.count <= Self.instructionsBudget, "The instructions are \(instructions.utf8.count) bytes")
        // Each domain is named by at least one of its tools.
        for domain in MCPToolRegistry.domains {
            #expect(domain.entries.contains { instructions.contains($0.tool.name) }, "The instructions name no \(domain.name) tool")
        }
        // And what every agent needs before its first call.
        for topic in ["get_app_info", "list_documents", "@active", "Group/Child", "ambiguous", "document pixels", "y down",
                      "recorded", "run_batch", "settle_pending_edits", "render_document", "export_image", "overwrite: true",
                      "discard_changes: true", "folder_access_denied", "folder_access_pending", "effective_locks", "placeholder",
                      "check_fonts", ".psd", "allow_lossy", "template", "list_profiles", "IPv4"] {
            #expect(instructions.contains(topic), "The instructions don't mention \(topic)")
        }
    }
}
