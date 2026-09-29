import AppKit
import SwiftUI

/// The Settings window (Compositor › Settings…): the switch that turns the local MCP server on or
/// off (off by default), its status and port, the access token (required by default), ready-to-paste
/// setup for each client, a shortcut to the Agent folder, and macOS folder access.
///
/// A port change applies immediately: a running server restarts on the new port (for
/// the same reason it was running), and a stopped one uses it on its next start. So does
/// the token switch, and a regenerated token: the next request needs the new one.
struct MCPSettingsView: View {
    let server: MCPServer
    @State private var isEnabled = MCPSettings.isEnabled
    @State private var requiresToken = MCPSettings.requiresToken
    @State private var portText = String(MCPSettings.port)
    /// The label of the most recently copied item, shown as "Copied ✓".
    @State private var copied: String?
    @State private var confirmingRegenerate = false
    /// Why the token couldn't be read, made or replaced.
    @State private var tokenError: String?

    private var bundleURL: URL { Bundle.main.bundleURL }

    /// The running endpoint, or the one the configured port would give.
    private var clientURL: URL {
        server.endpointURL ?? URL(string: "http://127.0.0.1:\(MCPSettings.port)/mcp")!
    }

    private var bridgePath: String { MCPClientSnippets.bridgeURL(inAppBundle: bundleURL).path }

