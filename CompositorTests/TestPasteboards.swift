import AppKit

/// Private pasteboards for tests that copy and paste: one per call, so no two tests share one, and all of them released
/// when the test process exits. (Sessions in a test host already default to one private pasteboard for the process;
/// see `EditorSession.defaultPasteboard`.)
enum TestPasteboards {
    nonisolated(unsafe) private static var names: [NSPasteboard.Name] = []

    @MainActor static func unique() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        if names.isEmpty {
            atexit { for name in TestPasteboards.names { NSPasteboard(name: name).releaseGlobally() } }
        }
        names.append(pasteboard.name)
        return pasteboard
    }
}
