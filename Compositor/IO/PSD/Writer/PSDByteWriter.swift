import Foundation

/// Where a `PSDByteWriter`'s bytes go: appended in order, with earlier bytes overwritten in place when a
/// length field is patched after its contents are written.
nonisolated protocol PSDByteSink {
    /// Bytes appended so far: the offset the next append lands at.
    var count: Int { get }
    mutating func append(_ bytes: Data)
    /// Replaces `bytes.count` already-appended bytes starting at `offset`.
    mutating func overwrite(_ bytes: Data, at offset: Int)
}

/// Big-endian primitives for Photoshop files (Adobe's *Photoshop File Formats Specification*), written to
/// memory (`PSDDataSink`, the default) or streamed to a file (`PSDFileSink`).
nonisolated struct PSDByteWriter {
    private var sink: any PSDByteSink

    init(sink: any PSDByteSink = PSDDataSink()) {
        self.sink = sink
    }

    /// Bytes written so far: the offset of the next byte.
    var count: Int { sink.count }

    /// Everything written, for a writer backed by memory. A `PSDFileSink`'s bytes are in its file, not here.
    var data: Data { (sink as? PSDDataSink)?.data ?? Data() }

    mutating func u8(_ value: UInt8) { integer(value) }
    mutating func u16(_ value: UInt16) { integer(value) }
    mutating func u32(_ value: UInt32) { integer(value) }
    mutating func i16(_ value: Int16) { integer(value) }
    mutating func i32(_ value: Int32) { integer(value) }
    mutating func f64(_ value: Double) { integer(value.bitPattern) }

    mutating func bytes(_ data: Data) { sink.append(data) }

    /// A four-character code (signature, block key, blend key), Latin-1 and space-padded like `PSDBlockFile`'s.
    mutating func code(_ string: String) { bytes(PSDBlockFile.code(string)) }

    /// Four zero bytes for a `u32` (usually a length) that `patch(_:at:)` fills in later; returns their offset.
    mutating func reserveU32() -> Int {
        let offset = count
        u32(0)
        return offset
    }

    mutating func patch(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value.bigEndian) { sink.overwrite(Data($0), at: offset) }
    }

    /// Overwrites `bytes.count` bytes written earlier (placeholder zeros, say) starting at `offset`.
    mutating func patch(_ bytes: Data, at offset: Int) {
        sink.overwrite(bytes, at: offset)
    }

    /// Length byte, then up to 255 Mac Roman bytes (unencodable characters become `?`), zero-padded so the
    /// length byte and characters together fill a multiple of `alignment` bytes.
    mutating func pascal(_ string: String, pad alignment: Int) {
        let start = count
        let encoded = (string.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(255)
        u8(UInt8(encoded.count))
        bytes(encoded)
        pad(to: alignment, from: start)
    }

    /// `u32` count of UTF-16 code units, then the units big-endian. A terminated string counts and writes a
    /// trailing NUL unit (descriptor `TEXT`); `luni` names have none.
    mutating func unicode(_ string: String, nulTerminated: Bool) {
        let units = Array(string.utf16) + (nulTerminated ? [0] : [])
        u32(UInt32(truncatingIfNeeded: units.count))
        var encoded = Data(capacity: units.count * 2)
        for unit in units {
            encoded.append(UInt8(unit >> 8))
            encoded.append(UInt8(unit & 0xFF))
        }
        bytes(encoded)
    }

    /// Zero bytes until the bytes written since `start` are a multiple of `alignment`.
    mutating func pad(to alignment: Int, from start: Int = 0) {
        guard alignment > 1 else { return }
        let remainder = (count - start) % alignment
        if remainder > 0 { bytes(Data(count: alignment - remainder)) }
    }

    private mutating func integer<Value: FixedWidthInteger>(_ value: Value) {
        withUnsafeBytes(of: value.bigEndian) { sink.append(Data($0)) }
    }
}

