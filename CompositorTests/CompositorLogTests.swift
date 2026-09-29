import Foundation
import Synchronization
import Testing
@testable import Compositor

/// The diagnostic log (`CompositorLog`): its JSON Lines, the privacy rules every value goes through, the switches,
/// and rotation and pruning of its files. Every log here writes to a temporary folder with an injected clock; none
/// touches `~/Library/Logs/Compositor`.
struct CompositorLogTests {
    // MARK: Lines

    @Test func eachEventIsOneJSONObjectStartingWithTimeLevelCategoryAndEvent() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        harness.log.info(.document, "open", ["path": "/tmp/Poster.psd", "bytes": 1234, "duration_ms": 12.5, "lossy": false])
        harness.log.warning(.app, "alert", ["title": "Couldn’t save\nthe \"project\""])
        let lines = try harness.lines()
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix(#"{"ts":"2026-09-24T14:03:05.123Z","level":"info","cat":"document","event":"open","#), "\(lines[0])")
        let open = try LogHarness.object(lines[0])
        #expect(open["path"] as? String == "/tmp/Poster.psd")
        #expect(open["bytes"] as? Int == 1234)
        #expect(open["duration_ms"] as? Double == 12.5)
        #expect(open["lossy"] as? Bool == false)
        let alert = try LogHarness.object(lines[1])
        #expect(alert["level"] as? String == "warning" && alert["cat"] as? String == "app")
        #expect(alert["title"] as? String == "Couldn’t save\nthe \"project\"")
    }

    @Test func timestampsAreUTCWithMilliseconds() {
        #expect(LogEncoding.timestamp(Date(timeIntervalSince1970: 1_790_258_585.123)) == "2026-09-24T14:03:05.123Z")
        #expect(LogEncoding.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(LogEncoding.timestamp(Date(timeIntervalSince1970: 59.999_7)) == "1970-01-01T00:01:00.000Z")
    }

    // MARK: Privacy

    /// The access token, an Authorization header, a credential inside text and image data never reach the file,
    /// however an event carries them.
    @Test func credentialsAndImageDataNeverReachTheFile() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let token = String(repeating: "x", count: 43) // 43 base64url characters, the access token's shape
        let base64Image = String(repeating: "iVBORw0KGgoAAAANSUhEUgAA", count: 200)
        harness.log.info(.mcp, "tool_call", [
            "token": .string(token),
            "requires_token": true,
            "authorization": "Bearer something",
            "args": .object([
                "text": .string("Paste \(token) into the client"),
                "note": "Authorization: Bearer abc.def.ghi",
                "image": .string(base64Image),
                "source": "data:image/png;base64,iVBORw0KGgo=",
                "layer": "0F6C5D8E-1B7A-4C3D-9E2F-5A6B7C8D9E0F",
                "digest": "3f786850e387550fdab836ed7e6dc881de23001b3f786850e387550fdab836ed",
                "path": "/tmp/Endorser_Portrait_Square_Final_version_2026_hq.png",
            ]),
        ])
        let text = try harness.text()
        #expect(!text.contains(token), "The token was written: \(text)")
        #expect(!text.contains("something") && !text.contains("abc.def.ghi"), "An Authorization value was written: \(text)")
        #expect(!text.contains("iVBORw0KGgo"), "Image data was written: \(text)")
        let event = try LogHarness.object(try #require(harness.lines().first))
        #expect(event["token"] as? String == "[redacted]" && event["requires_token"] as? String == "[redacted]")
        let args = try #require(event["args"] as? [String: Any])
        #expect(args["text"] as? String == "Paste [redacted] into the client")
        #expect(args["note"] as? String == "Authorization: Bearer [redacted]")
        #expect((args["image"] as? String)?.hasPrefix("[binary 4800 chars sha256:") == true, "\(args)")
        #expect((args["source"] as? String)?.hasPrefix("[binary ") == true, "\(args)")
        // Layer ids, digests and paths stay readable.
        #expect(args["layer"] as? String == "0F6C5D8E-1B7A-4C3D-9E2F-5A6B7C8D9E0F")
        #expect(args["digest"] as? String == "3f786850e387550fdab836ed7e6dc881de23001b3f786850e387550fdab836ed")
        #expect(args["path"] as? String == "/tmp/Endorser_Portrait_Square_Final_version_2026_hq.png")
    }

    @Test func longTextArraysAndNestingAreCutSayingHowMuchWasLeft() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let long = String(repeating: "Sample headline ", count: 100) // 1,600 characters
        let longPath = "/tmp/" + String(repeating: "folder/", count: 80) + "Poster.psd"
        var nested: LogValue = "bottom"
        for _ in 0..<10 { nested = .object(["inner": nested]) }
        harness.log.info(.mcp, "tool_call", [
            "text": .string(long),
            "path": .string(longPath),
            "layers": .array((0..<30).map { .int($0) }),
            "nested": nested,
        ])
        let event = try LogHarness.object(try #require(harness.lines().first))
        let text = try #require(event["text"] as? String)
        #expect(text.hasPrefix(String(long.prefix(300))) && text.hasSuffix("…(1600 chars in all)"), "\(text)")
        #expect(event["path"] as? String == longPath, "Paths up to \(LogEncoding.pathLimit) characters are kept whole")
        let layers = try #require(event["layers"] as? [Any])
        #expect(layers.count == 21 && layers.last as? String == "…(+10 more)")
        #expect(try harness.text().contains("{…}"), "Nesting past \(LogEncoding.depthLimit) levels is cut")
    }

