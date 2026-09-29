import AppKit
import Testing
@testable import Compositor

/// Fictitious PostScript names throughout: Kanit and Jubilat are installed on this Mac, so a real
/// missing-font case needs a name nobody has. Each test resolves a name of its own, since the
/// fallback cache is shared by the whole process, and the suite is serialized: two tests post the
/// font-list notification, which clears every cached name, and must not clear each other's.
@MainActor @Suite(.serialized)
struct FontResolverTests {
    @Test func exactlyInstalledFontResolvesToItself() {
        let resolved = FontResolver.resolve("HelveticaNeue-Bold", size: 40)
        #expect(resolved.requested == "HelveticaNeue-Bold")
        #expect(resolved.font.fontName == "HelveticaNeue-Bold")
        #expect(!resolved.isSubstitute)
        #expect(FontResolver.isAvailable("HelveticaNeue-Bold"))
    }

    @Test func missingFamilyAndWeightSubstitutesBoldHelveticaNeue() {
        let resolved = FontResolver.resolve("NoSuchSubstituteSans-Bold", size: 40)
        #expect(resolved.requested == "NoSuchSubstituteSans-Bold")
        #expect(resolved.isSubstitute)
        #expect(resolved.font.familyName == "Helvetica Neue")
        #expect(NSFontManager.shared.weight(of: resolved.font) >= 8)
        #expect(!FontResolver.isAvailable("NoSuchSubstituteSans-Bold"))
    }

    @Test func serifNamedMissingFontFallsBackToItalicTimesNewRoman() {
        let resolved = FontResolver.resolve("NoSuchSerif-Italic", size: 40)
        #expect(resolved.isSubstitute)
        #expect(resolved.font.familyName == "Times New Roman")
        #expect(NSFontManager.shared.traits(of: resolved.font).contains(.italicFontMask))
    }

    @Test func garbageNamesFallBackToTheSystemFont() {
        let system = NSFont.systemFont(ofSize: 40)
        for garbage in ["", "@@@"] {
            let resolved = FontResolver.resolve(garbage, size: 40)
            #expect(resolved.isSubstitute)
            #expect(resolved.font.fontName == system.fontName)
        }
    }

    @Test func missingMemberOfAnInstalledFamilyPicksAnotherMember() {
        let resolved = FontResolver.resolve("HelveticaNeue-NoSuchWeight", size: 40)
        #expect(resolved.isSubstitute)
        #expect(resolved.font.familyName == "Helvetica Neue")
    }

    @Test func acronymFamilyNamesSplitOnCapitalRuns() {
        // Skip gracefully if SF Pro isn't registered as its own family on this machine.
        guard NSFontManager.shared.availableMembers(ofFontFamily: "SF Pro") != nil else { return }
        let resolved = FontResolver.resolve("SFPro-NoSuchWeight", size: 40)
        #expect(resolved.isSubstitute)
        #expect(resolved.font.familyName == "SF Pro")
    }

    @Test func fontListChangeClearsCachedSubstitutes() {
        let name = "NoSuchClearedSans-Bold"
        _ = FontResolver.resolve(name, size: 40)
        #expect(FontResolver.cachedRequestedNames.contains(name))
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        #expect(!FontResolver.cachedRequestedNames.contains(name))
    }

    /// Font registration can be driven by CTFontManager or another process, so the notification
    /// isn't guaranteed to arrive on the main thread; this exercises that path without triggering
    /// `MainActor.assumeIsolated`'s trap.
    @Test func fontListChangeOffTheMainThreadStillClearsTheCache() async throws {
        let name = "NoSuchOffMainSans-Bold"
        _ = FontResolver.resolve(name, size: 40)
        #expect(FontResolver.cachedRequestedNames.contains(name))
        // Posted from a background thread, where the observer runs: it hands the reset to the main
        // actor, queued by the time the post returns.
        let postedOffTheMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
                continuation.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(postedOffTheMainThread)
        // The main actor runs it once other suites let go of it: wait on the cache itself, with a
        // deadline far past any load, rather than a count of yields.
        let deadline = ContinuousClock.now + .seconds(60)
        while FontResolver.cachedRequestedNames.contains(name), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FontResolver.cachedRequestedNames.contains(name))
    }

    @Test func resolutionIsCachedButHonorsTheRequestedSize() {
        let small = FontResolver.resolve("NoSuchSizedSans-Bold", size: 12)
        let large = FontResolver.resolve("NoSuchSizedSans-Bold", size: 96)
        #expect(small.font.pointSize == 12)
        #expect(large.font.pointSize == 96)
        #expect(small.font.familyName == large.font.familyName)
    }

    @MainActor
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 400, emptyLayer: true)
        return session
    }

    @Test func missingFontsListsOnlySubstitutedLiveTextLayers() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 10, y: 10), newLayer: true)
        session.textDraft?.style.content = "Installed"
        session.textDraft?.style.fontName = "HelveticaNeue-Bold"
        #expect(session.applyText(try #require(session.textDraft)))
        let installedID = try #require(session.activeLayerID)

        session.beginText(at: CGPoint(x: 10, y: 200), newLayer: true)
        session.textDraft?.style.content = "Missing"
        session.textDraft?.style.fontName = "NoSuchLayerSans-Bold"
        #expect(session.applyText(try #require(session.textDraft)))
        let missingID = try #require(session.activeLayerID)

        let missing = session.missingFonts()
        #expect(missing.count == 1)
        let entry = try #require(missing.first)
        #expect(entry.layerID == missingID)
        #expect(entry.layerID != installedID)
        #expect(entry.requested == "NoSuchLayerSans-Bold")
        #expect(entry.resolved.contains("Helvetica Neue") || entry.resolved.contains("HelveticaNeue"))
    }
}
