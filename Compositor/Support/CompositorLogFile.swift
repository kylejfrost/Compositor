import Foundation

/// How much log `CompositorLog` keeps on disk.
nonisolated struct LogFileLimits: Sendable, Equatable {
    /// A day's file rolls over to the next numbered one past this size.
    var maxFileBytes = 20 * 1024 * 1024
    /// Days of files kept, today's included.
    var maxAgeDays = 14
    /// All the files together; the oldest go first past this.
    var maxTotalBytes = 200 * 1024 * 1024
}

/// Writes log lines to `compositor-YYYY-MM-DD.jsonl` in one folder, then `compositor-YYYY-MM-DD.1.jsonl`, `.2` and so on
/// once a day's file reaches `maxFileBytes`; a new day starts a new file. Whenever it starts a file it prunes: files
/// older than `maxAgeDays` go, then the oldest until the rest fit in `maxTotalBytes` (never the file being written).
/// Ages come from the day in each file's name, so an injected clock decides them.
///
/// The folder is made owner-only (0700) and each file 0600: paths in the log say what the owner works on.
///
/// Thread safety: `@unchecked Sendable` because everything mutable is used only from its `CompositorLog`'s serial
/// queue. A failed write is counted and the file reopened next time; nothing is ever thrown to the caller.
nonisolated final class LogFileSink: @unchecked Sendable {
    static let prefix = "compositor-"
    static let suffix = ".jsonl"

    private var directory: URL?
    private var descriptor: Int32 = -1
    private var openDay: String?
    private var openIndex = 0
    private var openSize = 0

    deinit { close() }

    /// The file a day's `index`th file is written to (0: the day's first).
    static func fileName(day: String, index: Int) -> String {
        index == 0 ? "\(prefix)\(day)\(suffix)" : "\(prefix)\(day).\(index)\(suffix)"
    }

    /// The day and index a log file's name encodes; nil for any other file.
    static func parse(fileName name: String) -> (day: String, index: Int)? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stem = name.dropFirst(prefix.count).dropLast(suffix.count)
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard let day = parts.first, day.count == 10, isDay(day), parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let index = Int(parts[1]), index > 0 else { return nil }
            return (String(day), index)
        }
        return (String(day), 0)
    }

    private static func isDay(_ text: Substring) -> Bool {
        text.enumerated().allSatisfy { offset, character in
            offset == 4 || offset == 7 ? character == "-" : character.isASCII && character.isNumber
        }
    }

    /// `YYYY-MM-DD` of `date` in `timeZone`.
    static func day(of date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Closes the file; the next write opens the right one again.
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        openDay = nil
    }

    /// Appends `lines` (each without its newline), each to its day's file, in `directory`. Returns how many lines
    /// could not be written.
    func write(_ lines: [(day: String, text: String)], to directory: URL, limits: LogFileLimits,
               now: Date, timeZone: TimeZone) -> Int {
        if self.directory != directory {
            close()
            self.directory = directory
        }
        var failures = 0
        var batch = Data()
        var batchDay: String?
        func flush() {
            guard !batch.isEmpty else { return }
            if !append(batch) { failures += batch.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }
            batch = Data()
        }
        for line in lines {
            let data = Data((line.text + "\n").utf8)
            if line.day != batchDay || openSize + batch.count + data.count > limits.maxFileBytes {
                flush()
                if !prepare(day: line.day, adding: data.count, in: directory, limits: limits, now: now, timeZone: timeZone) {
                    failures += 1
                    batchDay = nil
                    continue
                }
                batchDay = line.day
            }
            batch.append(data)
        }
        flush()
        return failures
    }

    /// Makes the open file the right one for a line of `bytes` on `day`: that day's latest file, or the next one when
    /// the line wouldn't fit. Opening a file prunes. False when nothing could be opened.
    private func prepare(day: String, adding bytes: Int, in directory: URL, limits: LogFileLimits,
                         now: Date, timeZone: TimeZone) -> Bool {
        if descriptor >= 0, openDay == day, openSize == 0 || openSize + bytes <= limits.maxFileBytes { return true }
        var index: Int
        if descriptor >= 0, openDay == day {
            index = openIndex + 1
        } else {
            guard prepareDirectory(directory) else { return false }
            index = Self.files(in: directory).filter { $0.day == day }.map(\.index).max() ?? 0
        }
        close()
        while true {
            let url = directory.appendingPathComponent(Self.fileName(day: day, index: index))
            let size = Self.size(of: url)
            if size > 0, size + bytes > limits.maxFileBytes {
                index += 1
                continue
            }
            let opened = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard opened >= 0 else { return false }
            // A file made before (or by an older build) keeps its mode unless it is tightened here.
            fchmod(opened, 0o600)
            descriptor = opened
            openDay = day
            openIndex = index
            openSize = size
            prune(directory, limits: limits, now: now, timeZone: timeZone)
            return true
        }
    }

    private func append(_ data: Data) -> Bool {
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += count
                remaining -= count
            }
            return true
        }
        if written {
            openSize += data.count
        } else {
            close()
        }
        return written
    }

    /// Creates the folder owner-only, or tightens one that exists.
    private func prepareDirectory(_ directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        chmod(directory.path, 0o700)
        return true
    }

    /// The log files in `directory`, oldest first.
    static func files(in directory: URL) -> [(name: String, day: String, index: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in parse(fileName: name).map { (name, $0.day, $0.index) } }
            .sorted { ($0.day, $0.index) < ($1.day, $1.index) }
    }

    private static func size(of url: URL) -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return Int(info.st_size)
    }

    /// Deletes files from before the last `maxAgeDays` days, then the oldest until the rest fit in `maxTotalBytes`;
    /// never the file open now.
    private func prune(_ directory: URL, limits: LogFileLimits, now: Date, timeZone: TimeZone) {
        let oldestKept = Self.day(of: now.addingTimeInterval(-Double(max(0, limits.maxAgeDays - 1)) * 86_400), in: timeZone)
        let current = openDay.map { Self.fileName(day: $0, index: openIndex) }
        var kept: [(name: String, size: Int)] = []
        for file in Self.files(in: directory) where file.name != current {
            let url = directory.appendingPathComponent(file.name)
            if file.day < oldestKept {
                try? FileManager.default.removeItem(at: url)
            } else {
                kept.append((file.name, Self.size(of: url)))
            }
        }
        var total = kept.reduce(openSize) { $0 + $1.size }
        for file in kept where total > limits.maxTotalBytes {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.name))
            total -= file.size
        }
    }
}
