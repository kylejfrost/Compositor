import Foundation
import Testing
@testable import Compositor

@Suite
struct PSDByteWriterTests {
    private func bytes(_ write: (inout PSDByteWriter) -> Void) -> [UInt8] {
        var writer = PSDByteWriter()
        write(&writer)
        return Array(writer.data)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PSDByteWriterTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Lengths patched before and after the sink's buffer reaches the disk, around a run of plain writes.
    private func sample(_ writer: inout PSDByteWriter) {
        writer.code("8BPS")
        let outer = writer.reserveU32()
        for value in 0 ..< 40 { writer.u16(UInt16(value)) }
        let inner = writer.reserveU32()
        writer.bytes(Data(repeating: 7, count: 50))
        writer.patch(UInt32(writer.count - inner - 4), at: inner)
        writer.pascal("Layer 1", pad: 4)
        writer.patch(UInt32(writer.count - outer - 4), at: outer)
        writer.unicode("Hi", nulTerminated: false)
    }

    @Test func numbersAreBigEndian() {
        let written = bytes {
            $0.u8(0xAB)
            $0.u16(0x0102)
            $0.u32(0x0304_0506)
            $0.i16(-2)
            $0.i32(-3)
            $0.f64(1.5)
        }
        #expect(written == [0xAB, 1, 2, 3, 4, 5, 6, 0xFF, 0xFE, 0xFF, 0xFF, 0xFF, 0xFD,
                            0x3F, 0xF8, 0, 0, 0, 0, 0, 0])
    }

    @Test func codesAreFourLatin1Bytes() {
        #expect(bytes { $0.code("8BIM") } == Array("8BIM".utf8))
        #expect(bytes { $0.code("mul") } == Array("mul ".utf8))
    }

    @Test func reservedLengthIsPatchedInPlace() {
        var writer = PSDByteWriter()
        writer.code("8BIM")
        let offset = writer.reserveU32()
        #expect(offset == 4)
        writer.bytes(Data([1, 2, 3]))
        writer.patch(UInt32(writer.count - offset - 4), at: offset)
        #expect(writer.count == 11)
        #expect(Array(writer.data) == Array("8BIM".utf8) + [0, 0, 0, 3, 1, 2, 3])
    }

    @Test func pascalStringsAreMacRomanPaddedWithTheirLengthByte() {
        #expect(bytes { $0.pascal("Ab", pad: 4) } == [2, 0x41, 0x62, 0])
        #expect(bytes { $0.pascal("Layer 1", pad: 4) } == [7] + Array("Layer 1".utf8))
        #expect(bytes { $0.pascal("", pad: 2) } == [0, 0])
        #expect(bytes { $0.pascal("", pad: 4) } == [0, 0, 0, 0])
        #expect(bytes { $0.pascal("é", pad: 2) } == [1, 0x8E])
        #expect(bytes { $0.pascal("✓", pad: 1) } == [1, UInt8(ascii: "?")])
        let long = bytes { $0.pascal(String(repeating: "x", count: 300), pad: 4) }
        #expect(long.count == 256)
        #expect(long.first == 255)
        // Padding counts from the string's own start, not from the start of the output.
        #expect(bytes { $0.u8(9); $0.pascal("Ab", pad: 4) } == [9, 2, 0x41, 0x62, 0])
    }

    @Test func unicodeStringsCountUTF16UnitsAndAnOptionalNul() {
        #expect(bytes { $0.unicode("Hi", nulTerminated: true) } == [0, 0, 0, 3, 0, 0x48, 0, 0x69, 0, 0])
        #expect(bytes { $0.unicode("Hi", nulTerminated: false) } == [0, 0, 0, 2, 0, 0x48, 0, 0x69])
        #expect(bytes { $0.unicode("", nulTerminated: true) } == [0, 0, 0, 1, 0, 0])
        #expect(bytes { $0.unicode("😀", nulTerminated: false) } == [0, 0, 0, 2, 0xD8, 0x3D, 0xDE, 0x00])
    }

    @Test func padAlignsFromAStartOffset() {
        var writer = PSDByteWriter()
        writer.bytes(Data([9, 9, 9, 9, 9]))
        writer.pad(to: 4)
        #expect(writer.count == 8)
        writer.pad(to: 4)
        #expect(writer.count == 8)
        let start = writer.count - 3
        writer.u8(1)
        writer.pad(to: 4, from: start)
        #expect(writer.count == 9)
        writer.u8(2)
        writer.pad(to: 2, from: start)
        #expect(Array(writer.data) == [9, 9, 9, 9, 9, 0, 0, 0, 1, 2, 0])
    }

    @Test func fileSinkWritesWhatMemoryWritesPatchingFlushedBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.psd")
        var memory = PSDByteWriter()
        sample(&memory)
        // A 16-byte buffer puts both patched lengths on disk before they are patched.
        let sink = try PSDFileSink(replacing: url, bufferCapacity: 16)
        var file = PSDByteWriter(sink: sink)
        sample(&file)
        #expect(file.count == memory.count)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try sink.commit()
        #expect(try Data(contentsOf: url) == memory.data)
        #expect(!FileManager.default.fileExists(atPath: sink.temporaryURL.path))
    }

    @Test func committingReplacesAnExistingFileOnlyAtTheEnd() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.psd")
        try Data("old".utf8).write(to: url)
        let sink = try PSDFileSink(replacing: url)
        var writer = PSDByteWriter(sink: sink)
        writer.code("8BPS")
        writer.u16(1)
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        try sink.commit()
        #expect(Array(try Data(contentsOf: url)) == Array("8BPS".utf8) + [0, 1])
    }

    @Test func discardingLeavesNoFileBehind() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("abandoned.psd")
        let sink = try PSDFileSink(replacing: url)
        var writer = PSDByteWriter(sink: sink)
        writer.u32(1)
        #expect(FileManager.default.fileExists(atPath: sink.temporaryURL.path))
        sink.discard()
        #expect(!FileManager.default.fileExists(atPath: sink.temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A write the process never finished (it died before commit or discard) leaves its temporary file beside the
    /// destination; the next write to that file removes it, and nothing else.
    @Test func aNewWriteRemovesTemporaryFilesAnUnfinishedWriteLeftBesideItsDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.psd")
        let stale = directory.appendingPathComponent(".out.psd.\(UUID().uuidString)")
        let kept = [".out.psd.notes", ".other.psd.\(UUID().uuidString)", "out.psd.\(UUID().uuidString)", ".out.psd"]
            .map { directory.appendingPathComponent($0) }
        for file in [stale] + kept { try Data("x".utf8).write(to: file) }
        let sink = try PSDFileSink(replacing: url)
        var writer = PSDByteWriter(sink: sink)
        writer.u32(1)
        try sink.commit()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: url) == Data([0, 0, 0, 1]))
    }

    @Test func aFailedCommitThrowsAndCleansUp() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("gone.psd")
        let sink = try PSDFileSink(replacing: url)
        var writer = PSDByteWriter(sink: sink)
        writer.u32(1)
        try FileManager.default.removeItem(at: directory)
        #expect(throws: (any Error).self) { try sink.commit() }
        #expect(!FileManager.default.fileExists(atPath: sink.temporaryURL.path))
    }
}
