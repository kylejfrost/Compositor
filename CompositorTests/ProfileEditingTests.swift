import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// The Profile adjustment's browser: opening it, choosing and previewing a profile, Amount, OK and Cancel, renaming,
/// importing, thumbnails and the panel. Every test uses the temporary library in `ProfileTestSupport`.
@MainActor struct ProfileEditingTests {
    // MARK: Helpers

    /// An 8×8 document with one opaque pixel layer and a new Profile layer above it, its browser open.
    private func browsing() async throws -> (session: EditorSession, id: UUID, edit: ProfileEdit) {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        session.addAdjustment(.profile)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        await session.refreshProfileIndex()
        return (session, id, edit)
    }

    private func summary(_ name: String, in edit: ProfileEdit) throws -> ProfileSummary {
        try #require(edit.index?.profiles.first { $0.name == name })
    }

    private func layer(_ session: EditorSession, _ id: UUID) throws -> ImageLayer {
        try #require(session.document?.layers.first { $0.id == id })
    }

    /// Chooses `name` and commits.
    private func commit(_ name: String, in session: EditorSession) async throws {
        let edit = try #require(session.profileEdit)
        await session.chooseProfile(try summary(name, in: edit))
        session.finishAdjustmentEditing(commit: true)
    }

    /// Reopens the browser on a committed layer, with its index loaded.
    private func reopen(_ session: EditorSession, _ id: UUID) async throws -> ProfileEdit {
        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        await session.refreshProfileIndex()
        return edit
    }

    /// Lets AppKit run a layout and display pass over a shown panel.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    /// A usable synthetic profile no other test uses.
    private func uniqueProfile(_ name: String) -> Data {
        ProfileFixture.xmp(name: name, uuid: ProfileAdjustmentTests.uniqueUUID(), group: "Editing Tests",
                           rgb: ProfileFixture.rgbTable(divisions: 5) { r, g, b in (min(1, r * 1.1), g, b * 0.9) })
    }

    // MARK: Opening

    @Test func addingOpensTheBrowserWithNone() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        session.addAdjustment(.profile)
        let id = try #require(session.adjustmentEditingID)
        #expect(session.activeLayerID == id)
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        #expect(edit.layerID == id)
        #expect(edit.settings.reference == nil && edit.original == ProfileAdjustmentSettings())
        #expect(max(edit.source.width, edit.source.height) <= 160)
        #expect(session.adjustmentOriginal?.kind == .profile)

