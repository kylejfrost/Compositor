import Foundation
import Testing
import MCP
@testable import Compositor

/// Shared scaffolding for MCP tool tests: a workspace with a document already open,
/// a helper that calls `MCPToolRegistry` and asserts the success/failure shape every
/// tool result follows, and a scratch file location for tools that read or write files.
@MainActor enum MCPTestSupport {
    /// Installs a throwaway temporary directory as `MCPSettings.agentRootOverride`, once per
    /// process, so no MCP test ever reads or writes the real `~/Library/Application
    /// Support/Compositor/Agent` folder. `workspace()` and `call()` both force this before
    /// doing anything else, so any test that goes through either one is covered; the `let`
    /// initializer runs at most once no matter how many times it's referenced. It also installs the temporary profile
    /// library (`ProfileTestSupport.locations`), so profile tools never read the real Adobe folders.
    private static let agentRootOverrideInstalled: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTestSupport-Agent-\(UUID().uuidString)", isDirectory: true)
        MCPSettings.agentRootOverride = directory
        _ = ProfileTestSupport.locations
        return directory
    }()

    /// Installs the folder-access checker every MCP test runs with, once per process, forced
    /// by `workspace()` and `call()`. It knows of no protected roots, so no tool call in a
    /// test ever lists the real Documents, Desktop, Downloads, iCloud Drive, cloud storage or
    /// /Volumes: from the test host that could wait on a consent prompt, and get_app_info
    /// probes every root not checked yet. Suites testing folder access run their calls with
    /// a checker of their own (`FolderAccess.taskChecker`).
    private static let folderAccessCheckerInstalled: FolderAccess.Checker = {
        let checker = FolderAccess.Checker(locations: [:], lister: { _ in [] }, linkReader: { _ in nil })
        FolderAccess.checker = checker
        return checker
    }()

    /// A workspace whose first tab already has an open document, ready for tool calls
    /// that require one (`get_document`, layer edits, etc).
    static func workspace(width: Int = 640, height: Int = 480) -> ProjectWorkspace {
        _ = agentRootOverrideInstalled
        _ = folderAccessCheckerInstalled
        let workspace = ProjectWorkspace()
        workspace.current.session.createNewProject(width: width, height: height)
        return workspace
    }

    /// Calls a tool through `MCPToolRegistry.call` and asserts the result's error shape,
    /// returning the decoded `structuredContent` object for the caller to inspect further.
    ///
    /// - `expectError == nil`: asserts `isError != true` (a successful call).
    /// - `expectError == "some_code"`: asserts `isError == true`, `ok == false`, and that
    ///   `error` is an object whose `code` is `"some_code"`.
    @discardableResult
    static func call(
        _ name: String,
        _ args: [String: Value] = [:],
        in workspace: ProjectWorkspace,
        expectError code: String? = nil
    ) async throws -> [String: Value] {
        _ = agentRootOverrideInstalled
        _ = folderAccessCheckerInstalled
        let result = await MCPToolRegistry.call(name, args, workspace: workspace)
        let object = result.structuredContent?.objectValue

        if let code {
            #expect(result.isError == true, "Expected '\(name)' to fail, got: \(String(describing: object))")
            #expect(object?["ok"] == .bool(false), "Expected '\(name)' to report ok: false, got: \(String(describing: object))")
            #expect(
                object?["error"]?.objectValue?["code"]?.stringValue == code,
                "Expected '\(name)' to fail with code '\(code)', got: \(String(describing: object))"
            )
        } else {
            #expect(result.isError != true, "Expected '\(name)' to succeed, got: \(String(describing: object))")
        }
        return object ?? [:]
    }

    /// The temporary directory installed as `MCPSettings.agentRootOverride`, for tests that
    /// need to assert about where the Agent folder tools actually wrote.
    static var agentRootOverride: URL { agentRootOverrideInstalled }

    /// A path inside a fresh scratch directory (removed at process exit along with the
    /// rest of `NSTemporaryDirectory()`), for tools that need a real file to read or write.
    static func tempFile(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTestSupport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