    @Test(arguments: [
        ("Q2xhdWRlQ29kZVRva2VuMTIzNDU2Nzg5MGFiY2RlZmdo", "[redacted]"),
        ("sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD", "[redacted]"),
        ("0F6C5D8E-1B7A-4C3D-9E2F-5A6B7C8D9E0F", "0F6C5D8E-1B7A-4C3D-9E2F-5A6B7C8D9E0F"),
        ("3f786850e387550fdab836ed7e6dc881de23001b", "3f786850e387550fdab836ed7e6dc881de23001b"),
        ("a sentence with ordinary words and numbers like 2026", "a sentence with ordinary words and numbers like 2026"),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    ])
    func tokenShapedRunsAreRedactedAndOtherTextIsKept(_ text: String, _ expected: String) {
        #expect(LogEncoding.clean(text, isPath: false) == expected)
    }

    // MARK: Switches

    @Test func aDisabledLogWritesNothing() throws {
        let harness = LogHarness(enabled: false)
        defer { harness.remove() }
        harness.log.error(.app, "alert", ["title": "Couldn’t paint"])
        harness.log.flush()
        #expect(!FileManager.default.fileExists(atPath: harness.directory.path), "A disabled log made its folder")

        harness.log.setEnabled(true)
        harness.log.info(.app, "launch")
        harness.log.setEnabled(false)
        harness.log.info(.app, "after")
        #expect(try harness.lines().map { try LogHarness.object($0)["event"] as? String } == ["launch"])
    }