    private var enteredPort: Int? {
        Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { MCPSettings.isValidPort($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Allow AI agents to control this document", isOn: $isEnabled)
                .toggleStyle(.switch)
                .font(.headline)
                .onChange(of: isEnabled) { _, enabled in
                    MCPSettings.isEnabled = enabled
                    if enabled {
                        Task { try? await server.start(reason: .settings) }
                    } else {
                        // Stops it even when it was started for this session.
                        server.stop(reason: .settingsSwitch)
                    }
                }

            if server.isRunning, server.startReason == .session {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Running for this session only — started with --mcp or at an agent's request. It won't start again on the next launch.",
                          systemImage: "clock")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Stop for this session") { server.stop(reason: .stoppedForSession) }
                        .controlSize(.small)
                }
            }

            if let error = server.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow("Status", value: server.isRunning ? "Running" : "Stopped")
                    if let endpoint = server.endpointURL {
                        HStack(spacing: 8) {
                            statusRow("Endpoint", value: endpoint.absoluteString)
                            copyButton("Endpoint", text: endpoint.absoluteString)
                        }
                    }
                    portRow
                    if server.portFellBack {
                        Label("Port \(String(server.options.preferredPort)) is in use by another app, so Compositor is listening on \(String(server.port)) for now. The setup below uses \(String(server.port)), which changes on the next start: free port \(String(server.options.preferredPort)) or choose another.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Text("Agent folder")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Reveal in Finder") {
                            _ = try? MCPPaths.reveal()
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            accessTokenGroup

            GroupBox("Connect a client") {
                VStack(alignment: .leading, spacing: 12) {
                    snippet("Claude Code", note: "Run in Terminal (uses the bridge):",
                            text: MCPClientSnippets.claudeCode(bridgePath: bridgePath))
                    snippet("Codex", note: "Run in Terminal (uses the bridge):", text: MCPClientSnippets.codex(bridgePath: bridgePath))
                    snippet("Claude Desktop", note: "Add to claude_desktop_config.json:",
                            text: MCPClientSnippets.claudeDesktop(bridgePath: bridgePath))
                    snippet("Other clients", note: "The command for any stdio client (Hermes…):",
                            text: MCPClientSnippets.stdioCommand(bridgePath: bridgePath))
                    snippet("Claude Code over HTTP", note: "Or connect directly:",
                            text: MCPClientSnippets.claudeCodeHTTP(url: clientURL, token: requiresToken ? MCPClientSnippets.tokenPlaceholder : nil),
                            copy: { MCPClientSnippets.claudeCodeHTTP(url: clientURL, token: requiresToken ? try server.currentToken() : nil) })
                    snippet("Codex over HTTP",
                            note: requiresToken ? "Or connect directly; keep the export line in ~/.zshrc:" : "Or connect directly:",
                            text: MCPClientSnippets.codexHTTP(url: clientURL,
                                                              tokenFilePath: requiresToken ? server.options.tokenFileURL?.path : nil))
                    if !MCPClientSnippets.isInApplicationsFolder(bundleURL) {
                        Label("Compositor is running from \(bundleURL.deletingLastPathComponent().path). Move it to the Applications folder so the setups that run compositor-mcp keep pointing at it.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            FolderAccessGroup()

            DiagnosticLogsGroup()

            Text("This starts a local server on 127.0.0.1 that only this Mac can reach, and by default only with the access token. Agents can open and edit documents and read and write image and project files anywhere your account can (relative paths go to the Agent folder, and an existing file is only replaced when the agent asks to overwrite it) — every edit is a single undo step. It is off by default; besides this switch, only launching with --mcp or an agent's start request runs it, and then just until Compositor quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
    }

    /// The token switch, and copying or replacing the token. Clients that connect over HTTP send the token
    /// themselves; the compositor-mcp bridge reads it from its file.
    private var accessTokenGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Require access token", isOn: $requiresToken)
                    .toggleStyle(.switch)
                    .onChange(of: requiresToken) { _, required in
                        MCPSettings.requiresToken = required
                        do {
                            try server.setRequiresToken(required)
                            tokenError = nil
                        } catch {
                            tokenError = error.localizedDescription
                        }
                    }
                Text("Other accounts and apps on this Mac can reach 127.0.0.1 too; the token, which only you can read, keeps them from using Compositor's access to your files. The compositor-mcp bridge sends it only to this server. A client set up over HTTP sends it to whatever answers on its port, even another account's program while Compositor isn't listening there, so prefer the bridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(copied == "Token" ? "Copied ✓" : "Copy token") {
                        copy("Token") { try server.currentToken() }
                    }
                    Button("Regenerate token…") { confirmingRegenerate = true }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!requiresToken)
                if let tokenError {
                    Label(tokenError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Regenerate the access token?", isPresented: $confirmingRegenerate) {
            Button("Regenerate", role: .destructive) {
                do {
                    try server.regenerateToken()
                    tokenError = nil
                    copied = nil
                } catch {
                    tokenError = error.localizedDescription
                }
            }
        } message: {
            Text("Clients that connect over HTTP with the current token (Claude Code, Codex over HTTP) stop working until you set them up again with the new one. The compositor-mcp bridge picks up the new token automatically.")
        }
    }

    private var portRow: some View {
        HStack(spacing: 8) {
            Text("Port").font(.caption).foregroundStyle(.secondary)
            TextField("Port", text: $portText)
                .font(.caption.monospaced())
                .frame(width: 70)
                .onSubmit { apply(enteredPort) }
            Button("Apply") { apply(enteredPort) }
                .buttonStyle(.borderless).font(.caption)
                .disabled(enteredPort == nil
                          || (enteredPort == Int(server.options.preferredPort) && !server.portFellBack))
            if enteredPort == nil {
                Text("Use 1024–65535").font(.caption).foregroundStyle(.red)
            } else if Int(MCPSettings.defaultPort) != enteredPort {
                Button("Default") { apply(Int(MCPSettings.defaultPort)) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private func apply(_ port: Int?) {
        guard let port, MCPSettings.isValidPort(port) else { return }
        portText = String(port)
        MCPSettings.port = UInt16(port)
        Task { try? await server.changePreferredPort(UInt16(port)) }
    }

    /// A setup to copy: `text` as shown, and `copy` for what goes on the clipboard when it differs (the token itself
    /// where `text` shows `<token>`).
    private func snippet(_ title: String, note: String, text: String, copy: (() throws -> String)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.caption.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(copied == title ? "Copied ✓" : "Copy") { self.copy(title, copy ?? { text }) }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func copyButton(_ label: String, text: String) -> some View {
        Button(copied == label ? "Copied ✓" : "Copy") { copy(label) { text } }
            .buttonStyle(.borderless).font(.caption)
    }

    /// Puts `text()` on the clipboard, and nowhere else: it may hold the access token.
    private func copy(_ label: String, _ text: () throws -> String) {
        do {
            let value = try text()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = label
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}

/// Settings’ Folder access group (Compositor › Settings…): each location macOS guards with its Files &
/// Folders privacy controls that exists on this Mac, what the last check found, and a
/// button that asks macOS now, so its prompt appears while the owner is at the Mac rather
/// than in front of an unattended agent. A denied location links to the Files and Folders
/// settings, where access is turned on.
private struct FolderAccessGroup: View {
    @State private var requesting: Set<ProtectedRoot> = []

    /// How long a click waits for the owner to answer the macOS prompt before showing the
    /// location as still waiting.
    private static let requestTimeout: Duration = .seconds(60)

    /// System Settings → Privacy & Security → Files and Folders.
    private static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// What the checker last found for each root. The checker is observable, so a click here and
    /// a tool's own check both show up as soon as they're in.
    private var access: [ProtectedRoot: RootAccess] { FolderAccess.lastKnownAccess }

    var body: some View {
        GroupBox("Folder access") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Agents running unattended can only reach folders granted here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(FolderAccess.existingRoots, id: \.self) { root in
                    row(root)
                }
                if access.values.contains(where: { $0.state == .denied }) {
                    Text("macOS asks only once. To allow a denied location, turn it on for Compositor in System Settings > Privacy & Security > Files and Folders, or add Compositor to Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ root: ProtectedRoot) -> some View {
        let folders = requesting.contains(root) ? nil : access[root].flatMap { Self.folderSummary($0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(root.displayName)
                    .font(.caption)
                    .help(FolderAccess.activeChecker.locations[root].map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
                Spacer(minLength: 8)
                if requesting.contains(root) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for your answer…").font(.caption).foregroundStyle(.secondary)
                } else {
                    stateLabel(access[root]?.state)
                    if access[root]?.state == .denied {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettingsURL) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                Button("Request access") { request(root) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(requesting.contains(root))
            }
            if let folders {
                Text(folders)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// For a location macOS guards folder by folder, which providers or volumes are denied
    /// and which one is still waiting; nil when none are.
    nonisolated private static func folderSummary(_ access: RootAccess) -> String? {
        var parts: [String] = []
        if !access.deniedFolders.isEmpty {
            parts.append("Denied: " + access.deniedFolders.joined(separator: ", "))
        }
        if !access.pendingFolders.isEmpty {
            parts.append("Waiting for approval: " + access.pendingFolders.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func stateLabel(_ state: FolderAccessState?) -> some View {
        let (text, symbol, color): (String, String, Color) = switch state {
        case .granted: ("Granted", "checkmark.circle.fill", .green)
        case .denied: ("Denied", "xmark.circle.fill", .red)
        case .notDetermined: ("Waiting for approval", "clock", .orange)
        case .absent: ("Nothing to check", "minus.circle", .secondary)
        case nil: ("Not checked", "questionmark.circle", .secondary)
        }
        return Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    /// Probes `root` from the click, on the main run loop, so macOS shows its prompt while
    /// the owner is here. The listing itself runs off the main thread, so Settings stays
    /// responsive while the prompt is up. For a location guarded folder by folder, the probe
    /// goes past folders already denied, so each provider or volume not asked about yet
    /// gets its prompt in turn.
    private func request(_ root: ProtectedRoot) {
        requesting.insert(root)
        Task {
            // Recorded in the checker's lastKnownAccess, which this view shows.
            _ = await FolderAccess.probeAccess(root, timeout: Self.requestTimeout)
            requesting.remove(root)
        }
    }
}
