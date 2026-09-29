import AppKit

/// Gets Compositor's MCP server running: launches the app with `--mcp` (the server
/// then runs for that session only, without turning the Settings switch on), or, when
/// it's already running, asks it to start the server with a distributed notification.
struct AppLauncher: Sendable {
    /// The values the app defines in `MCPSettings`; this tool shares no code with it.
    static let appBundleIdentifier = "com.wonderassembly.compositor"
    static let launchArgument = "--mcp"
    static let startNotification = Notification.Name("com.wonderassembly.compositor.mcp.start")

    /// The bridge's own executable, used to find the app bundle it's embedded in.
    let executableURL: URL?

    /// The app to launch: the one this executable lives in
    /// (`Compositor.app/Contents/MacOS/compositor-mcp`), else whichever copy
    /// LaunchServices knows by bundle identifier.
    static func appBundleURL(executableURL: URL?) -> URL? {
        if let executableURL {
            let candidate = executableURL.resolvingSymlinksInPath()
                .deletingLastPathComponent() // MacOS
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // Compositor.app
            if candidate.pathExtension == "app" { return candidate }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
    }

    var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleIdentifier).isEmpty
    }

    /// Launches Compositor in the background, or signals the running one.
    func requestServer() async throws {
        if isAppRunning {
            Log.info("Compositor is running; asking it to start its MCP server")
            BridgeLog.shared.info("launch", ["action": "notify_running_app"])
            postStartNotification()
            return
        }
        guard let appURL = Self.appBundleURL(executableURL: executableURL) else {
            BridgeLog.shared.warning("launch", ["action": "open_app", "error": "Compositor.app could not be found"])
            throw UnreachableError(reason: "Compositor.app could not be found")
        }
        Log.info("launching \(appURL.path) \(Self.launchArgument)")
        BridgeLog.shared.info("launch", ["action": "open_app", "app": appURL.path])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [Self.launchArgument]
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            BridgeLog.shared.warning("launch", ["action": "open_app", "app": appURL.path, "error": error.localizedDescription])
            throw UnreachableError(reason: "Compositor could not be launched: \(error.localizedDescription)")
        }
    }

    /// Repeats the start request while waiting: a Compositor that was still launching
    /// when the first one was posted had not begun listening for it yet.
    func renotifyIfRunning() {
        if isAppRunning { postStartNotification() }
    }

    private func postStartNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.startNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
