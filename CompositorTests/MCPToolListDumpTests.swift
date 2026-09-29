import Foundation
import MCP
import Testing
@testable import Compositor

/// Opt-in: writes the result the MCP server sends for `tools/list` (`ListTools.Result` over `MCPToolRegistry.tools`)
/// to a JSON file, so `skills/compositor/scripts/tool-atlas.py --from-json` can regenerate the agent skills' tool atlas
/// without launching Compositor. It runs only when `COMPOSITOR_TOOLLIST_OUT` names the file to write:
///
///     TEST_RUNNER_COMPOSITOR_TOOLLIST_OUT=<file.json> xcodebuild test … -only-testing:CompositorTests/MCPToolListDumpTests
///
/// (xcodebuild hands `TEST_RUNNER_`-prefixed variables to the tests without the prefix.) Otherwise it is skipped.
@MainActor
struct MCPToolListDumpTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_TOOLLIST_OUT"] != nil))
    func writesTheToolsListResult() throws {
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_TOOLLIST_OUT"])
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ListTools.Result(tools: MCPToolRegistry.tools))
        try data.write(to: url, options: .atomic)

        // What was written reads back as the same tools, in the registry's order. (Compared as JSON: a whole-number
        // double such as a default of 1.0 is written as 1 and reads back as an integer `Value`.)
        let written = try JSONDecoder().decode(ListTools.Result.self, from: Data(contentsOf: url))
        #expect(written.tools.map(\.name) == MCPToolRegistry.tools.map(\.name))
        #expect(try encoder.encode(written) == data)
    }
}
