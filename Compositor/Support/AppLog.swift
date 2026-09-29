import Foundation
import Sparkle

/// The app's own events in the diagnostic log (`CompositorLog`, `app` category): the launch, the quit, and errors
/// shown to the person using the app.
@MainActor
enum AppLog {
    /// When this process started, for the quit's uptime.
    private static let launchedAt = ContinuousClock.now

    /// Logs what is running and on what Mac: version and build, macOS, the machine model and memory, the size limits
    /// (one surface's side and pixels, and the document pixel budget, which scales with the memory), whether `--mcp` started the MCP server for this session, and what the one-time preferences carry-over
    /// did (nil when it didn't run).
    static func launched(arguments: [String], migration: PreferencesMigration.Outcome?, log: CompositorLog = .shared) {
        _ = launchedAt // Starts the uptime clock (a static is made when first read).
        let info = Bundle.main.infoDictionary ?? [:]
        var fields: [String: LogValue] = [
            "version": .string(info["CFBundleShortVersionString"] as? String ?? "?"),
            "build": .string(info["CFBundleVersion"] as? String ?? "?"),
            "macos": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "model": .string(machineModel),
            "memory_gb": .double((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10),
            "cpus": .int(ProcessInfo.processInfo.activeProcessorCount),
            "max_canvas_side": .int(DocumentLimits.maxSide),
            "max_pixels": .int(DocumentLimits.maxSurfacePixels),
            "document_pixel_budget": .int(DocumentLimits.documentPixelBudget),
            "launched_with_mcp": .bool(arguments.contains(MCPSettings.launchArgument)),
            "mcp_enabled": .bool(MCPSettings.isEnabled),
            "verbose": .bool(log.isVerbose),
            "pid": .int(Int(getpid())),
        ]
        if let migration {
            fields["migration"] = .object([
                "preferences_copied": migration.copiedPreferences.map { .int($0.count) } ?? .string("already_done"),
                "agent_folder": .string(migration.agentFolder.rawValue),
            ])
        }
        log.info(.app, "launch", fields)
    }

    /// Logs the quit and waits for the log to reach the disk.
    static func terminating(log: CompositorLog = .shared) {
        log.info(.app, "terminate", ["uptime_s": .double(((ContinuousClock.now - launchedAt) / .milliseconds(100)).rounded() / 10)])
        log.flush()
    }

    /// Logs an error the app shows (`what` names the alert: paint, import, crop), unless it arose inside an agent's
    /// tool call: that call's own event reports it. Nil (the alert dismissed) logs nothing.
    static func userError(_ what: String, _ message: String?) {
        guard let message, MCPCallLog.callID == nil else { return }
        CompositorLog.active.warning(.app, "user_error", ["what": .string(what), "message": .string(message)])
    }

    /// Logs an alert the app shows for a failed file operation (`ProjectController`).
    static func alert(_ title: String, error: any Error) {
        guard MCPCallLog.callID == nil else { return }
        CompositorLog.active.warning(.app, "user_error", ["what": "alert", "title": .string(title),
                                                          "message": .string(error.localizedDescription)])
    }

    /// `hw.model`, e.g. `Mac16,11`.
    static var machineModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}

/// Logs Sparkle's update checks (`update` category): when one starts, what it found, and why it ended. Nothing about
/// the person is logged; Sparkle's own requests carry no user data either.
nonisolated final class UpdateLog: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        CompositorLog.shared.info(.update, "check_started", ["kind": .string(Self.kind(updateCheck))])
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        CompositorLog.shared.info(.update, "update_found", ["version": .string(item.displayVersionString),
                                                            "build": .string(item.versionString)])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        CompositorLog.shared.info(.update, "no_update", ["reason": reason.map { .int($0.intValue) } ?? .null])
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        CompositorLog.shared.warning(.update, "check_failed", ["domain": .string(error.domain), "code": .int(error.code),
                                                               "message": .string(error.localizedDescription)])
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        var fields: [String: LogValue] = ["kind": .string(Self.kind(updateCheck))]
        if let error = error as NSError? { fields["error_code"] = .int(error.code) }
        CompositorLog.shared.info(.update, "check_finished", fields)
    }

    private static func kind(_ check: SPUUpdateCheck) -> String {
        switch check {
        case .updates: "user"
        case .updatesInBackground: "background"
        case .updateInformation: "information"
        @unknown default: "other"
        }
    }
}
