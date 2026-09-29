import Foundation

/// Ready-to-paste setup for the MCP clients Settings (Compositor › Settings…, Connect a client) offers to copy.
///
/// The `compositor-mcp` bridge embedded in the app is the setup that needs nothing else, and every client's first
/// setup: it finds the running server and its access token through the endpoint file, so a client that launches it
/// (Claude Code, Codex, Claude Desktop, Hermes, any stdio client) is never told the token, and the token goes only to
/// the server the running Compositor published. The alternative for Claude Code and Codex connects to the HTTP
/// endpoint directly and sends the token itself, to whatever answers on that port: Claude Code as a header given when
/// it is added (Settings shows `<token>` and copies the token itself), Codex from an environment variable set from
/// the token file.
nonisolated enum MCPClientSnippets {
    static let serverName = "compositor"
    static let bridgeExecutableName = "compositor-mcp"
    /// Where the access token goes in the setup Settings shows; the copied setup has the token itself.
    static let tokenPlaceholder = "<token>"
    /// The environment variable Codex reads the token from (`--bearer-token-env-var`).
    static let tokenEnvironmentVariable = "COMPOSITOR_MCP_TOKEN"

    /// Claude Code through the bridge, which needs no URL and no token.
    static func claudeCode(bridgePath: String) -> String {
        "claude mcp add \(serverName) -- \(shellWord(bridgePath))"
    }

    /// Claude Code straight to the endpoint. With a `token` (nil when the server requires none), Claude Code stores it
    /// and sends it with every request to `url`.
    static func claudeCodeHTTP(url: URL, token: String?) -> String {
        let add = "claude mcp add --transport http \(serverName) \(url.absoluteString)"
        guard let token else { return add }
        return add + " --header \"Authorization: Bearer \(token)\""
    }

    /// Codex through the bridge, which needs no URL and no token.
    static func codex(bridgePath: String) -> String {
        "codex mcp add \(serverName) -- \(shellWord(bridgePath))"
    }

    /// Codex straight to the endpoint. With a token file (the server requires the token), Codex reads the token from
    /// `COMPOSITOR_MCP_TOKEN`, which the first line sets from that file; it must be set wherever Codex runs.
    static func codexHTTP(url: URL, tokenFilePath: String?) -> String {
        let add = "codex mcp add \(serverName) --url \(url.absoluteString)"
        guard let tokenFilePath else { return add }
        return """
            export \(tokenEnvironmentVariable)="$(cat \(shellWord(tokenFilePath)))"
            \(add) --bearer-token-env-var \(tokenEnvironmentVariable)
            """
    }

    /// The `mcpServers` entry for `claude_desktop_config.json`.
    static func claudeDesktop(bridgePath: String) -> String {
        #"{ "mcpServers": { "\#(serverName)": { "command": \#(jsonString(bridgePath)) } } }"#
    }

    /// The command for any other client that launches a stdio server (Hermes, …): the bridge, as one shell word.
    static func stdioCommand(bridgePath: String) -> String {
        shellWord(bridgePath)
    }

    /// Where the bridge lives inside an app bundle.
    static func bridgeURL(inAppBundle bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/MacOS/\(bridgeExecutableName)")
    }

    /// Whether the app runs from `/Applications`, the one place whose path a client
    /// config can rely on staying put.
    static func isInApplicationsFolder(_ bundleURL: URL) -> Bool {
        bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    /// A JSON string literal, quotes and backslashes escaped; slashes left readable.
    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    /// `value` as one shell word: as it is when no shell treats any of its characters specially (the usual
    /// `/Applications/…` path), else in single quotes.
    private static func shellWord(_ value: String) -> String {
        let plain = !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "/._-+:@%,=".unicodeScalars.contains(scalar))
        }
        return plain ? value : "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