/// Keeps the written bytes in memory.
nonisolated struct PSDDataSink: PSDByteSink {
    private(set) var data = Data()

    var count: Int { data.count }

    mutating func append(_ bytes: Data) { data.append(bytes) }

    mutating func overwrite(_ bytes: Data, at offset: Int) {
        precondition(offset >= 0 && offset + bytes.count <= count, "PSD patch outside the written bytes")
        let start = data.startIndex + offset
        data.replaceSubrange(start ..< start + bytes.count, with: bytes)
    }
}

/// Streams bytes into a temporary file on the destination's volume, then moves it over the destination in one
/// step (`commit`), so a failed or abandoned write never leaves a partial file where the document was. Appends
/// are buffered; a patch of bytes already on disk seeks back to them. The first I/O error stops further writes
/// and is thrown by `commit`. An instance released without `commit` removes its temporary file.
nonisolated final class PSDFileSink: PSDByteSink {
    let destination: URL
    let temporaryURL: URL
    /// The item-replacement directory holding `temporaryURL`; nil when it sits beside the destination instead.
    private let replacementDirectory: URL?
    private let capacity: Int
    private var handle: FileHandle?
    private var buffer = Data()
    /// Bytes already in the file; `buffer` holds the ones after them.
    private var flushed = 0
    private var failure: (any Error)?
    private(set) var count = 0

    init(replacing destination: URL, bufferCapacity: Int = 4 << 20) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        self.destination = destination
        capacity = max(1, bufferCapacity)
        PSDFileSink.removeUnfinishedWrites(to: destination)
        replacementDirectory = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: folder, create: true)
        temporaryURL = (replacementDirectory ?? folder)
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        do {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: temporaryURL])
            }
            handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            removeTemporaryFiles()
            throw error
        }
    }

    deinit {
        discard()
    }

    func append(_ bytes: Data) {
        count += bytes.count
        guard failure == nil else { return }
        if buffer.count + bytes.count <= capacity {
            buffer.append(bytes)
            return
        }
        flush()
        if bytes.count <= capacity { buffer.append(bytes) } else { write(bytes) }
    }

    func overwrite(_ bytes: Data, at offset: Int) {
        precondition(offset >= 0 && offset + bytes.count <= count, "PSD patch outside the written bytes")
        guard failure == nil, let handle else { return }
        if offset >= flushed {
            let start = buffer.startIndex + offset - flushed
            buffer.replaceSubrange(start ..< start + bytes.count, with: bytes)
            return
        }
        // The patch may straddle the file and the buffer: flush first so it lands in the file whole.
        flush()
        guard failure == nil else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes)
            try handle.seekToEnd()
        } catch {
            failure = error
        }
    }

    /// Writes out the buffer, closes the file and replaces the destination with it.
    func commit() throws {
        defer { discard() }
        flush()
        if let failure { throw failure }
        guard let handle else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination]) }
        self.handle = nil
        try handle.close()
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
    }

    /// Closes and removes the temporary file, leaving the destination untouched. Safe to call more than once.
    func discard() {
        try? handle?.close()
        handle = nil
        buffer = Data()
        removeTemporaryFiles()
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func write(_ bytes: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: bytes)
            flushed += bytes.count
        } catch {
            failure = error
        }
    }

    /// Removes the temporary files earlier writes to `destination` left beside it when the process died before
    /// `commit` or `discard`: `.<name>.<UUID>`, as a sink names them, and nothing else. `PSDWriter.write` coordinates
    /// its writes to a destination, so none of them belongs to a write still running.
    private static func removeUnfinishedWrites(to destination: URL) {
        let folder = destination.deletingLastPathComponent()
        let prefix = ".\(destination.lastPathComponent)."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func removeTemporaryFiles() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temporaryURL)
        if let replacementDirectory { try? fileManager.removeItem(at: replacementDirectory) }
    }
}
