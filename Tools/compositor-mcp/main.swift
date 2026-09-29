import Foundation

// compositor-mcp: the stdio MCP server that Claude Desktop (and any other client that
// only launches local commands) runs. It carries newline-delimited JSON-RPC between
// stdin/stdout and Compositor's local Streamable HTTP endpoint, one POST per line,
// finding the endpoint through the file the app publishes and launching Compositor
// with `--mcp` when nothing answers. Each POST carries Compositor's access token, from
// the token file the endpoint file names, so clients need no setup beyond the command.
//
// stdout carries JSON-RPC lines and nothing else; every diagnostic goes to stderr.
// Dependency-free by design (Foundation and AppKit only): it must not link the MCP
// SDK or any of the app's code.

/// Command-line options.
struct BridgeOptions: Sendable {
    var endpoint: URL?
    var endpointFile: URL?
    var tokenFile: URL?
    /// Where the diagnostic log goes (`BridgeLog`).
    var log = BridgeLog.Destination.standard
    var launches = true
    var launchTimeout: TimeInterval = 20
    var showsHelp = false
    var showsVersion = false

    struct UsageError: Error {
        let message: String
    }

    static let usage = """
        usage: compositor-mcp [--endpoint <url> | --endpoint-file <path>] [--token-file <path>] [--no-launch]
                              [--launch-timeout <seconds>] [--log-file <path> | --no-log]

        Bridges MCP over stdio to Compositor's local HTTP endpoint.
          --endpoint <url>            Use this endpoint instead of the published one.
          --endpoint-file <path>      Read the endpoint from this file
                                      (default: ~/Library/Application Support/Compositor/mcp/endpoint.json).
          --token-file <path>         Send the access token in this file (default: the file the endpoint
                                      file names, when the server requires one).
          --no-launch                 Never launch Compositor or ask it to start its server.
          --launch-timeout <seconds>  How long to wait for Compositor's server (default 20).
          --log-file <path>           Write the diagnostic log here (default:
                                      ~/Library/Logs/Compositor/bridge.jsonl, unless Compositor's
                                      Settings turned diagnostic logs off).
          --no-log                    Write no diagnostic log.
          --version, --help
        """

    static func parse(_ arguments: [String]) throws -> BridgeOptions {
        var options = BridgeOptions()
        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let value = remaining.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
            return value
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "--endpoint":
                let text = try value(for: argument)
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host != nil else {
                    throw UsageError(message: "--endpoint must be an http URL, got \(text)")
                }
                options.endpoint = url
            case "--endpoint-file":
                let path = (try value(for: argument) as NSString).expandingTildeInPath
                options.endpointFile = URL(fileURLWithPath: path)
            case "--token-file":
                let path = (try value(for: argument) as NSString).expandingTildeInPath
                options.tokenFile = URL(fileURLWithPath: path)
            case "--no-launch":
                options.launches = false
            case "--log-file":
                let path = (try value(for: argument) as NSString).expandingTildeInPath
                options.log = .file(URL(fileURLWithPath: path))
            case "--no-log":
                options.log = .off
            case "--launch-timeout":
                let text = try value(for: argument)
                guard let seconds = TimeInterval(text), seconds.isFinite, seconds > 0 else {
                    throw UsageError(message: "--launch-timeout must be a positive number of seconds, got \(text)")
                }
                options.launchTimeout = seconds
            case "--help", "-h":
                options.showsHelp = true
            case "--version":
                options.showsVersion = true
            default:
                throw UsageError(message: "unknown argument \(argument)")
            }
        }
        if options.endpoint != nil && options.endpointFile != nil {
            throw UsageError(message: "use either --endpoint or --endpoint-file, not both")
        }
        return options
    }
}

// A client that goes away closes our stdout; writing must fail with EPIPE, not kill us.
signal(SIGPIPE, SIG_IGN)

let options: BridgeOptions
do {
    options = try BridgeOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as BridgeOptions.UsageError {
    Log.write("compositor-mcp: \(error.message)\n\(BridgeOptions.usage)")
    exit(64) // EX_USAGE
}

if options.showsHelp {
    Log.write(BridgeOptions.usage)
    exit(0)
}
if options.showsVersion {
    Log.write("compositor-mcp \(Log.version)")
    exit(0)
}

BridgeLog.shared.start(options.log)
BridgeLog.shared.info("start", [
    "version": Log.version,
    "args": Array(CommandLine.arguments.dropFirst()),
    "endpoint_source": options.endpoint == nil ? "file" : "url",
    "endpoint": options.endpoint?.absoluteString ?? (options.endpointFile ?? EndpointDiscovery.defaultEndpointFile).path,
    "launches": options.launches,
    "launch_timeout": options.launchTimeout,
])

let discovery = EndpointDiscovery(
    source: options.endpoint.map(EndpointDiscovery.Source.url)
        ?? .file(options.endpointFile ?? EndpointDiscovery.defaultEndpointFile),
    tokenFile: options.tokenFile,
    http: HTTPPoster())
let launcher = options.launches ? AppLauncher(executableURL: Bundle.main.executableURL) : nil
let bridge = Bridge(resolver: EndpointResolver(discovery: discovery, launcher: launcher, timeout: options.launchTimeout),
                    writer: StdoutWriter(),
                    http: HTTPPoster())
await bridge.run(StdinLines())
BridgeLog.shared.info("exit", ["reason": "stdin_closed"])
exit(0)
