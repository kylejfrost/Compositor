import Foundation
import Testing
@testable import Compositor

@MainActor
struct PreferencesMigrationTests {
    /// The app launched as a test host must not migrate: that would write the real
    /// `migration.*` markers into the user's defaults and move their real Agent folder.
    @Test func aTestHostLaunchSkipsTheMigrationMCPSetupAndUpdater() {
        #expect(CompositorApplicationDelegate.isHostingTests, "These tests run inside the app as test host")
        let hosted = CompositorApplicationDelegate.launchTasks(isHostingTests: true)
        #expect(!hosted.migratesPreferences && !hosted.managesMCP && !hosted.startsUpdater && !hosted.writesLogs)
        let normal = CompositorApplicationDelegate.launchTasks(isHostingTests: false)
        #expect(normal.migratesPreferences && normal.managesMCP && normal.startsUpdater && normal.writesLogs)
    }

    /// The carry-over runs before the workspace (and its first tab's session, which reads the tool settings it
    /// carries over) is made; a test host makes the workspace without it.
    @Test func theMigrationRunsBeforeTheWorkspaceIsMade() {
        var order: [String] = []
        let normal = CompositorApplicationDelegate.launchTasks(isHostingTests: false)
        let workspace = CompositorApplicationDelegate.makeWorkspace(launchTasks: normal, migrate: { order.append("migrate") },
                                                                    workspace: { order.append("workspace"); return ProjectWorkspace() })
        #expect(order == ["migrate", "workspace"])
        #expect(workspace.tabs.count == 1)
        order = []
        let hosted = CompositorApplicationDelegate.launchTasks(isHostingTests: true)
        _ = CompositorApplicationDelegate.makeWorkspace(launchTasks: hosted, migrate: { order.append("migrate") },
                                                        workspace: { order.append("workspace"); return ProjectWorkspace() })
        #expect(order == ["workspace"])
    }