    @Test func debugEventsAreKeptOnlyWhenVerbose() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        harness.log.debug(.mcp, "render", ["duration_ms": 3.0])
        #expect(!harness.log.isVerbose)
        harness.log.setVerbose(true)
        #expect(harness.log.isVerbose)
        harness.log.debug(.mcp, "render", ["duration_ms": 4.0])
        let events = try harness.lines().map { try LogHarness.object($0) }
        #expect(events.count == 1 && events.first?["duration_ms"] as? Double == 4.0)
        #expect(events.first?["level"] as? String == "debug")
    }

    // MARK: The queue

    /// Events past the queue's limit are dropped rather than held, and one `log_dropped` event, written ahead of the
    /// events that were kept, says how many. Once the queue has room it takes events again.
    @Test(.timeLimit(.minutes(1)))
    func eventsPastTheQueueLimitAreDroppedAndCountedInOneEvent() throws {
        let harness = LogHarness(maxPending: 3)
        defer { harness.remove() }
        harness.log.holdingQueue {
            for index in 0..<10 { harness.log.info(.app, "tick", ["index": .int(index)]) }
        }
        var events = try harness.lines().map { try LogHarness.object($0) }
        #expect(events.map { $0["event"] as? String } == ["log_dropped", "tick", "tick", "tick"], "\(events)")
        let dropped = try #require(events.first)
        #expect(dropped["count"] as? Int == 7, "\(dropped)")
        #expect(dropped["level"] as? String == "warning" && dropped["cat"] as? String == "app", "\(dropped)")
        #expect(events.dropFirst().map { $0["index"] as? Int } == [0, 1, 2], "The first events are the ones kept")

        harness.log.info(.app, "after")
        events = try harness.lines().map { try LogHarness.object($0) }
        #expect(events.map { $0["event"] as? String } == ["log_dropped", "tick", "tick", "tick", "after"], "\(events)")
    }

    /// A log whose folder can't be made (a file stands in its place) counts each line it couldn't write. `log` never
    /// throws and never waits for the write: it returns while the queue is held. The file in the way is left alone, and
    /// once the folder can be made the log writes again.
    @Test(.timeLimit(.minutes(1)))
    func aWriteThatFailsIsCountedAndNeverHoldsUpTheCaller() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        try FileManager.default.createDirectory(at: harness.directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let inTheWay = Data("not a folder\n".utf8)
        try inTheWay.write(to: harness.directory)
        harness.log.holdingQueue {
            for index in 0..<3 { harness.log.error(.app, "alert", ["index": .int(index)]) }
        }
        harness.log.flush()
        #expect(harness.log.failedWrites == 3)
        #expect(try Data(contentsOf: harness.directory) == inTheWay, "The file in the folder's place was changed")

        try FileManager.default.removeItem(at: harness.directory)
        harness.log.info(.app, "after")
        #expect(try harness.lines().map { try LogHarness.object($0)["event"] as? String } == ["after"])
        #expect(harness.log.failedWrites == 3)
    }

    // MARK: Files

    @Test func theFolderIsOwnerOnlyAndTheFilesAreTheOwnersAlone() throws {
        let harness = LogHarness()
        defer { harness.remove() }
        harness.log.info(.app, "launch")
        harness.log.flush()
        let folder = try FileManager.default.attributesOfItem(atPath: harness.directory.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let file = try FileManager.default.attributesOfItem(atPath: harness.file("compositor-2026-09-24.jsonl").path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aDaysFileRollsOverAtItsSizeLimitAndANewDayStartsANewFile() throws {
        let harness = LogHarness(limits: LogFileLimits(maxFileBytes: 1_000, maxAgeDays: 14, maxTotalBytes: 1_000_000))
        defer { harness.remove() }
        let filler = String(repeating: "x", count: 150)
        for index in 0..<12 { harness.log.info(.app, "tick", ["index": .int(index), "note": .string(filler)]) }
        harness.log.flush()
        #expect(harness.names() == ["compositor-2026-09-24.1.jsonl", "compositor-2026-09-24.2.jsonl",
                                    "compositor-2026-09-24.jsonl"], "\(harness.names())")
        for name in harness.names() {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: harness.file(name).path)[.size] as? Int)
            #expect(size <= 1_000, "\(name) grew to \(size) bytes")
        }
        // Every event is in one of them, in order.
        let indexes = try ["compositor-2026-09-24.jsonl", "compositor-2026-09-24.1.jsonl", "compositor-2026-09-24.2.jsonl"]
            .flatMap { try harness.lines(in: $0) }.map { try LogHarness.object($0)["index"] as? Int }
        #expect(indexes == Array(0..<12))

        harness.clock.advance(by: 86_400)
        harness.log.info(.app, "next day")
        harness.log.flush()
        #expect(harness.names().contains("compositor-2026-09-25.jsonl"))
        #expect(try harness.lines(in: "compositor-2026-09-25.jsonl").count == 1)
    }

    @Test func filesPastTheAgeLimitGoThenTheOldestUntilTheRestFit() throws {
        let harness = LogHarness(limits: LogFileLimits(maxFileBytes: 1_000_000, maxAgeDays: 14, maxTotalBytes: 1_500))
        defer { harness.remove() }
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        let kilobyte = Data(repeating: 0x61, count: 1_000)
        for name in ["compositor-2026-09-01.jsonl", "compositor-2026-09-10.jsonl", "compositor-2026-09-11.jsonl",
                     "compositor-2026-09-11.1.jsonl", "compositor-2026-09-20.jsonl", "bridge.jsonl", "notes.txt"] {
            try kilobyte.write(to: harness.file(name))
        }
        harness.log.info(.app, "launch")
        harness.log.flush()
        // 09-01 and 09-10 are more than 14 days old (09-11 is the oldest day kept); then 09-11 and 09-11.1 go, oldest
        // first, until the rest (09-20 and today's new file) fit in 1,500 bytes. Files that aren't this log's stay.
        #expect(harness.names() == ["bridge.jsonl", "compositor-2026-09-20.jsonl", "compositor-2026-09-24.jsonl", "notes.txt"],
                "\(harness.names())")
    }

    @Test func logFileNamesAreParsedStrictly() {
        #expect(LogFileSink.parse(fileName: "compositor-2026-09-24.jsonl")! == ("2026-09-24", 0))
        #expect(LogFileSink.parse(fileName: "compositor-2026-09-24.3.jsonl")! == ("2026-09-24", 3))
        for name in ["compositor-2026-9-24.jsonl", "compositor-2026-09-24.0.jsonl", "compositor-2026-09-24.x.jsonl",
                     "bridge.jsonl", "compositor-2026-09-24.jsonl.bak"] {
            #expect(LogFileSink.parse(fileName: name) == nil, "\(name)")
        }
    }
}

/// A log in a fresh temporary folder, stamped by a clock the test moves.
nonisolated struct LogHarness {
    let directory: URL
    let clock: TestClock
    let log: CompositorLog

    init(enabled: Bool = true, verbose: Bool = false, limits: LogFileLimits = LogFileLimits(),
         maxPending: Int = CompositorLog.defaultMaxPending) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompositorLogTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_790_258_585.123)) // 2026-09-24T14:03:05.123Z
        self.clock = clock
        log = CompositorLog(CompositorLog.Configuration(directory: directory, isEnabled: enabled, isVerbose: verbose,
                                                        limits: limits, maxPending: maxPending,
                                                        timeZone: TimeZone(identifier: "UTC")!,
                                                        now: { clock.now }))
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The folder's file names, sorted.
    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Everything written so far, every file, once the queue is done.
    func text() throws -> String {
        log.flush()
        return try names().map { try String(contentsOf: file($0), encoding: .utf8) }.joined()
    }

    func lines() throws -> [String] {
        try text().split(separator: "\n").map(String.init)
    }

    func lines(in name: String) throws -> [String] {
        log.flush()
        return try String(contentsOf: file(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "Not an object: \(line)")
    }

    func remove() {
        log.flush()
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

/// A clock tests move by hand.
nonisolated final class TestClock: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    var now: Date { date.withLock { $0 } }
    func advance(by seconds: TimeInterval) { date.withLock { $0 += seconds } }
}
