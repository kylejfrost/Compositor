import AppKit
import SwiftUI

/// Settings’ Diagnostic logs group (Compositor › Settings…): the switches for the diagnostic log (`CompositorLog`)
/// and its verbose mode, and a button that shows its folder, so its files can be looked at or sent when something
/// goes wrong. The compositor-mcp bridge follows the same switch for its own log.
struct DiagnosticLogsGroup: View {
    @State private var isEnabled = CompositorLogSettings.isEnabled(in: .standard)
    @State private var isVerbose = CompositorLogSettings.isVerbose(in: .standard)

    var body: some View {
        GroupBox("Diagnostic logs") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep diagnostic logs", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: isEnabled) { _, enabled in CompositorLogSettings.setEnabled(enabled) }
                Toggle("Verbose (argument values of read-only calls, render timings)", isOn: $isVerbose)
                    .toggleStyle(.switch)
                    .disabled(!isEnabled)
                    .onChange(of: isVerbose) { _, verbose in CompositorLogSettings.setVerbose(verbose) }
                Text("Records what Compositor, its MCP server and the compositor-mcp bridge do — launches, agents' calls and how they ended, opens, saves and exports, and errors — in ~/Library/Logs/Compositor, kept 14 days. File paths are included; the access token, image data and document contents never are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal Logs in Finder") { reveal() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shows the log folder, made (owner-only) if nothing has been logged yet.
    private func reveal() {
        let folder = CompositorLogSettings.directoryURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
