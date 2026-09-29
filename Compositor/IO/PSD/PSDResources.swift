import Foundation

/// Decodes the image resources `PSDReader` keeps verbatim in `PSDDocumentExtras.resources` but doesn't need to
/// read itself: guides (1032), the global light angle/altitude (1037/1049), alpha channel names (1006/1045) and
/// the ICC profile description (1039). Nothing here fails an import: data too short or otherwise malformed yields
/// an empty result rather than throwing.
nonisolated enum PSDResources {
    /// Resource 1032: `u32 version(1) · u32 gridCycleH · u32 gridCycleV · u32 count · count × (u32 location in
    /// 1/32 px, u8 direction: 0 vertical, 1 horizontal)`. A guide outside ±1,000,000 px is dropped; a count larger
    /// than the remaining bytes is capped rather than read past the end. A header that can't even be read (too
    /// short, or a version other than 1) yields no guides — see `guidesAreMalformed` for reporting that case.
    static func parseGuides(_ data: Data) -> [CanvasGuide] {
        guides(data, limit: .max).guides
    }

    /// The most guides a project saves (`ProjectStore`), and so the most an import keeps.
    static let maximumGuides = 1_000

    /// Resource 1032's first `limit` guides, in file order, and how many it holds in all (`total`, those
    /// `parseGuides` would read): guides are made for the ones kept only, however many the resource claims.
    static func guides(_ data: Data, limit: Int) -> (guides: [CanvasGuide], total: Int) {
        guard !guidesAreMalformed(data) else { return ([], 0) }
        let count = min(Int(u32(data, 12)), (data.count - headerSize) / guideEntrySize)
        var guides: [CanvasGuide] = []
        guides.reserveCapacity(min(count, max(0, limit)))
        var total = 0
        var offset = headerSize
        for _ in 0..<count {
            let location = Int32(bitPattern: u32(data, offset))
            let direction = data[data.startIndex + offset + 4]
            offset += guideEntrySize
            let position = Double(location) / 32
            guard position > -1_000_000, position < 1_000_000 else { continue }
            total += 1
            if guides.count < limit {
                guides.append(CanvasGuide(id: UUID(), axis: direction == 1 ? .horizontal : .vertical, position: position))
            }
        }
        return (guides, total)
    }

    /// Whether resource 1032's data is too broken to parse at all (unreadable header or unsupported version),
    /// warranting a note rather than silently producing no guides. A short guide list (count capped to the
    /// remaining bytes) is not malformed by itself.
    static func guidesAreMalformed(_ data: Data) -> Bool {
        guard data.count >= headerSize else { return !data.isEmpty }
        return u32(data, 0) != 1
    }

    /// Resources 1037 (angle) and 1049 (altitude), Photoshop's global light for layer effects.
    static func globalLight(_ resources: [PSDImageResource]) -> (angle: Double?, altitude: Double?) {
        var angle: Double?, altitude: Double?
        for resource in resources {
            let data = resource.data
            switch resource.id {
            case 1037 where data.count >= 4: angle = Double(Int32(bitPattern: u32(data, 0)))
            case 1049 where data.count >= 4: altitude = Double(Int32(bitPattern: u32(data, 0)))
            default: break
            }
        }
        return (angle, altitude)
    }

    /// Alpha channel names: Unicode (1045) when present, else Pascal strings (1006).
    static func alphaNames(_ resources: [PSDImageResource]) -> [String] {
        var pascal: [String]?, unicode: [String]?
        for resource in resources {
            switch resource.id {
            case 1006: pascal = pascalStrings(resource.data)
            case 1045: unicode = unicodeStrings(resource.data)
            default: break
            }
        }
        return unicode ?? pascal ?? []
    }

    /// The `desc` tag of an ICC profile (v2 `desc` or v4 `mluc`, first record); resource 1039's data. Nil when
    /// absent or the data is too short to hold what it claims.
    static func iccDescription(_ data: Data) -> String? {
        guard data.count >= 132 else { return nil }
        let tagCount = Int(u32(data, 128))
        for index in 0..<min(tagCount, 1_000) {
            let entry = 132 + index * 12
            guard entry + 12 <= data.count else { return nil }
            guard data.subdata(in: entry ..< entry + 4) == Data("desc".utf8) else { continue }
            let start = Int(u32(data, entry + 4)), size = Int(u32(data, entry + 8))
            guard start >= 0, size >= 12, start <= data.count - size else { return nil }
            let type = data.subdata(in: start ..< start + 4)
            if type == Data("desc".utf8) {
                let length = Int(u32(data, start + 8))
                guard length <= size - 12 else { return nil }
                let text = String(decoding: data.subdata(in: start + 12 ..< start + 12 + length), as: UTF8.self)
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            if type == Data("mluc".utf8) {
                guard size >= 28, u32(data, start + 8) >= 1 else { return nil }
                let length = Int(u32(data, start + 20)), offset = Int(u32(data, start + 24))
                guard length % 2 == 0, offset <= size, length <= size - offset else { return nil }
                var units: [UInt16] = []
                for i in stride(from: 0, to: length, by: 2) {
                    units.append(UInt16(data[start + offset + i]) << 8 | UInt16(data[start + offset + i + 1]))
                }
                return String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            return nil
        }
        return nil
    }

    /// Resource 1006: consecutive Pascal strings.
    private static func pascalStrings(_ data: Data) -> [String] {
        var names: [String] = [], offset = 0
        while offset < data.count, names.count < 56 {
            let length = Int(data[data.startIndex + offset])
            guard offset + 1 + length <= data.count else { break }
            let bytes = data.subdata(in: data.startIndex + offset + 1 ..< data.startIndex + offset + 1 + length)
            names.append(String(data: bytes, encoding: .macOSRoman) ?? "")
            offset += 1 + length
        }
        return names
    }

    /// Resource 1045: `u32 count` + UTF-16BE strings, each `u32 length` (code units) + the UTF-16BE text.
    private static func unicodeStrings(_ data: Data) -> [String] {
        var names: [String] = [], offset = 0
        while offset + 4 <= data.count, names.count < 56 {
            let count = Int(u32(data, offset))
            guard count <= (data.count - offset - 4) / 2 else { break }
            names.append(unicodeName(data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + 4 + count * 2)) ?? "")
            offset += 4 + count * 2
        }
        return names
    }

    private static func unicodeName(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let count = Int(u32(data, 0))
        guard count > 0, data.count >= 4 + count * 2 else { return nil }
        var units = [UInt16]()
        units.reserveCapacity(count)
        for i in 0..<count {
            let hi = data[data.startIndex + 4 + i * 2], lo = data[data.startIndex + 5 + i * 2]
            units.append(UInt16(hi) << 8 | UInt16(lo))
        }
        return String(utf16CodeUnits: units, count: count).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static let headerSize = 16
    private static let guideEntrySize = 5

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }
}
