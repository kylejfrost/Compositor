import AppKit

/// A font resolved for editing text imported from Photoshop, which names fonts by PostScript
/// name. `requested` is that PostScript name, verbatim; `font` is what to actually draw and edit
/// with; `isSubstitute` is true whenever `font` isn't the exact font named, so a caller can warn
/// once per missing font instead of on every keystroke. `isFamilyMatch` is true when `font` is the font named or
/// another member of its family (steps 1 and 2 below), false for a guessed fallback.
nonisolated struct ResolvedFont: Equatable {
    let requested: String
    let font: NSFont
    let isSubstitute: Bool
    var isFamilyMatch = false
}

/// Picks a font for a PostScript name Photoshop stored, falling back by family, weight and slant
/// when the exact font isn't installed. Order: (1) the exact PostScript name; (2) another member
/// of the same family, matched by weight and italic; (3) Helvetica Neue (Times New Roman for
/// serif-named fonts), with weight and slant guessed from words in the name; (4) the system font,
/// for names with no letters to guess anything from. Resolutions are cached by requested name,
/// since the family lookup in step 2 isn't free and the same handful of names repeat across a
/// document's text layers.
@MainActor
enum FontResolver {
    /// How to rebuild a resolved font at any size, once a name's fallback path has been worked
    /// out, so a different point size doesn't have to re-walk the fallback rules.
    private enum Recipe {
        case exact(String)
        case member(String)
        case family(String, NSFontTraitMask, Int)
        case system(italic: Bool)
    }

    private static var cache: [String: Recipe] = [:]

