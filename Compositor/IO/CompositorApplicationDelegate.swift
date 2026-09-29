import AppKit
import Sparkle

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Made first, as the delegate is created: see `makeWorkspace`.
    let workspace = makeWorkspace(launchTasks: launchTasks, migrate: { migration = PreferencesMigration.migrateIfNeeded() },
                                  workspace: { ProjectWorkspace() })
    /// What the preferences carry-over did at this launch, for the log's `launch` event.
    private static var migration: PreferencesMigration.Outcome?
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    /// Local MCP server for AI agents: started by the Settings switch (off by default),
    /// the `--mcp` launch argument, or the distributed start notification.
    let mcpServer = MCPServer()
    /// Checks the update feed and installs new versions (Sparkle). Started only after launch: its first-run prompt,
    /// shown during launch, kept the editor window from ever opening. Its checks are logged (`UpdateLog`).
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updateLog, userDriverDelegate: nil)
    /// Sparkle holds its delegate weakly.
    private static let updateLog = UpdateLog()

    /// The app is hosting unit tests (`xcodebuild test` launches it as the test host).
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Launch work that touches the user's real preferences, files or network.
    struct LaunchTasks: Equatable {
        /// The one-time sandbox carry-over (`PreferencesMigration`): writes real
        /// UserDefaults markers and moves the real Agent folder.
        var migratesPreferences: Bool
        /// Endpoint-file cleanup, auto-start of the MCP server, and the start
        /// notification observer: binds the real port and writes the real endpoint file.
        var managesMCP: Bool
        /// Sparkle's updater: reads and writes the real `SU*` preferences, fetches the
        /// update feed, and can show its permission or update window.
        var startsUpdater: Bool
        /// The diagnostic log in `~/Library/Logs/Compositor` (`CompositorLog.shared`).
        var writesLogs: Bool
    }

    /// None of it runs in a test host: tests use their own defaults suites, temporary
    /// folders and ephemeral ports, and must leave the user's real state untouched.
    nonisolated static func launchTasks(isHostingTests: Bool) -> LaunchTasks {
        LaunchTasks(migratesPreferences: !isHostingTests, managesMCP: !isHostingTests, startsUpdater: !isHostingTests,
                    writesLogs: !isHostingTests)
    }

    /// The workspace, made once the one-time preferences carry-over has run (when `launchTasks` allows it): the
    /// first tab's session reads its tool settings as it is made, so a migration run later (in
    /// `applicationWillFinishLaunching`) left the first launch after the update showing the default settings.
    static func makeWorkspace(launchTasks: LaunchTasks, migrate: () -> Void,
                              workspace: () -> ProjectWorkspace) -> ProjectWorkspace {
        if launchTasks.migratesPreferences { migrate() }
        return workspace()
    }

    private static var launchTasks: LaunchTasks { launchTasks(isHostingTests: isHostingTests) }

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            if let showEditor { showEditor() }
            // Launched to open a file, SwiftUI makes no window, and the editor that would set `showEditor` never
            // appears. A Dock click's reopen event makes the window, so the app sends itself one once launched.
            else { DispatchQueue.main.async { Self.reopen() } }
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }

    private static func reopen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always dark, alerts and open/save panels included, whatever the Mac is set to.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // The one-time carry-over of preferences and the Agent folder from the old sandbox container has run by now,
        // before the workspace was made (`makeWorkspace`).
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.launchTasks.writesLogs {
            CompositorLogSettings.startAppLog()
            AppLog.launched(arguments: CommandLine.arguments, migration: Self.migration)
        }
        if Self.launchTasks.startsUpdater {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [updater] in updater.startUpdater() }
        }
        mcpServer.workspace = workspace
        guard Self.launchTasks.managesMCP else { return }
        // A crash leaves the endpoint file behind; clear it before anything starts, so
        // the bridge never trusts a file naming a dead (or reused) pid.
        MCPEndpointFile.removeStale(at: MCPSettings.endpointFileURL, currentPID: getpid())
        // Starts only when the user turned the switch on, or asked for this session with `--mcp`.
        if let reason = MCPServer.launchStartReason(isEnabled: MCPSettings.isEnabled, arguments: CommandLine.arguments) {
            Task { try? await mcpServer.start(reason: reason) }
        }
        // `.deliverImmediately`: AppKit otherwise holds distributed notifications while the
        // app is in the background, which is exactly when an agent asks for the server.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(mcpStartRequested(_:)),
            name: MCPSettings.startNotification, object: nil, suspensionBehavior: .deliverImmediately)
    }

    /// Something on this Mac (typically the `compositor-mcp` bridge) asked for the MCP
    /// server: start it (for this session, unless the Settings switch is on), or, if it's
    /// already running, republish the endpoint file so the asker finds the live port and pid.
    @objc private func mcpStartRequested(_ notification: Notification) {
        if mcpServer.isRunning {
            mcpServer.refreshEndpointFile()
        } else {
            let reason = MCPServer.notificationStartReason(isEnabled: MCPSettings.isEnabled)
            Task { try? await mcpServer.start(reason: reason) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        // Also removes the endpoint file, so agents never find a dead endpoint.
        mcpServer.stop(reason: .appTerminating)
        AppLog.terminating()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let textEditing = workspace.quitOrder.contains { $0.session.textDraft != nil }
        guard workspace.canSwitch || textEditing else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.confirmQuit()) }
        return .terminateLater
    }
}
