import Foundation
import os

/// One-time carry-over of preferences (and the Agent folder) written while the app was
/// sandboxed, now that the sandbox is gone and `UserDefaults.standard` / `FileManager`'s
/// `applicationSupportDirectory` resolve to the unsandboxed locations instead of the old
/// container.
enum PreferencesMigration {
    private static let log = Logger(subsystem: "com.wonderassembly.compositor", category: "preferences-migration")

    /// Set once the preferences plist step is resolved: the plist was read (and any missing
    /// keys copied), or it was confirmed absent. Left unset if the plist exists but can't be
    /// parsed, so the next launch retries instead of silently giving up on real data.
    static let markerKey = "migration.sandboxPreferences.v1"
    /// Set once the Agent folder step is resolved: the folder was moved, a destination was
    /// already there, or there was never a folder to move. Left unset if a move is attempted
    /// and fails, so the next launch retries rather than stranding the folder.
    static let agentFolderMarkerKey = "migration.sandboxAgentFolder.v1"

    /// What one launch's `migrateIfNeeded` did, for the diagnostic log's `launch` event.
    struct Outcome: Equatable, Sendable {
        enum AgentFolder: String, Sendable {
            case alreadyDone = "already_done"
            case nothingToMove = "nothing_to_move"
            case destinationExists = "destination_exists"
            case moved
            /// Left in place, to be tried again next launch.
            case failed
        }
        /// The preference keys copied from the old container; nil when that step had run before.
        var copiedPreferences: [String]?
        var agentFolder: AgentFolder
    }

    /// Where the sandboxed app's `UserDefaults.standard` was actually stored on disk.
    static var containerPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.wonderassembly.compositor/Data/Library/Preferences/com.wonderassembly.compositor.plist")
    }

    /// Where the MCP Agent folder lived inside the sandbox container.
    static var containerAgentFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.wonderassembly.compositor/Data/Library/Application Support/Compositor/\(MCPSettings.agentFolderName)")
    }

    /// Copies every key present in `plist` but missing from `defaults`, then marks the
    /// preferences step done. Safe to call repeatedly: already-copied keys are never
    /// overwritten.
    ///
    /// A missing plist means there was never a sandboxed install to migrate from, so it's
    /// treated as done. A plist that exists but can't be parsed is logged and left alone —
    /// not marked done — so a later launch retries instead of permanently skipping real data.
    @discardableResult
    static func migrate(from plist: URL, into defaults: UserDefaults) -> [String] {
        guard FileManager.default.fileExists(atPath: plist.path) else {
            defaults.set(true, forKey: markerKey)
            return []
        }
        guard let dictionary = NSDictionary(contentsOf: plist) as? [String: Any] else {
            log.error("Could not parse the sandboxed preferences plist at \(plist.path, privacy: .public); will retry on next launch.")
            return []
        }
        var copied: [String] = []
        for (key, value) in dictionary {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        defaults.set(true, forKey: markerKey)
        return copied
    }

    /// Runs the one-time migration if it hasn't run yet: copies missing preference keys from
    /// the old sandbox container plist, and moves the old Agent folder into the new
    /// unsandboxed location if nothing is there yet. The two steps are tracked and retried
    /// independently, so a failure in one doesn't strand the other.
    ///
    /// `applicationSupportDirectory` is the base `Application Support` folder the Agent
    /// folder's destination is computed under (matching `MCPSettings.agentRootURL`); it
    /// defaults to the real location via `MCPSettings.applicationSupportBaseURL`, which has no
    /// side effects, so a launch with nothing to migrate never creates the destination as a
    /// side effect of merely checking it.
    @discardableResult
    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        containerPlistURL: URL = PreferencesMigration.containerPlistURL,
        containerAgentFolderURL: URL = PreferencesMigration.containerAgentFolderURL,
        applicationSupportDirectory: URL = MCPSettings.applicationSupportBaseURL
    ) -> Outcome {
        var outcome = Outcome(copiedPreferences: nil, agentFolder: .alreadyDone)
        if !defaults.bool(forKey: markerKey) {
            outcome.copiedPreferences = migrate(from: containerPlistURL, into: defaults)
        }

        guard !defaults.bool(forKey: agentFolderMarkerKey) else { return outcome }
        let fileManager = FileManager.default
        let destination = MCPSettings.agentRootURL(under: applicationSupportDirectory)

        guard fileManager.fileExists(atPath: containerAgentFolderURL.path) else {
            // Never sandboxed, or already migrated by hand: nothing to move.
            defaults.set(true, forKey: agentFolderMarkerKey)
            outcome.agentFolder = .nothingToMove
            return outcome
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            // Something is already there; leave it alone but stop checking every launch.
            defaults.set(true, forKey: agentFolderMarkerKey)
            outcome.agentFolder = .destinationExists
            return outcome
        }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: containerAgentFolderURL, to: destination)
            defaults.set(true, forKey: agentFolderMarkerKey)
            outcome.agentFolder = .moved
        } catch {
            // Leave the marker unset so the next launch retries. moveItem either fully
            // succeeds or leaves the source untouched, so nothing is lost here.
            log.error("Could not move the Agent folder from \(containerAgentFolderURL.path, privacy: .public) to \(destination.path, privacy: .public): \(String(describing: error), privacy: .public); will retry on next launch.")
            outcome.agentFolder = .failed
        }
        return outcome
    }
}
