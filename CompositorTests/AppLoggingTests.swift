import Foundation
import Testing
@testable import Compositor

/// The app's own events in the diagnostic log: the launch (what's running, on what Mac, and what the one-time
/// preferences carry-over did), the quit, and errors shown to the person using the app. Events go to a log in a
/// temporary folder; nothing here touches the app's log or real preferences.
@MainActor struct AppLoggingTests {
    @Test func theLaunchEventDescribesTheAppTheMacAndTheMigration() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let migration = PreferencesMigration.Outcome(copiedPreferences: ["jpegExportQuality"], agentFolder: .moved)
        AppLog.launched(arguments: ["Compositor", "--mcp"], migration: migration, log: harness.log)
        AppLog.terminating(log: harness.log)

        let launch = try #require(try harness.events(named: "launch").first)
        #expect(launch["cat"] as? String == "app" && launch["level"] as? String == "info")
        #expect((launch["version"] as? String)?.isEmpty == false && launch["build"] is String, "\(launch)")
        #expect((launch["macos"] as? String)?.contains("Version") == true, "\(launch)")
        #expect((launch["model"] as? String)?.isEmpty == false, "\(launch)")
        #expect((launch["memory_gb"] as? Double).map { $0 > 0 } == true, "\(launch)")
        // The limits as get_app_info names them: one surface's side and pixels, and the budget that scales with memory.
        #expect(launch["max_canvas_side"] as? Int == DocumentLimits.maxSide && launch["max_pixels"] as? Int == 200_000_000,
                "\(launch)")
        #expect(launch["document_pixel_budget"] as? Int == DocumentLimits.documentPixelBudget && launch["pixel_budget"] == nil,
                "\(launch)")
        #expect(launch["launched_with_mcp"] as? Bool == true, "\(launch)")
        #expect(launch["mcp_enabled"] is Bool && launch["pid"] is Int, "\(launch)")
        let carried = try #require(launch["migration"] as? [String: Any], "\(launch)")
        #expect(carried["preferences_copied"] as? Int == 1 && carried["agent_folder"] as? String == "moved", "\(carried)")

        let quit = try #require(try harness.events(named: "terminate").first)
        #expect((quit["uptime_s"] as? Double).map { $0 >= 0 } == true, "\(quit)")
    }

    /// An error the app shows (the paint, import and crop alerts, a failed save or open) is a warning in the log.
    /// One raised inside an agent's tool call is that call's error, logged with the call, so it isn't repeated.
    @Test func errorsShownToThePersonAreWarningsButNotThoseAToolCallReports() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let session = MCPTestSupport.workspace().current.session
        CompositorLog.$taskLog.withValue(harness.log) {
            session.brushError = "“Headline” is locked."
            session.brushError = nil
            session.importError = "Poster.psd: The file couldn’t be read."
            session.cropError = "The crop is empty."
            AppLog.alert("Couldn’t save the project", error: CocoaError(.fileWriteNoPermission))
            MCPCallLog.$callID.withValue("0badcafe") {
                session.brushError = "Reported by the tool call instead."
            }
        }
        let errors = try harness.events(named: "user_error")
        #expect(errors.map { $0["what"] as? String } == ["paint", "import", "crop", "alert"], "\(errors)")
        #expect(errors.allSatisfy { $0["level"] as? String == "warning" && $0["cat"] as? String == "app" })
        #expect(errors.first?["message"] as? String == "“Headline” is locked.")
        #expect(errors.last?["title"] as? String == "Couldn’t save the project", "\(errors)")
        #expect((errors.last?["message"] as? String)?.isEmpty == false, "\(errors)")
    }

    @Test func theMigrationSaysWhatItDid() throws {
        let suite = "AppLoggingTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist = folder.appendingPathComponent("container.plist")
        let agent = folder.appendingPathComponent("ContainerAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try (["jpegExportQuality": 0.7] as NSDictionary).write(to: plist)
        let support = folder.appendingPathComponent("AppSupport", isDirectory: true)

        let first = PreferencesMigration.migrateIfNeeded(defaults: defaults, containerPlistURL: plist,
                                                         containerAgentFolderURL: agent, applicationSupportDirectory: support)
        #expect(first == PreferencesMigration.Outcome(copiedPreferences: ["jpegExportQuality"], agentFolder: .moved))
        let again = PreferencesMigration.migrateIfNeeded(defaults: defaults, containerPlistURL: plist,
                                                         containerAgentFolderURL: agent, applicationSupportDirectory: support)
        #expect(again == PreferencesMigration.Outcome(copiedPreferences: nil, agentFolder: .alreadyDone))
    }
}