    /// Installed on first use of `resolve`: clears `cache` whenever the installed font list
    /// changes, so a font installed (or removed) mid-session is looked up again instead of
    /// reusing a stale substitute. `queue: nil` delivers the notification synchronously on
    /// whatever thread posted it, which usually is the main thread but isn't a documented
    /// guarantee (font registration can be driven by CTFontManager or another process), so this
    /// only asserts main-actor isolation once `Thread.isMainThread` confirms it; off the main
    /// thread it hops there with a `Task` instead of risking `assumeIsolated`'s trap.
    private static let fontListObserver: NSObjectProtocol = {
        NotificationCenter.default.addObserver(forName: NSFont.fontSetChangedNotification, object: nil, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { FontResolver.resetCache() }
            } else {
                Task { @MainActor in FontResolver.resetCache() }
            }
        }
    }()

    static func resolve(_ postScriptName: String, size: CGFloat) -> ResolvedFont {
        _ = fontListObserver
        let recipe: Recipe
        if let cached = cache[postScriptName] {
            recipe = cached
        } else {
            recipe = makeRecipe(postScriptName)
            cache[postScriptName] = recipe
        }
        switch recipe {
        case .exact(let name):
            return ResolvedFont(requested: postScriptName, font: NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size),
                                isSubstitute: false, isFamilyMatch: true)
        case .member(let name):
            return ResolvedFont(requested: postScriptName, font: NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size),
                                isSubstitute: true, isFamilyMatch: true)
        case .family(let family, let traits, let weight):
            let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: weight, size: size) ?? NSFont.systemFont(ofSize: size)
            return ResolvedFont(requested: postScriptName, font: font, isSubstitute: true)
        case .system(let italic):
            let base = NSFont.systemFont(ofSize: size)
            let font = italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
            return ResolvedFont(requested: postScriptName, font: font, isSubstitute: true)
        }
    }

    /// Whether `postScriptName` names an installed font exactly, the same check step 1 of
    /// `resolve` uses.
    static func isAvailable(_ postScriptName: String) -> Bool {
        NSFont(name: postScriptName, size: 12) != nil
    }

    /// Clears cached fallback recipes. Called when the installed font list changes; also a test
    /// hook, alongside `cachedRequestedNames`, for verifying that wiring without installing a
    /// real font.
    static func resetCache() { cache.removeAll() }

    /// Test hook: the requested names `resolve` has a cached fallback recipe for.
    static var cachedRequestedNames: Set<String> { Set(cache.keys) }

    private static func makeRecipe(_ postScriptName: String) -> Recipe {
        if NSFont(name: postScriptName, size: 12) != nil { return .exact(postScriptName) }
        // Nothing here to read a family or style out of; guess nothing rather than guess wrong.
        guard postScriptName.contains(where: { $0.isLetter }) else { return .system(italic: false) }
        let (family, style) = splitFamilyStyle(postScriptName)
        if let member = matchingMember(family: family, style: style) { return .member(member) }
        let fallbackFamily = isSerif(postScriptName) ? "Times New Roman" : "Helvetica Neue"
        var traits: NSFontTraitMask = []
        if isItalic(style) { traits.insert(.italicFontMask) }
        return .family(fallbackFamily, traits, weight(from: style) ?? 5)
    }

    /// `"Family-Style"` split on the first `-`; the whole name and an empty style when there
    /// isn't one.
    private static func splitFamilyStyle(_ name: String) -> (family: String, style: String) {
        guard let dash = name.firstIndex(of: "-") else { return (name, "") }
        return (String(name[name.startIndex ..< dash]), String(name[name.index(after: dash)...]))
    }

    /// The best member of `family` for `style`'s weight and italic words, tried under its raw
    /// PostScript prefix (`"HelveticaNeue"`), a space-inserted display name split at both
    /// lower/digit→upper and acronym boundaries (`"SFPro"` → `"SF Pro"`, `"SFProDisplay"` →
    /// `"SF Pro Display"`), and finally a case-insensitive match against every installed family
    /// with its spaces removed, since Photoshop names families the first way and AppKit registers
    /// most of them the second, with the rare one not reachable by either split.
    ///
    /// Note: some Photoshop-authored designs register a weight as its own separate, narrow family
    /// instead of a member of the main one — e.g. "Jubilat Medium" alongside "Jubilat" — so this
    /// family's member pool may not be the font's whole design family.
    private static func matchingMember(family: String, style: String) -> String? {
        guard !family.isEmpty else { return nil }
        var members: [[Any]]?
        for candidate in candidateFamilies(for: family) {
            if let found = NSFontManager.shared.availableMembers(ofFontFamily: candidate), !found.isEmpty {
                members = found
                break
            }
        }
        guard let members else { return nil }
        let targetWeight = weight(from: style) ?? 5
        let targetItalic = isItalic(style)
        var best: (name: String, score: Int)?
        for member in members {
            guard member.count >= 4, let name = member[0] as? String, let weight = member[2] as? Int else { continue }
            let traitsValue = (member[3] as? Int).map { NSFontTraitMask(rawValue: UInt($0)) } ?? []
            let italic = traitsValue.contains(.italicFontMask)
            let score = abs(weight - targetWeight) * 2 + (italic == targetItalic ? 0 : 1)
            if best == nil || score < best!.score { best = (name, score) }
        }
        return best?.name
    }

    /// NSFontManager's weight scale, 0–15; checked most-specific keyword first so `"SemiBold"`
    /// and `"ExtraBold"` aren't caught by a plain `"Bold"` match.
    private static let weightKeywords: [(String, Int)] = [
        ("Thin", 2), ("Hairline", 2), ("ExtraLight", 3), ("UltraLight", 3), ("Light", 4),
        ("Regular", 5), ("Book", 5), ("Roman", 5), ("Normal", 5), ("Medium", 6),
        ("SemiBold", 8), ("DemiBold", 8), ("ExtraBold", 10), ("Heavy", 10), ("Bold", 9),
        ("Black", 11), ("Ultra", 11),
    ]

    private static func weight(from text: String) -> Int? {
        for (keyword, weight) in weightKeywords where text.range(of: keyword, options: .caseInsensitive) != nil {
            return weight
        }
        return nil
    }

    private static func isItalic(_ text: String) -> Bool {
        text.range(of: "Italic", options: .caseInsensitive) != nil || text.range(of: "Oblique", options: .caseInsensitive) != nil
    }

    private static func isSerif(_ text: String) -> Bool {
        ["Serif", "Times", "Georgia", "Jubilat", "Garamond", "Caslon", "Baskerville"]
            .contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// `family`'s raw form, its acronym-aware camel-case split, and (if neither is an installed
    /// family) whichever installed family matches it with spaces removed, case-insensitively.
    private static func candidateFamilies(for family: String) -> [String] {
        var candidates = [family, spacedCamelCase(family)]
        let normalized = family.replacingOccurrences(of: " ", with: "").lowercased()
        if let match = NSFontManager.shared.availableFontFamilies.first(where: {
            $0.replacingOccurrences(of: " ", with: "").lowercased() == normalized
        }) {
            candidates.append(match)
        }
        return candidates
    }

    /// Inserts a space at each camel-case word boundary: a lowercase letter or digit followed by
    /// an uppercase one (`"HelveticaNeue"` → `"Helvetica Neue"`), and, within a run of uppercase
    /// letters, before its last letter when that starts a new lowercase word (`"SFPro"` →
    /// `"SF Pro"`, `"SFProDisplay"` → `"SF Pro Display"` — the standard acronym-boundary rule, as
    /// in "HTTPRequest" → "HTTP Request").
    private static func spacedCamelCase(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            if index > 0 {
                let previous = characters[index - 1]
                let afterLowerOrDigit = character.isUppercase && (previous.isLowercase || previous.isNumber)
                let acronymBoundary = character.isUppercase && previous.isUppercase
                    && index + 1 < characters.count && characters[index + 1].isLowercase
                if afterLowerOrDigit || acronymBoundary { result.append(" ") }
            }
            result.append(character)
        }
        return result
    }
}
