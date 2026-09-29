import AppKit
import UniformTypeIdentifiers

/// The open Profile browser: the layer's settings being edited, the library listing and what the panel shows.
@Observable final class ProfileEdit {
    let layerID: UUID
    /// The composite below the layer, longest side at most 160 px, for the cards.
    let source: CGImage
    let original: ProfileAdjustmentSettings
    var settings: ProfileAdjustmentSettings
    var preview = true
    var query = ""
    /// nil: all groups.
    var group: String?
    var showsUnusable = false
    /// nil while the first scan runs.
    var index: ProfileIndex?
    /// Registered profiles this document uses that no library folder has.
    var documentProfiles: [ProfileSummary] = []
    /// The card being loaded.
    var loading: ProfileDigest?
    /// Import results and errors.
    var message: String?
    let thumbnails = ProfileThumbnailStore()
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var chooseTask: Task<Void, Never>?
    @ObservationIgnored var bakeTask: Task<Void, Never>?

    init(layerID: UUID, source: CGImage, settings: ProfileAdjustmentSettings) {
        self.layerID = layerID
        self.source = source
        original = settings
        self.settings = settings
    }

    var visibleProfiles: [ProfileSummary] {
        index?.search(query: query, group: group, includeUnusable: showsUnusable) ?? []
    }

    var selectedSummary: ProfileSummary? {
        guard let digest = settings.reference?.digest else { return nil }
        return index?.summary(for: digest) ?? documentProfiles.first { $0.digest == digest }
    }

    /// The chosen profile. Every chosen profile is registered, whether or not a listing has it.
    var selectedProfile: LoadedProfile? {
        settings.reference.flatMap { ProfileRegistry.shared.profile($0.digest) }
    }

    /// `image` scaled with high-quality interpolation so its longest side is at most `longestSide`; never enlarged.
    nonisolated static func thumbnailSource(from image: CGImage, longestSide: Int = 160) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longestSide, longestSide > 0 else { return image }
        let scale = CGFloat(longestSide) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return image }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

extension EditorSession {
    /// Lists the library (scanning it again with `refresh`) and the document's profiles that no folder has. The
    /// edited layer counts with the profile it had when the browser opened, which a preview has since replaced on it.
    func refreshProfileIndex(refresh: Bool = false) async {
        guard let edit = profileEdit else { return }
        let index = await ProfileLibrary.shared.index(refresh: refresh)
        guard profileEdit === edit else { return }
        edit.index = index
        let used = (document?.layers ?? []).compactMap { layer -> ProfileDigest? in
            guard layer.adjustment?.kind == .profile else { return nil }
            return layer.id == edit.layerID ? edit.original.reference?.digest
                : layer.adjustment?.profileSettings?.reference?.digest
        }
        var seen = Set<ProfileDigest>()
        edit.documentProfiles = used.compactMap { digest -> ProfileSummary? in
            guard index.summary(for: digest) == nil, seen.insert(digest).inserted,
                  let loaded = ProfileRegistry.shared.profile(digest) else { return nil }
            return ProfileSummary(loaded: loaded)
        }
    }

    /// Loads (and so registers) a listed profile and previews it; nil chooses None. Errors go to the panel's message,
    /// which a new choice clears.
    func chooseProfile(_ summary: ProfileSummary?) async {
        guard let edit = profileEdit else { return }
        edit.message = nil
        guard let summary else {
            edit.settings.reference = nil
            previewAdjustmentEditing(preview: edit.preview)
            return
        }
        edit.loading = summary.digest
        let loaded: LoadedProfile
        do {
            loaded = try await ProfileLibrary.shared.load(summary)
        } catch {
            edit.message = error.localizedDescription
            if edit.loading == summary.digest { edit.loading = nil }
            // The file changed or went away since it was listed: list the library as it is now.
            switch error as? ProfileError {
            case .digestMismatch?, .unreadable?: await refreshProfileIndex(refresh: true)
            default: break
            }
            return
        }
        // A newer click, or closing the panel, supersedes this one.
        guard profileEdit === edit, !Task.isCancelled else {
            if edit.loading == summary.digest { edit.loading = nil }
            return
        }
        await choose(loaded, in: edit)
    }

    /// Registers a profile that no listing needs to have, and previews it. Errors go to the panel's message.
    func chooseProfile(loaded: LoadedProfile?) async {
        guard let edit = profileEdit else { return }
        edit.message = nil
        guard let loaded else {
            await chooseProfile(nil)
            return
        }
        do {
            try await choose(ProfileRegistry.shared.register(loaded), in: edit)
        } catch {
            edit.message = error.localizedDescription
        }
    }