    @Test func copiesOnlyMissingKeysOnceAndSetsMarker() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: plist) }
        try (["jpegExportQuality": 0.7, "tool.rulers": true, "NSWindow Frame editor": "0 66 2560 1344 0 0 2560 1410 "] as NSDictionary).write(to: plist)
        defaults.set(0.9, forKey: "jpegExportQuality")

        let copied = PreferencesMigration.migrate(from: plist, into: defaults)

        #expect(Set(copied) == ["tool.rulers", "NSWindow Frame editor"])
        #expect(defaults.double(forKey: "jpegExportQuality") == 0.9 && defaults.bool(forKey: "tool.rulers"))
        #expect(defaults.bool(forKey: PreferencesMigration.markerKey))
        #expect(PreferencesMigration.migrate(from: plist, into: defaults).isEmpty)
    }

    @Test func migrateSkipsAndRetriesOnAnUnparseablePlistWithoutMarkingDone() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: plist) }
        try "this is not a plist".write(to: plist, atomically: true, encoding: .utf8)

        let copied = PreferencesMigration.migrate(from: plist, into: defaults)

        #expect(copied.isEmpty)
        #expect(!defaults.bool(forKey: PreferencesMigration.markerKey))
    }

    @Test func migrateIfNeededMovesAbsentAgentFolderFromContainer() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let containerPlist = tmp.appendingPathComponent("container.plist")
        let sourceAgent = tmp.appendingPathComponent("ContainerAgent", isDirectory: true)
        let applicationSupport = tmp.appendingPathComponent("AppSupport", isDirectory: true)
        let destination = applicationSupport.appendingPathComponent("Compositor/Agent")
        try FileManager.default.createDirectory(at: sourceAgent, withIntermediateDirectories: true)
        let marker = sourceAgent.appendingPathComponent("dropped.txt")
        try "hello".write(to: marker, atomically: true, encoding: .utf8)
        try (["jpegExportQuality": 0.7] as NSDictionary).write(to: containerPlist)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(!FileManager.default.fileExists(atPath: destination.path))

        PreferencesMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: containerPlist,
            containerAgentFolderURL: sourceAgent,
            applicationSupportDirectory: applicationSupport
        )

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("dropped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: sourceAgent.path))
        #expect(defaults.double(forKey: "jpegExportQuality") == 0.7)
        #expect(defaults.bool(forKey: PreferencesMigration.markerKey))
        #expect(defaults.bool(forKey: PreferencesMigration.agentFolderMarkerKey))
    }

    @Test func migrateIfNeededLeavesExistingDestinationAgentFolderAlone() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let containerPlist = tmp.appendingPathComponent("container.plist")
        let sourceAgent = tmp.appendingPathComponent("ContainerAgent", isDirectory: true)
        let applicationSupport = tmp.appendingPathComponent("AppSupport", isDirectory: true)
        let destination = applicationSupport.appendingPathComponent("Compositor/Agent")
        try FileManager.default.createDirectory(at: sourceAgent, withIntermediateDirectories: true)
        try "old".write(to: sourceAgent.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "kept".write(to: destination.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try ([:] as NSDictionary).write(to: containerPlist)
        defer { try? FileManager.default.removeItem(at: tmp) }

        PreferencesMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: containerPlist,
            containerAgentFolderURL: sourceAgent,
            applicationSupportDirectory: applicationSupport
        )

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("kept.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))
        #expect(FileManager.default.fileExists(atPath: sourceAgent.appendingPathComponent("old.txt").path))
        #expect(defaults.bool(forKey: PreferencesMigration.agentFolderMarkerKey))
    }

    @Test func migrateIfNeededIsHarmlessWhenNothingToMigrate() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let containerPlist = tmp.appendingPathComponent("missing.plist")
        let sourceAgent = tmp.appendingPathComponent("MissingAgent", isDirectory: true)
        let applicationSupport = tmp.appendingPathComponent("AppSupport", isDirectory: true)
        let destination = applicationSupport.appendingPathComponent("Compositor/Agent")
        defer { try? FileManager.default.removeItem(at: tmp) }

        PreferencesMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: containerPlist,
            containerAgentFolderURL: sourceAgent,
            applicationSupportDirectory: applicationSupport
        )

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(defaults.bool(forKey: PreferencesMigration.markerKey))
        #expect(defaults.bool(forKey: PreferencesMigration.agentFolderMarkerKey))
    }

    /// Regression test for the destination being computed *inside* `migrateIfNeeded` from an
    /// injectable `applicationSupportDirectory` base, rather than accepting a pre-built
    /// destination URL. The production default (`MCPSettings.applicationSupportBaseURL`) is a
    /// pure computation with no side effects, so referencing it can never make the "does the
    /// destination already exist" check see a folder that was just created by evaluating the
    /// default itself. This test exercises exactly that computed-destination code path — the
    /// same one production hits when nothing is injected — using a temp base instead of the
    /// real Application Support folder.
    @Test func migrateIfNeededComputesTheDestinationFromTheApplicationSupportBaseRatherThanReceivingItPrebuilt() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A base folder that has never been touched: merely referencing it, or computing a
        // path under it, must not create anything.
        let applicationSupport = tmp.appendingPathComponent("NeverTouched", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: applicationSupport.path))
        let computedDestination = MCPSettings.agentRootURL(under: applicationSupport)
        #expect(!FileManager.default.fileExists(atPath: applicationSupport.path))
        #expect(!FileManager.default.fileExists(atPath: computedDestination.path))

        let containerPlist = tmp.appendingPathComponent("container.plist")
        try ([:] as NSDictionary).write(to: containerPlist)
        let sourceAgent = tmp.appendingPathComponent("ContainerAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAgent, withIntermediateDirectories: true)
        try "hello".write(to: sourceAgent.appendingPathComponent("dropped.txt"), atomically: true, encoding: .utf8)

        PreferencesMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: containerPlist,
            containerAgentFolderURL: sourceAgent,
            applicationSupportDirectory: applicationSupport
        )

        #expect(FileManager.default.fileExists(atPath: computedDestination.appendingPathComponent("dropped.txt").path))
    }

    @Test func migrateIfNeededLeavesTheAgentFolderMarkerUnsetAndTheSourceIntactWhenTheMoveFails() throws {
        let suite = "PreferencesMigrationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let containerPlist = tmp.appendingPathComponent("container.plist")
        try ([:] as NSDictionary).write(to: containerPlist)

        let sourceAgent = tmp.appendingPathComponent("ContainerAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAgent, withIntermediateDirectories: true)
        try "hello".write(to: sourceAgent.appendingPathComponent("dropped.txt"), atomically: true, encoding: .utf8)

        // The "Compositor" path component under this base is a plain file, so creating
        // "Compositor/Agent" underneath it — and therefore the move — fails.
        let applicationSupport = tmp.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try "not a folder".write(to: applicationSupport.appendingPathComponent("Compositor"), atomically: true, encoding: .utf8)

        PreferencesMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: containerPlist,
            containerAgentFolderURL: sourceAgent,
            applicationSupportDirectory: applicationSupport
        )

        #expect(!defaults.bool(forKey: PreferencesMigration.agentFolderMarkerKey))
        #expect(FileManager.default.fileExists(atPath: sourceAgent.appendingPathComponent("dropped.txt").path))
    }
}
