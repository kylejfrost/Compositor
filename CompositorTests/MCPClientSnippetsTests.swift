import Foundation
import Testing
@testable import Compositor

/// The ready-to-paste client setup lines shown in Compositor › Settings…, Connect a client. Settings shows
/// `<token>` where the access token goes; its Copy button puts the token itself on the clipboard.
struct MCPClientSnippetsTests {
    private let url = URL(string: "http://127.0.0.1:2667/mcp")!
    private let bridge = "/Applications/Compositor.app/Contents/MacOS/compositor-mcp"

    /// Claude Code's first setup is the bridge, like every client's: it sends the token only to the server the running
    /// Compositor published, where a client set up over HTTP sends it to whatever answers on its port.
    @Test func claudeCodeRunsTheBridgeWhichNeedsNoToken() {
        #expect(MCPClientSnippets.claudeCode(bridgePath: bridge)
                == "claude mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp")
    }

    @Test func claudeCodeOverHTTPSendsTheTokenAsAHeader() {
        #expect(MCPClientSnippets.claudeCodeHTTP(url: url, token: MCPClientSnippets.tokenPlaceholder)
                == #"claude mcp add --transport http compositor http://127.0.0.1:2667/mcp --header "Authorization: Bearer <token>""#)
    }

    @Test func claudeCodeOverHTTPWithoutTheTokenRequirementIsThePlainAddCommand() {
        #expect(MCPClientSnippets.claudeCodeHTTP(url: url, token: nil)
                == "claude mcp add --transport http compositor http://127.0.0.1:2667/mcp")
    }

    @Test func codexRunsTheBridgeWhichNeedsNoToken() {
        #expect(MCPClientSnippets.codex(bridgePath: bridge)
                == "codex mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp")
    }

    /// Codex over HTTP reads the token from an environment variable, set from the token file: the snippet itself
    /// never holds the token.
    @Test func codexOverHTTPReadsTheTokenFromTheEnvironment() {
        #expect(MCPClientSnippets.codexHTTP(url: url, tokenFilePath: "/Users/k/Library/Application Support/Compositor/mcp/token") == """
            export COMPOSITOR_MCP_TOKEN="$(cat '/Users/k/Library/Application Support/Compositor/mcp/token')"
            codex mcp add compositor --url http://127.0.0.1:2667/mcp --bearer-token-env-var COMPOSITOR_MCP_TOKEN
            """)
        #expect(MCPClientSnippets.codexHTTP(url: url, tokenFilePath: nil) == "codex mcp add compositor --url http://127.0.0.1:2667/mcp")
    }

    @Test func claudeDesktopRunsTheBridge() {
        #expect(MCPClientSnippets.claudeDesktop(bridgePath: "/Applications/Compositor.app/Contents/MacOS/compositor-mcp")
                == #"{ "mcpServers": { "compositor": { "command": "/Applications/Compositor.app/Contents/MacOS/compositor-mcp" } } }"#)
    }

    /// Hermes and any other client that launches a stdio server: the bridge's path is the whole command.
    @Test func anyStdioClientRunsTheBridge() {
        #expect(MCPClientSnippets.stdioCommand(bridgePath: bridge) == bridge)
    }

    @Test func snippetsUseTheActualPort() {
        let fallback = URL(string: "http://127.0.0.1:53117/mcp")!
        #expect(MCPClientSnippets.claudeCodeHTTP(url: fallback, token: nil).hasSuffix(" http://127.0.0.1:53117/mcp"))
        #expect(MCPClientSnippets.claudeCodeHTTP(url: fallback, token: "<token>").contains(" http://127.0.0.1:53117/mcp "))
        #expect(MCPClientSnippets.codexHTTP(url: fallback, tokenFilePath: "/t").contains("--url http://127.0.0.1:53117/mcp "))
    }

    @Test func anUnusualBridgePathStillMakesValidJSON() throws {
        let path = #"/Users/k/Apps "beta"\Compositor.app/Contents/MacOS/compositor-mcp"#
        let snippet = MCPClientSnippets.claudeDesktop(bridgePath: path)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: Any])
        let compositor = try #require(servers["compositor"] as? [String: Any])
        #expect(compositor["command"] as? String == path)
    }

    /// A path with spaces or quotes stays one shell word in the command-line snippets, as a real shell reads them.
    @Test func anUnusualPathStaysOneShellWord() throws {
        let path = #"/Users/k/My Apps/it's "beta"\$HOME/Compositor.app/Contents/MacOS/compositor-mcp"#
        for (snippet, prefix) in [(MCPClientSnippets.claudeCode(bridgePath: path), "claude mcp add compositor -- "),
                                  (MCPClientSnippets.codex(bridgePath: path), "codex mcp add compositor -- "),
                                  (MCPClientSnippets.stdioCommand(bridgePath: path), "")] {
            #expect(snippet.hasPrefix(prefix + "'"), "\(snippet)")
            #expect(try Self.shellWords(String(snippet.dropFirst(prefix.count))) == [path])
        }
        let tokenFile = "/Users/k/Library/Application Support/Compositor/mcp/token"
        let export = try #require(MCPClientSnippets.codexHTTP(url: url, tokenFilePath: tokenFile).split(separator: "\n").first)
        #expect(try Self.shellWords(String(export.dropFirst(#"export COMPOSITOR_MCP_TOKEN="$(cat "#.count).dropLast(2)))
                == [tokenFile])
    }

    @Test func theBridgeLivesInsideTheAppBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/Compositor.app", isDirectory: true)
        #expect(MCPClientSnippets.bridgeURL(inAppBundle: bundle).path
                == "/Applications/Compositor.app/Contents/MacOS/compositor-mcp")
        #expect(MCPClientSnippets.isInApplicationsFolder(bundle))
        #expect(!MCPClientSnippets.isInApplicationsFolder(
            URL(fileURLWithPath: "/Users/k/Library/Developer/Xcode/DerivedData/Build/Products/Debug/Compositor.app")))
        #expect(!MCPClientSnippets.isInApplicationsFolder(URL(fileURLWithPath: "/ApplicationsExtra/Compositor.app")))
    }

    /// The words /bin/sh makes of `text`, one per line (none of the words here hold a line break).
    private static func shellWords(_ text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\n' \(text)"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
