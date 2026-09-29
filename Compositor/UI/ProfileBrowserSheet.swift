import SwiftUI

/// The Profile adjustment's panel: Lightroom and Camera Raw profiles as cards previewed on the image below the layer,
/// the chosen profile's Amount, Preview, importing, and Cancel / OK.
struct ProfileBrowserSheet: View {
    @Bindable var session: EditorSession
    /// Group sections the user has closed ("group:<name>", or "document").
    @State private var collapsed: Set<String> = []
    @State private var showsIgnored = false
    /// While the search field has the focus and holds a search, Return and Escape belong to it rather than to OK and
    /// Cancel.
    @FocusState private var searching: Bool

    init(session: EditorSession) {
        self.session = session
    }

    private var edit: ProfileEdit? { session.profileEdit }
    private var typingSearch: Bool { searching && edit?.query.isEmpty == false }
    private static let cardWidth: CGFloat = 120
    private static let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: 12, alignment: .top), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let edit {
                header(edit)
                listing(edit)
                Divider()
                footer(edit)
            } else {
                Spacer()
            }
            Divider()
            HStack {
                Button("Cancel") { session.finishAdjustmentEditing(commit: false) }.shortcut(.escape, unless: typingSearch)
                Spacer()
                Button("OK") { session.finishAdjustmentEditing(commit: true) }
                    .shortcut(.return, unless: typingSearch).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
    }

    // MARK: Header

    private func header(_ edit: ProfileEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Search profiles", text: Bindable(edit).query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searching)
                    // Escape clears the search (OK and Cancel have Return and Escape back once it's empty).
                    .onExitCommand { edit.query = "" }
                Picker("Group", selection: Bindable(edit).group) {
                    Text("All Groups").tag(String?.none)
                    ForEach(edit.index?.groups ?? [], id: \.name) { group in
                        Text(group.name).tag(Optional(group.name))
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .trailing)
            }
            Toggle("Show profiles Compositor can't apply", isOn: Bindable(edit).showsUnusable)
            Text("Lightroom and Camera Raw profiles").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Cards

    @ViewBuilder private func listing(_ edit: ProfileEdit) -> some View {
        if let index = edit.index {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    noneCard(edit)
                    if index.usable.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No Lightroom or Camera Raw profiles found.")
                            Button("Import Profiles…") { session.showProfileImportPanel() }
                        }
                        .padding(.vertical, 8)
                    } else if edit.visibleProfiles.isEmpty {
                        Text("No profiles match.").foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Self.sections(edit.visibleProfiles), id: \.name) { section in
                        self.section(section.name, key: "group:\(section.name)", profiles: section.profiles, in: edit)
                    }
                    if !edit.documentProfiles.isEmpty {
                        section("In This Document", key: "document", profiles: edit.documentProfiles, in: edit)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Finding profiles…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Consecutive runs of one group, in display order.
    private static func sections(_ profiles: [ProfileSummary]) -> [(name: String, profiles: [ProfileSummary])] {
        var sections: [(name: String, profiles: [ProfileSummary])] = []
        for profile in profiles {
            if sections.last?.name == profile.group {
                sections[sections.count - 1].profiles.append(profile)
            } else {
                sections.append((profile.group, [profile]))
            }
        }
        return sections
    }

    private func section(_ title: String, key: String, profiles: [ProfileSummary], in edit: ProfileEdit) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(key) },
                                            set: { if $0 { collapsed.remove(key) } else { collapsed.insert(key) } })) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(profiles) { card($0, in: edit) }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(profiles.count)").foregroundStyle(.secondary)
            }
        }
    }

    private func noneCard(_ edit: ProfileEdit) -> some View {
        let selected = edit.settings.reference == nil
        return Button {
            edit.chooseTask?.cancel()
            edit.chooseTask = Task { await session.chooseProfile(nil) }
        } label: {
            CardLabel(name: "None", image: edit.source, symbol: nil, selected: selected, loading: false, approximate: false)
        }
        .buttonStyle(.plain)
        .help("No profile: the layer changes nothing")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("None")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("profileCard")
    }

    private func card(_ summary: ProfileSummary, in edit: ProfileEdit) -> some View {
        let selected = edit.settings.reference?.digest == summary.digest
        let usable = summary.usability == .usable
        let approximate = Self.ignored(summary.fidelity) != nil
        return Button {
            edit.chooseTask?.cancel()
            edit.chooseTask = Task { await session.chooseProfile(summary) }
        } label: {
            CardLabel(name: summary.name, image: edit.thumbnails.image(for: summary),
                      symbol: !usable ? "nosign" : edit.thumbnails.hasFailed(summary) ? "exclamationmark.triangle" : nil,
                      selected: selected, loading: edit.loading == summary.digest, approximate: approximate)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .help(summary.usability.error?.localizedDescription ?? summary.name)
        .onAppear { edit.thumbnails.request(summary, source: edit.source) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.name), \(summary.group)" + (approximate ? ", approximate" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("profileCard")
    }

    // MARK: Footer

    private func footer(_ edit: ProfileEdit) -> some View {
        let reference = edit.settings.reference
        let profile = edit.selectedProfile?.profile
        let supportsAmount = profile?.support.contains(.amount) ?? true
        let setsAmount = reference != nil && supportsAmount
        let ignored = profile.flatMap { Self.ignored($0.fidelity) } ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(reference?.name ?? "None").font(.headline).lineLimit(1).truncationMode(.middle)
                if let group = edit.selectedSummary?.group ?? reference?.group {
                    Text(group).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if !ignored.isEmpty {
                    Button("Approximate") { showsIgnored = true }
                        .controlSize(.small)
                        .help("Settings in this profile that Compositor doesn't apply")
                        .popover(isPresented: $showsIgnored, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(ignored, id: \.self) { Text("\(Self.readableSetting($0)) isn't applied") }
                            }
                            .padding(14)
                        }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("Amount")
                Slider(value: Binding(get: { Double(edit.settings.amount) },
                                      set: { session.setProfileAmount(Int($0.rounded())) }),
                       in: 0...200, step: 1)
                    .accessibilityLabel("Amount")
                TextField("Amount", value: Binding(get: { edit.settings.amount }, set: { session.setProfileAmount($0) }),
                          format: .number)
                    .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .unitSuffix("%")
            }
            .foregroundStyle(setsAmount ? .primary : .secondary)
            .disabled(!setsAmount)
            if reference != nil && !supportsAmount {
                Text("This profile has no Amount").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Toggle("Preview", isOn: Binding(get: { edit.preview }, set: { session.setProfilePreview($0) }))
                Spacer(minLength: 0)
                if let hidden = edit.index?.hidden.total, hidden > 0 {
                    Text("\(hidden) camera-specific or RAW-only profiles hidden")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("Compositor applies profiles to rendered images; these need a camera's raw files.")
                }
                Button("Import Profiles…") { session.showProfileImportPanel() }
            }
            if let message = edit.message {
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func ignored(_ fidelity: ProfileFidelity) -> [String]? {
        if case .approximate(let ignored) = fidelity { return ignored }
        return nil
    }

    /// A crs setting name as words: a trailing "2012" (the process version) dropped and camel case split, so
    /// "Clarity2012" reads "Clarity" and "SplitToningShadowSaturation" "Split Toning Shadow Saturation".
    static func readableSetting(_ name: String) -> String {
        let characters = Array(name.hasSuffix("2012") ? String(name.dropLast(4)) : name)
        var words = ""
        for (position, character) in characters.enumerated() {
            if position > 0, character.isUppercase {
                let previous = characters[position - 1]
                let startsWord = position + 1 < characters.count && characters[position + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && startsWord) { words.append(" ") }
            }
            words.append(character)
        }
        return words
    }
}

private extension View {
    /// The configured shortcut for `key`, except while `suppressed`.
    @ViewBuilder func shortcut(_ key: KeyEquivalent, unless suppressed: Bool) -> some View {
        if suppressed { self } else { configuredNativeShortcut(key) }
    }
}

/// One card: the profile's picture (or a symbol when it can't be applied or made), its name, and its state.
private struct CardLabel: View {
    let name: String
    let image: CGImage?
    let symbol: String?
    let selected: Bool
    let loading: Bool
    let approximate: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill()
                        .frame(width: 120, height: 90).clipped()
                } else if let symbol {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 90)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 16)).padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if approximate {
                    Text("Approximate").font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .padding(5)
                }
            }
            .overlay { if loading { ProgressView().controlSize(.small) } }
            Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 120, height: 30, alignment: .top)
        }
        .contentShape(Rectangle())
    }
}

/// Shows the Profile browser in its floating panel while a Profile layer is being edited; closing the panel cancels.
struct ProfileBrowserPanelModifier: ViewModifier {
    let session: EditorSession
    @State private var panel = FloatingPanelController(name: "profilePanel")

    func body(content: Content) -> some View {
        content.onChange(of: session.profileEdit == nil) { _, closed in
            if closed {
                panel.close()
            } else {
                panel.onClose = { session.finishAdjustmentEditing(commit: false) }
                panel.show(title: "Profile", content: ProfileBrowserSheet(session: session))
            }
        }
    }
}

extension View {
    func profileBrowserPanel(_ session: EditorSession) -> some View {
        modifier(ProfileBrowserPanelModifier(session: session))
    }
}
