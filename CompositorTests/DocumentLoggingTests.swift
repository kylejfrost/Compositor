import CoreGraphics
import Foundation
import MCP
import Testing
@testable import Compositor

/// What the diagnostic log records about documents (open, save, export, revert, close), macOS folder access (probes
/// and refusals), the profile library (scans and imports) and, when verbose, render timings. Files live in temporary
/// folders; events go to a log in a temporary folder through `CompositorLog.taskLog`.
@MainActor struct DocumentLoggingTests {
    @Test func savesExportsOpensRevertsAndClosesAreLogged() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace(width: 16, height: 8)
        let project = MCPTestSupport.tempFile("Poster.comp")
        let photoshop = project.deletingLastPathComponent().appendingPathComponent("Poster.psd")
        let picture = project.deletingLastPathComponent().appendingPathComponent("Poster.png")
        let other = MCPTestSupport.workspace()
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("save_document_as", ["path": .string(project.path)], in: workspace)
            try await MCPTestSupport.call("save_document_as", ["path": .string(photoshop.path), "set_as_current": false], in: workspace)
            try await MCPTestSupport.call("export_image", ["path": .string(picture.path)], in: workspace)
            try await MCPTestSupport.call("open_document", ["path": .string(photoshop.path)], in: other)
            try await MCPTestSupport.call("add_blank_layer", ["name": "Headline"], in: other)
            try await MCPTestSupport.call("revert_document", ["discard_changes": true], in: other)
            try await MCPTestSupport.call("add_blank_layer", ["name": "Headline"], in: workspace)
            try await MCPTestSupport.call("close_document", ["discard_changes": true], in: workspace)
        }

        let saves = try await harness.eventually(named: "save", count: 2)
        let comp = try #require(saves.first { $0["format"] as? String == "comp" }, "\(saves)")
        #expect(comp["cat"] as? String == "document" && comp["path"] as? String == project.path, "\(comp)")
        #expect(comp["kind"] as? String == "save_as" && comp["via"] as? String == "mcp", "\(comp)")
        #expect((comp["bytes"] as? Int).map { $0 > 0 } == true && comp["duration_ms"] is Double, "\(comp)")
        let psd = try #require(saves.first { $0["format"] as? String == "psd" }, "\(saves)")
        #expect(psd["kind"] as? String == "copy" && psd["path"] as? String == photoshop.path, "\(psd)")
        #expect((psd["bytes"] as? Int).map { $0 > 0 } == true, "\(psd)")
        #expect(psd["lossy"] as? Bool == false && (psd["warnings"] as? [Any])?.isEmpty == true, "\(psd)")

        let export = try #require(try harness.events(named: "export").first)
        #expect(export["path"] as? String == picture.path && export["format"] as? String == "png", "\(export)")
        #expect((export["bytes"] as? Int).map { $0 > 0 } == true && export["width"] as? Int == 16, "\(export)")

        let opens = try harness.events(named: "open")
        #expect(opens.count == 2, "The open and the revert each read the file: \(opens)")
        let open = try #require(opens.first)
        #expect(open["path"] as? String == photoshop.path && open["format"] as? String == "psd", "\(open)")
        #expect((open["bytes"] as? Int).map { $0 > 0 } == true && open["duration_ms"] is Double, "\(open)")
        #expect(open["conversions"] as? Int == 0 && open["conversion_notes"] == nil, "\(open)")

        let revert = try #require(try harness.events(named: "revert").first)
        #expect(revert["path"] as? String == photoshop.path && revert["discarded_changes"] as? Bool == true, "\(revert)")
        let close = try #require(try harness.events(named: "close").first)
        #expect(close["path"] as? String == project.path && close["discarded_changes"] as? Bool == true, "\(close)")
    }

    /// Upstream's newer files open through the same read, and the log names what each one is: a Large Document as
    /// `psb`, a Photoshop file with only a background (which opens as its merged image) by its version rather than its
    /// name, and an SVG as `svg`.
    @Test func largeDocumentsBackgroundOnlyFilesAndSVGsAreLoggedAsWhatTheyAre() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let psb = MCPTestSupport.tempFile("Poster.psb")
        let flat = psb.deletingLastPathComponent().appendingPathComponent("Flat.psd")
        let svg = psb.deletingLastPathComponent().appendingPathComponent("Logo.svg")
        defer { try? FileManager.default.removeItem(at: psb.deletingLastPathComponent()) }
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try #require(context.makeImage())
        var sky = PSDRecord(id: UUID(), name: "Sky")
        sky.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        sky.image = image
        try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: [sky]), composite: image,
                            largeDocument: true).write(to: psb)
        try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: []), composite: image,
                            largeDocument: true).write(to: flat)
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="4"><rect width="8" height="4" fill="#00f"/></svg>"##.utf8)
            .write(to: svg)
        let workspace = MCPTestSupport.workspace(width: 16, height: 8)
        try await CompositorLog.$taskLog.withValue(harness.log) {
            for url in [psb, flat, svg] { try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace) }
        }
        let opens = try harness.events(named: "open")
        var formats: [String: String] = [:]
        for event in opens { if let path = event["path"] as? String { formats[path] = event["format"] as? String } }
        #expect(formats == [psb.path: "psb", flat.path: "psb", svg.path: "svg"], "\(opens)")
        #expect(opens.allSatisfy { ($0["bytes"] as? Int).map { $0 > 0 } == true }, "\(opens)")
    }

    @Test func aFileThatCantBeOpenedIsLoggedWithTheReason() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let broken = MCPTestSupport.tempFile("Broken.psd")
        try Data("8BPS not really".utf8).write(to: broken)
        await CompositorLog.$taskLog.withValue(harness.log) {
            _ = try? await MCPTestSupport.workspace().openDocument(at: broken)
        }
        let failed = try #require(try harness.events(named: "open_failed").first)
        #expect(failed["path"] as? String == broken.path && failed["level"] as? String == "warning", "\(failed)")
        #expect((failed["error"] as? String)?.isEmpty == false, "\(failed)")
    }

    @Test func folderAccessProbesAndRefusalsAreLogged() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let home = FakeHome(roots: [.documents, .desktop])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let checker = FolderAccess.Checker(locations: home.locations, lister: { try lister.list($0) }, linkReader: { _ in nil })
        let file = home[.documents].appendingPathComponent("Poster.psd")
        await CompositorLog.$taskLog.withValue(harness.log) {
            await FolderAccess.$taskChecker.withValue(checker) {
                _ = await FolderAccess.probeAccess(.desktop, timeout: .seconds(30))
                await #expect(throws: FolderAccessError.self) { try await FolderAccess.ensureReachable(file, timeout: .seconds(30)) }
            }
        }
        let probe = try #require(try harness.events(named: "probe").first)
        #expect(probe["cat"] as? String == "folder_access" && probe["root"] as? String == "desktop", "\(probe)")
        #expect(probe["state"] as? String == "granted" && probe["duration_ms"] is Double, "\(probe)")
        let blocked = try #require(try harness.events(named: "blocked").first)
        #expect(blocked["root"] as? String == "documents" && blocked["path"] as? String == file.path, "\(blocked)")
        #expect(blocked["code"] as? String == "folder_access_denied" && blocked["level"] as? String == "warning", "\(blocked)")
    }

    @Test func profileScansAndImportsAreCounted() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentLoggingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system/Artistic", isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let look = system.appendingPathComponent("Look.xmp")
        try ProfileFixture.xmp(name: "Look", uuid: UUID().uuidString.replacingOccurrences(of: "-", with: ""), group: "Artistic",
                               rgb: ProfileFixture.rgbTable(divisions: 5)).write(to: look)
        let library = ProfileLibrary(locations: .init(adobeSystem: root.appendingPathComponent("system"),
                                                      adobeUser: root.appendingPathComponent("user"),
                                                      imported: root.appendingPathComponent("imported")))
        await CompositorLog.$taskLog.withValue(harness.log) {
            _ = await library.index()
            _ = await library.importProfiles(at: [look, root.appendingPathComponent("missing.xmp")])
        }
        let scan = try #require(try harness.events(named: "scan").first)
        #expect(scan["cat"] as? String == "profile" && scan["profiles"] as? Int == 1 && scan["usable"] as? Int == 1, "\(scan)")
        #expect(scan["hidden"] as? Int == 0 && scan["groups"] as? Int == 1 && scan["duration_ms"] is Double, "\(scan)")
        let imported = try #require(try harness.events(named: "import").first)
        #expect(imported["imported"] as? Int == 1 && imported["already_imported"] as? Int == 0, "\(imported)")
        #expect(imported["skipped"] as? Int == 1, "\(imported)")
    }

    @Test func rendersAreTimedOnlyWhenVerbose() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace(width: 32, height: 16)
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("render_document", ["max_size": 32], in: workspace)
            harness.log.setVerbose(true)
            try await MCPTestSupport.call("render_document", ["max_size": 32], in: workspace)
        }
        let renders = try harness.events(named: "render")
        #expect(renders.count == 1, "\(renders)")
        #expect(renders.first?["level"] as? String == "debug" && renders.first?["width"] as? Int == 32, "\(renders)")
        #expect(renders.first?["duration_ms"] is Double && renders.first?["layers"] is Int, "\(renders)")
        #expect((renders.first?["bytes"] as? Int).map { $0 > 0 } == true, "\(renders)")
    }
}

extension LogHarness {
    /// The first `count` events named `name`, waiting up to five seconds for them.
    func eventually(named name: String, count: Int) async throws -> [[String: Any]] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let found = try events(named: name)
            if found.count >= count { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try events(named: name)
    }
}