    private func choose(_ loaded: LoadedProfile, in edit: ProfileEdit) async {
        edit.settings.reference = ProfileReference(loaded)
        if !loaded.profile.support.contains(.amount) { edit.settings.amount = 100 }
        edit.loading = nil
        await prebakeIfDrawnLarge(loaded, edit.settings.amount)
        // A newer choice (which cancels this one), or closing the panel, supersedes it while the table bakes.
        guard profileEdit === edit, !Task.isCancelled, edit.settings.reference?.digest == loaded.digest else { return }
        previewAdjustmentEditing(preview: edit.preview)
    }

    /// Clamped to 0…200; always 100 for a profile without Amount. A document the canvas draws large bakes the table
    /// first, off the main thread, and only the latest Amount is previewed.
    func setProfileAmount(_ amount: Int) {
        guard let edit = profileEdit else { return }
        let range = ProfileAdjustmentSettings.amountRange
        let loaded = edit.selectedProfile
        let amount = loaded?.profile.support.contains(.amount) == false ? 100 : min(max(amount, range.lowerBound), range.upperBound)
        edit.settings.amount = amount
        let previous = edit.bakeTask
        previous?.cancel()
        guard let loaded, drawsProfilesLarge else {
            edit.bakeTask = nil
            previewAdjustmentEditing(preview: edit.preview)
            return
        }
        edit.bakeTask = Task { [weak self] in
            // One bake at a time: Amounts dragged past while it runs are skipped.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.prebakeIfDrawnLarge(loaded, amount)
            guard let self, !Task.isCancelled, self.profileEdit === edit, edit.settings.amount == amount else { return }
            self.previewAdjustmentEditing(preview: edit.preview)
        }
    }

    func setProfilePreview(_ preview: Bool) {
        guard let edit = profileEdit else { return }
        edit.preview = preview
        previewAdjustmentEditing(preview: preview)
    }

    /// Copies profiles into Compositor's library, reports the result in the panel, lists them, and chooses the one
    /// imported when there is exactly one. The open panel is non-modal, so the browser may have closed before Import
    /// was clicked: the profiles are imported all the same, with nothing to show them in.
    func importProfiles(_ urls: [URL]) async {
        let edit = profileEdit
        let report = await ProfileLibrary.shared.importProfiles(at: urls)
        guard let edit, profileEdit === edit else { return }
        edit.message = nil
        var parts: [String] = []
        if !report.imported.isEmpty {
            parts.append("Imported \(report.imported.count) profile\(report.imported.count == 1 ? "" : "s").")
        }
        if !report.alreadyImported.isEmpty { parts.append("\(report.alreadyImported.count) already imported.") }
        if let first = report.skipped.first {
            parts.append("\(report.skipped.count) skipped: \(first.error.localizedDescription)")
        }
        await refreshProfileIndex(refresh: true)
        guard profileEdit === edit else { return }
        if report.imported.count == 1 { await chooseProfile(report.imported[0]) }
        // After the choice, which clears the message; an error choosing it replaces the report.
        guard profileEdit === edit, edit.message == nil else { return }
        edit.message = parts.isEmpty ? "Nothing to import." : parts.joined(separator: " ")
    }

    /// A non-modal open panel for `.xmp` files and folders of them.
    func showProfileImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Profiles"
        panel.message = "Choose Lightroom or Camera Raw profiles, or folders that hold them."
        panel.prompt = "Import"
        if let xmp = UTType(filenameExtension: "xmp") { panel.allowedContentTypes = [xmp] }
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await self?.importProfiles(urls) }
        }
    }

    /// Whether the canvas draws more of the document than a profile is evaluated at directly, whatever the
    /// document's own size: the canvas applies adjustments to what it draws (the visible part of the document, in
    /// points), so a small document zoomed in needs the table as a large one does. The preview then waits for the
    /// table rather than having the canvas evaluate every pixel; the canvas itself never waits for a bake.
    private var drawsProfilesLarge: Bool {
        guard let document else { return false }
        let view = CGRect(origin: .zero, size: viewport.viewSize)
        let drawn = viewport.documentRect(CGSize(width: document.width, height: document.height)).intersection(view)
        return !drawn.isNull && drawn.width * drawn.height > CGFloat(ProfileRenderer.directPixelLimit)
    }

    private func prebakeIfDrawnLarge(_ loaded: LoadedProfile, _ amount: Int) async {
        guard drawsProfilesLarge else { return }
        await ProfileLUTCache.prebake(loaded, percent: amount)
    }
}