        await session.refreshProfileIndex()
        let index = try #require(edit.index)
        #expect(index.usable.contains { $0.name == "Warm AdobeRGB" })
        #expect(!index.usable.contains { $0.name == "Raw Only" })
        #expect(index.hidden.rawOnly == 1)
        #expect(edit.visibleProfiles.contains { $0.name == "Warm AdobeRGB" })
        #expect(!edit.visibleProfiles.contains { $0.name == "Raw Only" })
        edit.showsUnusable = true
        #expect(edit.visibleProfiles.contains { $0.name == "Raw Only" })
        edit.showsUnusable = false
        edit.query = "warm"
        #expect(edit.visibleProfiles.map(\.name) == ["Warm AdobeRGB"])
        session.finishAdjustmentEditing(commit: false)
    }

    /// A small document drawn large (400 pixels at 300 %, 1.2 megapixels on screen) has each table it previews baked
    /// off the main thread first, for a card and for each Amount, so the canvas finds the table baked.
    @Test func aDocumentDrawnLargeIsPrebakedBeforeItsPreview() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 400)
        let document = CGSize(width: 400, height: 400)
        session.viewport.resize(to: CGSize(width: 1400, height: 1000), backingScale: 1, documentSize: document)
        session.viewport.setZoom(3, anchoredAt: session.viewport.center, documentSize: document)
        session.addAdjustment(.profile)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        let loaded = try LoadedProfile(data: uniqueProfile("Drawn Large"))
        await session.chooseProfile(loaded: loaded)
        #expect(ProfileLUTCache.bakeCount(for: ProfileLUTCache.key(for: loaded, percent: 100, options: .standard)) == 1)
        #expect(try layer(session, id).adjustment?.profile.reference?.digest == loaded.digest)

        session.setProfileAmount(140)
        // The preview waits for the table.
        #expect(try layer(session, id).adjustment?.profile.amount == 100)
        await edit.bakeTask?.value
        #expect(ProfileLUTCache.bakeCount(for: ProfileLUTCache.key(for: loaded, percent: 140, options: .standard)) == 1)
        #expect(try layer(session, id).adjustment?.profile.amount == 140)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func thumbnailSourcesAreDownsampledNeverUpsampled() throws {
        let large = try ProfileAdjustmentTests.gradient(width: 400, height: 200)
        let scaled = ProfileEdit.thumbnailSource(from: large)
        #expect(scaled.width == 160 && scaled.height == 80)
        let small = try ProfileAdjustmentTests.gradient(width: 8, height: 8)
        let kept = ProfileEdit.thumbnailSource(from: small)
        #expect(kept.width == 8 && kept.height == 8)
    }

    // MARK: Choosing, Amount, OK and Cancel

    @Test func choosingPreviewsAndOKCommitsWithRename() async throws {
        let (session, id, edit) = try await browsing()
        let warm = try summary("Warm AdobeRGB", in: edit)
        await session.chooseProfile(warm)
        #expect(edit.loading == nil)
        #expect(try layer(session, id).adjustment?.profile.reference?.digest == warm.digest)
        #expect(edit.selectedSummary?.digest == warm.digest)

        session.setProfileAmount(140)
        await edit.bakeTask?.value
        #expect(try layer(session, id).adjustment?.profile.amount == 140)

        session.finishAdjustmentEditing(commit: true)
        #expect(try layer(session, id).name == "Warm AdobeRGB")
        #expect(try layer(session, id).adjustment?.profile == ProfileAdjustmentSettings(reference: edit.settings.reference,
                                                                                         amount: 140))
        #expect(session.profileEdit == nil && session.adjustmentEditingID == nil)

        session.undo()
        #expect(try layer(session, id).adjustment?.profile == ProfileAdjustmentSettings())
        #expect(try layer(session, id).name == "Profile")
        session.undo()
        #expect(session.document?.layers.contains { $0.id == id } == false)
    }

    @Test func cancelRestores() async throws {
        let (session, id, edit) = try await browsing()
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        session.setProfileAmount(60)
        await edit.bakeTask?.value
        #expect(try layer(session, id).adjustment?.profile.amount == 60)
        session.finishAdjustmentEditing(commit: false)
        let restored = try layer(session, id)
        #expect(restored.adjustment?.profile.reference == nil)
        #expect(restored.adjustment?.profile.amount == 100)
        #expect(restored.name == "Profile")
        #expect(session.profileEdit == nil && session.adjustmentEditingID == nil)
    }

    @Test func amountIsClampedAndTheLatestWins() async throws {
        let (session, id, edit) = try await browsing()
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        session.setProfileAmount(250)
        #expect(edit.settings.amount == 200)
        session.setProfileAmount(-5)
        session.setProfileAmount(75)
        await edit.bakeTask?.value
        #expect(edit.settings.amount == 75)
        #expect(try layer(session, id).adjustment?.profile.amount == 75)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func renameOnlyReplacesDefaultNames() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        session.addAdjustment(.profile)
        let named = try #require(session.adjustmentEditingID)
        session.renameLayer(named, to: "My Grade")
        await session.beginAdjustmentEditing(named)
        await session.refreshProfileIndex()
        try await commit("Warm AdobeRGB", in: session)
        #expect(try layer(session, named).name == "My Grade")
        #expect(try layer(session, named).adjustment?.profile.reference?.name == "Warm AdobeRGB")

        let (other, id, _) = try await browsing()
        try await commit("Warm AdobeRGB", in: other)
        #expect(try layer(other, id).name == "Warm AdobeRGB")
        _ = try await reopen(other, id)
        try await commit("Film ProPhoto", in: other)
        #expect(try layer(other, id).name == "Film ProPhoto")
        // Back to None: a name that followed the profile goes back to the default.
        _ = try await reopen(other, id)
        await other.chooseProfile(nil)
        other.finishAdjustmentEditing(commit: true)
        #expect(try layer(other, id).name == "Profile")
        #expect(try layer(other, id).adjustment?.profile.reference == nil)
    }

    @Test func profilesWithoutAmountStayAt100() async throws {
        let (session, id, edit) = try await browsing()
        let noAmount = try summary("No Amount", in: edit)
        #expect(!noAmount.supportsAmount)
        await session.chooseProfile(noAmount)
        session.setProfileAmount(30)
        await edit.bakeTask?.value
        #expect(edit.settings.amount == 100)
        #expect(try layer(session, id).adjustment?.profile.amount == 100)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func choosingAProfileWithoutAmountResetsTheAmount() async throws {
        let (session, id, edit) = try await browsing()
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        session.setProfileAmount(40)
        await edit.bakeTask?.value
        await session.chooseProfile(try summary("No Amount", in: edit))
        #expect(edit.settings.amount == 100)
        #expect(try layer(session, id).adjustment?.profile.amount == 100)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func previewToggle() async throws {
        let (session, id, edit) = try await browsing()
        let warm = try summary("Warm AdobeRGB", in: edit)
        await session.chooseProfile(warm)
        session.setProfilePreview(false)
        #expect(!edit.preview)
        #expect(try layer(session, id).adjustment?.profile == ProfileAdjustmentSettings())
        session.setProfilePreview(true)
        #expect(try layer(session, id).adjustment?.profile.reference?.digest == warm.digest)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func choosingNoneClearsTheReference() async throws {
        let (session, id, edit) = try await browsing()
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        await session.chooseProfile(nil)
        #expect(edit.settings.reference == nil && edit.selectedSummary == nil)
        #expect(try layer(session, id).adjustment?.profile.reference == nil)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func aProfileThatCantBeLoadedReportsAnError() async throws {
        let (session, id, edit) = try await browsing()
        let ghost = ProfileSummary(loaded: try LoadedProfile(data: uniqueProfile("Ghost \(UUID().uuidString)")))
        await session.chooseProfile(ghost)
        #expect(edit.message == ProfileError.notLoaded(name: ghost.name).localizedDescription)
        #expect(edit.loading == nil && edit.settings.reference == nil)
        #expect(try layer(session, id).adjustment?.profile.reference == nil)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func choosingALoadedProfileRegistersIt() async throws {
        let (session, id, edit) = try await browsing()
        let loaded = try LoadedProfile(data: uniqueProfile("Loaded \(UUID().uuidString)"))
        await session.chooseProfile(loaded: loaded)
        #expect(ProfileRegistry.shared.profile(loaded.digest) != nil)
        #expect(try layer(session, id).adjustment?.profile.reference?.digest == loaded.digest)

        let rawOnly = try LoadedProfile(data: ProfileFixture.xmp(name: "Raw \(UUID().uuidString)",
                                                                 uuid: ProfileAdjustmentTests.uniqueUUID(),
                                                                 outputReferred: false,
                                                                 rgb: ProfileFixture.rgbTable(divisions: 3)))
        await session.chooseProfile(loaded: rawOnly)
        #expect(edit.message == ProfileError.rawOnly.localizedDescription)
        #expect(try layer(session, id).adjustment?.profile.reference?.digest == loaded.digest)
        session.finishAdjustmentEditing(commit: false)
    }

    // MARK: Reopening and the document's own profiles

    @Test func reopenShowsTheCurrentProfile() async throws {
        let (session, id, edit) = try await browsing()
        let warm = try summary("Warm AdobeRGB", in: edit)
        await session.chooseProfile(warm)
        session.setProfileAmount(120)
        await edit.bakeTask?.value
        session.finishAdjustmentEditing(commit: true)
        let committed = try #require(try layer(session, id).adjustment?.profile)

        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        let reopened = try #require(session.profileEdit)
        #expect(reopened !== edit)
        #expect(reopened.settings == committed && reopened.original == committed)
        await reopened.loadTask?.value
        #expect(reopened.index != nil)
        #expect(reopened.selectedSummary?.digest == warm.digest)
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func documentOnlyProfilesAreListed() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        let q = try LoadedProfile(data: uniqueProfile("Q \(UUID().uuidString)"))
        let id = try #require(session.addProfileAdjustment(q))
        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        await session.refreshProfileIndex()
        #expect(edit.index?.summary(for: q.digest) == nil)
        #expect(edit.documentProfiles.map(\.digest) == [q.digest])
        #expect(edit.documentProfiles.first?.source == .document)
        #expect(edit.selectedSummary?.digest == q.digest)
        session.finishAdjustmentEditing(commit: false)
    }

    // MARK: Importing

    @Test func importAddsAndChoosesASingleProfile() async throws {
        let (session, id, edit) = try await browsing()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = uniqueProfile("New")
        let url = folder.appendingPathComponent("New.xmp")
        try data.write(to: url)

        await session.importProfiles([url])
        #expect(edit.message?.hasPrefix("Imported 1 profile") == true, "\(edit.message ?? "nil")")
        #expect(edit.index?.profiles.contains { $0.name == "New" } == true)
        #expect(edit.settings.reference?.name == "New")
        #expect(try layer(session, id).adjustment?.profile.reference?.name == "New")
        let copy = ProfileTestSupport.locations.imported.appendingPathComponent("\(ProfileDigest(of: data).hex).xmp")
        #expect(FileManager.default.fileExists(atPath: copy.path))

        // Importing the same file again imports nothing new.
        await session.importProfiles([url])
        #expect(edit.message == "1 already imported.")
        session.finishAdjustmentEditing(commit: false)
    }

    @Test func importReportsWhatItSkipped() async throws {
        let (session, _, edit) = try await browsing()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rawOnly = folder.appendingPathComponent("Raw.xmp")
        try ProfileFixture.xmp(name: "Raw", uuid: ProfileAdjustmentTests.uniqueUUID(), outputReferred: false,
                               rgb: ProfileFixture.rgbTable(divisions: 3)).write(to: rawOnly)
        await session.importProfiles([rawOnly])
        #expect(edit.message == "1 skipped: \(ProfileError.rawOnly.localizedDescription)")
        #expect(edit.settings.reference == nil)

        let empty = folder.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await session.importProfiles([empty])
        #expect(edit.message == "Nothing to import.")
        session.finishAdjustmentEditing(commit: false)
    }

    // MARK: Thumbnails

    @Test func thumbnailsNeverRegister() async throws {
        let (session, _, edit) = try await browsing()
        let name = "Thumbnail \(UUID().uuidString)"
        let file = ProfileTestSupport.locations.adobeUser.appendingPathComponent("\(name).xmp")
        try uniqueProfile(name).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await session.refreshProfileIndex(refresh: true)
        let summary = try summary(name, in: edit)

        edit.thumbnails.request(summary, source: edit.source)
        let deadline = ContinuousClock.now + .seconds(5)
        while edit.thumbnails.image(for: summary) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try #require(edit.thumbnails.image(for: summary))
        #expect(image.width == edit.source.width && image.height == edit.source.height)
        #expect(ProfileRegistry.shared.profile(summary.digest) == nil)
        session.finishAdjustmentEditing(commit: false)
    }

    /// Refused at once, not merely unrendered after a wait: a render that finished late would pass a timed check.
    @Test func unusableProfilesGetNoThumbnail() async throws {
        let (session, _, edit) = try await browsing()
        let rawOnly = try #require(edit.index?.profiles.first { $0.name == "Raw Only" })
        #expect(!edit.thumbnails.request(rawOnly, source: edit.source))
        #expect(edit.thumbnails.image(for: rawOnly) == nil && !edit.thumbnails.hasFailed(rawOnly))
        session.finishAdjustmentEditing(commit: false)
    }

    /// A card whose picture can't be made (its file went away or changed since it was listed) is marked as failed,
    /// which shows a symbol, and isn't read and rendered again each time it scrolls into view.
    @Test func aThumbnailThatFailsIsRecordedAndNotRetried() async throws {
        let (session, _, edit) = try await browsing()
        let name = "Vanishing \(UUID().uuidString)"
        let file = ProfileTestSupport.locations.adobeUser.appendingPathComponent("\(name).xmp")
        try uniqueProfile(name).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await session.refreshProfileIndex(refresh: true)
        let summary = try summary(name, in: edit)
        try FileManager.default.removeItem(at: file)

        #expect(edit.thumbnails.request(summary, source: edit.source))
        let deadline = ContinuousClock.now + .seconds(5)
        while !edit.thumbnails.hasFailed(summary), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(edit.thumbnails.hasFailed(summary) && edit.thumbnails.image(for: summary) == nil)
        #expect(!edit.thumbnails.request(summary, source: edit.source))
        session.finishAdjustmentEditing(commit: false)
    }

    // MARK: Library changes, superseded choices and messages

    /// Opening the browser scans the library again, so a profile installed while Compositor runs (a Lightroom pack,
    /// a Camera Raw update) is listed without relaunching.
    @Test func openingTheBrowserRescansTheLibrary() async throws {
        let (session, id, _) = try await browsing()
        session.finishAdjustmentEditing(commit: false)
        let name = "Installed Later \(UUID().uuidString)"
        let file = ProfileTestSupport.locations.adobeUser.appendingPathComponent("\(name).xmp")
        try uniqueProfile(name).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        let reopened = try #require(session.profileEdit)
        await reopened.loadTask?.value
        #expect(reopened.index?.profiles.contains { $0.name == name } == true)
        session.finishAdjustmentEditing(commit: false)
    }

    /// Choosing a card whose file changed since it was listed reports it and lists the file as it is now, so the card
    /// can be chosen again.
    @Test func aProfileFileThatChangedIsListedAgain() async throws {
        let (session, _, edit) = try await browsing()
        let name = "Changing \(UUID().uuidString)"
        let file = ProfileTestSupport.locations.adobeUser.appendingPathComponent("\(name).xmp")
        try uniqueProfile(name).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await session.refreshProfileIndex(refresh: true)
        let listed = try summary(name, in: edit)
        let changed = uniqueProfile(name)
        try changed.write(to: file)
        await session.chooseProfile(listed)
        #expect(edit.message == ProfileError.digestMismatch.localizedDescription)
        #expect(edit.index?.profiles.first { $0.name == name }?.digest == ProfileDigest(of: changed))
        session.finishAdjustmentEditing(commit: false)
    }

    /// A choice superseded while its table bakes (a newer card click cancels it) doesn't preview once the bake ends.
    @Test func aChoiceCancelledWhileItsTableBakesDoesNotPreview() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 400)
        let document = CGSize(width: 400, height: 400)
        session.viewport.resize(to: CGSize(width: 1400, height: 1000), backingScale: 1, documentSize: document)
        session.viewport.setZoom(3, anchoredAt: session.viewport.center, documentSize: document)
        session.addAdjustment(.profile)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        let loaded = try LoadedProfile(data: uniqueProfile("Superseded"))
        let choice = Task { await session.chooseProfile(loaded: loaded) }
        let deadline = ContinuousClock.now + .seconds(5)
        while edit.settings.reference?.digest != loaded.digest, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        choice.cancel()
        await choice.value
        #expect(try layer(session, id).adjustment?.profile.reference == nil)
        session.finishAdjustmentEditing(commit: false)
    }

    /// Profiles chosen in the open panel are imported even when the browser closed before Import was clicked.
    @Test func importingAfterTheBrowserClosedStillImports() async throws {
        let (session, _, _) = try await browsing()
        session.finishAdjustmentEditing(commit: false)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = uniqueProfile("Late")
        let url = folder.appendingPathComponent("Late.xmp")
        try data.write(to: url)
        await session.importProfiles([url])
        let copy = ProfileTestSupport.locations.imported.appendingPathComponent("\(ProfileDigest(of: data).hex).xmp")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(session.profileEdit == nil)
    }

    /// The layer's own document-only profile stays under "In This Document" after a preview replaced it on the layer,
    /// so it can be chosen again without Cancel.
    @Test func theOriginalDocumentProfileStaysListedAfterAPreview() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        let q = try LoadedProfile(data: uniqueProfile("Q \(UUID().uuidString)"))
        let id = try #require(session.addProfileAdjustment(q))
        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        let edit = try #require(session.profileEdit)
        await edit.loadTask?.value
        #expect(edit.documentProfiles.map(\.digest) == [q.digest])
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        await session.refreshProfileIndex(refresh: true)
        #expect(edit.documentProfiles.map(\.digest) == [q.digest])
        session.finishAdjustmentEditing(commit: false)
    }

    /// An error from an earlier card goes once a profile is chosen.
    @Test func aSuccessfulChoiceClearsAnEarlierError() async throws {
        let (session, _, edit) = try await browsing()
        let ghost = ProfileSummary(loaded: try LoadedProfile(data: uniqueProfile("Ghost \(UUID().uuidString)")))
        await session.chooseProfile(ghost)
        #expect(edit.message != nil)
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        #expect(edit.message == nil)
        session.finishAdjustmentEditing(commit: false)
    }

    // MARK: Closing

    @Test func closingClearsEditState() async throws {
        _ = ProfileTestSupport.locations
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        session.addAdjustment(.profile)
        await session.beginAdjustmentEditing(try #require(session.adjustmentEditingID))
        let edit = try #require(session.profileEdit)
        let loadTask = try #require(edit.loadTask)
        session.finishAdjustmentEditing(commit: false)
        #expect(session.profileEdit == nil && session.adjustmentEditingID == nil)
        #expect(loadTask.isCancelled)
        // The scan that was running lands nowhere.
        await loadTask.value
        #expect(edit.index == nil)
    }

    @Test func guidesWaitForTheBrowser() async throws {
        let (session, _, _) = try await browsing()
        #expect(!session.canEditGuides)
        session.finishAdjustmentEditing(commit: false)
        #expect(session.canEditGuides)
    }

    @Test func panelShowsAndClosesAsCancel() async throws {
        let (session, id, edit) = try await browsing()
        let original = try #require(try layer(session, id).adjustment)
        await session.chooseProfile(try summary("Warm AdobeRGB", in: edit))
        #expect(try layer(session, id).adjustment != original)
        let controller = FloatingPanelController(name: "testProfilePanel")
        controller.onClose = { session.finishAdjustmentEditing(commit: false) }
        controller.show(title: "Profile", content: ProfileBrowserSheet(session: session))
        settle()
        let panel = try #require(NSApp.windows.first { $0.identifier == controller.identifier })
        #expect(panel.isVisible)
        #expect(panel.contentView?.frame.size == CGSize(width: 600, height: 640))
        panel.performClose(nil)
        #expect(try layer(session, id).adjustment == original)
        #expect(session.profileEdit == nil && session.adjustmentEditingID == nil)
    }

    // MARK: Keyboard

    /// Return and Escape typed in the search field while it holds a search don't commit or cancel the browser (Escape
    /// clears the search instead); with the search empty they are OK and Cancel again.
    @Test func returnAndEscapeInTheSearchFieldStayInTheField() async throws {
        let (session, _, edit) = try await browsing()
        let controller = FloatingPanelController(name: "testProfileSearchKeys")
        controller.onClose = { session.finishAdjustmentEditing(commit: false) }
        controller.show(title: "Profile", content: ProfileBrowserSheet(session: session))
        settle()
        let panel = try #require(NSApp.windows.first { $0.identifier == controller.identifier })
        func textFields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { subview -> [NSTextField] in
                if let field = subview as? NSTextField { return [field] }
                return textFields(in: subview)
            }
        }
        let content = try #require(panel.contentView)
        let search = try #require(textFields(in: content).first { $0.placeholderString == "Search profiles" })
        #expect(panel.makeFirstResponder(search))
        edit.query = "warm"
        settle()
        func key(_ characters: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        _ = panel.performKeyEquivalent(with: key("\r", 36))
        #expect(session.profileEdit === edit)
        _ = panel.performKeyEquivalent(with: key("\u{1b}", 53))
        #expect(session.profileEdit === edit)
        edit.query = ""
        settle()
        _ = panel.performKeyEquivalent(with: key("\r", 36))
        #expect(session.profileEdit == nil)
        panel.performClose(nil)
    }

    // MARK: Fidelity

    @Test func ignoredSettingsReadAsWords() {
        #expect(ProfileBrowserSheet.readableSetting("Clarity2012") == "Clarity")
        #expect(ProfileBrowserSheet.readableSetting("SplitToningShadowSaturation") == "Split Toning Shadow Saturation")
        #expect(ProfileBrowserSheet.readableSetting("Contrast2012") == "Contrast")
        #expect(ProfileBrowserSheet.readableSetting("HueAdjustmentRed") == "Hue Adjustment Red")
        #expect(ProfileBrowserSheet.readableSetting("PointColors") == "Point Colors")
    }
}
