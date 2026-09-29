import Foundation
import MCP
@testable import Compositor

/// The tool reference docs/mcp.md carries between `begin` and `end`, generated from `MCPToolRegistry` so the page can't
/// drift from what `tools/list` says. `MCPToolDocsTests` checks it, and rewrites it when asked to.
@MainActor enum MCPToolDocs {
    static let begin = "<!-- tools:begin -->"
    static let end = "<!-- tools:end -->"

    /// docs/mcp.md in the source tree.
    static var pageURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/mcp.md")
    }

    /// A description's first sentence: up to the first full stop followed by a space (or the end), as every tool's
    /// description leads with one sentence saying what it does.
    static func summary(of description: String) -> String {
        var index = description.startIndex
        while let stop = description[index...].firstIndex(of: ".") {
            let next = description.index(after: stop)
            if next == description.endIndex || description[next] == " " { return String(description[...stop]) }
            index = next
        }
        return description
    }

    /// The generated reference: each domain's tools, one line each — name, summary sentence, then its arguments
    /// (required first, as the tool lists them, then optional ones alphabetically; `document` is left out, since every
    /// document tool takes it).
    static func reference() -> String {
        var lines = [
            "<!-- Generated from MCPToolRegistry by MCPToolDocsTests; don't edit by hand. To update, run:",
            "     TEST_RUNNER_COMPOSITOR_WRITE_DOCS=1 xcodebuild test … -only-testing:CompositorTests/MCPToolDocsTests -->",
        ]
        for domain in MCPToolRegistry.domains {
            lines += ["", "**\(domain.name)**", ""]
            lines += domain.entries.map { line(for: $0.tool) }
        }
        return lines.joined(separator: "\n")
    }

    static func line(for tool: Tool) -> String {
        let schema = tool.inputSchema.objectValue ?? [:]
        let properties = (schema["properties"]?.objectValue ?? [:]).keys.filter { $0 != "document" }
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let optional = properties.filter { !required.contains($0) }.sorted()
        var arguments: [String] = []
        if !required.isEmpty { arguments.append(required.map { "`\($0)`" }.joined(separator: ", ")) }
        if !optional.isEmpty { arguments.append("optional " + optional.map { "`\($0)`" }.joined(separator: ", ")) }
        let tail = arguments.isEmpty ? "" : " — " + arguments.joined(separator: "; ")
        return "- `\(tool.name)` — \(summary(of: tool.description ?? ""))\(tail)"
    }

    /// `page` with the text between the markers replaced by `section`; nil when the markers are missing.
    static func replacingReference(in page: String, with section: String) -> String? {
        guard let start = page.range(of: begin), let finish = page.range(of: end, range: start.upperBound..<page.endIndex) else {
            return nil
        }
        return page.replacingCharacters(in: start.upperBound..<finish.lowerBound, with: "\n" + section + "\n")
    }
}
