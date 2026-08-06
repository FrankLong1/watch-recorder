import AVFoundation
import Foundation
import Testing

/// Exercises the real on-disk layout against a temporary root, via
/// `MemoStore(rootURL:)`. Nothing here touches an app container.
@MainActor
@Suite("MemoStore")
struct MemoStoreTests {

    /// A unique root per test, cleaned up by the caller.
    private static func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MemoStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func seedIndex(_ memos: [Memo], at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(memos)
        try data.write(to: root.appendingPathComponent("memos.json"))
    }

    /// A *real* PCM CAF in the capture format, so `finalize` actually decodes,
    /// compresses and files it. An earlier version of these tests wrote zero
    /// bytes; compression failed, `finalize` returned nil, and the ordering
    /// assertions below became vacuous — they passed with the bug reintroduced.
    private static func writeCapture(seconds: Double, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: CaptureFormat.sampleRate,
            channels: AVAudioChannelCount(CaptureFormat.channels),
            interleaved: true
        ) else { throw CocoaError(.fileWriteUnknown) }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(CaptureFormat.sampleRate * seconds)
        // The buffer must be in the file's *processing* format (float), not its
        // on-disk format. Handing `write(from:)` a mismatched buffer raises an
        // ObjC exception, which takes the whole test process down rather than
        // failing one test.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames  // silence; only the duration matters here
        try file.write(from: buffer)
    }

    private static func memo(_ name: String, secondsAgo: TimeInterval) -> Memo {
        Memo(
            id: UUID(),
            filename: "\(name).m4a",
            createdAt: Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(-secondsAgo),
            duration: 5
        )
    }

    @Test("loadIfNeeded sorts a shuffled index newest-first")
    func loadSorts() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldest = Self.memo("oldest", secondsAgo: 300)
        let middle = Self.memo("middle", secondsAgo: 200)
        let newest = Self.memo("newest", secondsAgo: 100)
        // Deliberately out of order on disk.
        try Self.seedIndex([middle, oldest, newest], at: root)

        let store = MemoStore(rootURL: root)
        store.loadIfNeeded()

        #expect(store.memos.map(\.filename) == ["newest.m4a", "middle.m4a", "oldest.m4a"])
    }

    /// The bug this guards: `finalize` used to `insert(at: 0)`, so a capture
    /// recovered from a crash jumped to the top of the list regardless of when
    /// it was actually recorded.
    @Test("a recovered older capture sorts by its own date, not to the top")
    func recoveredCaptureSortsByDate() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let recent = Self.memo("recent", secondsAgo: 10)
        try Self.seedIndex([recent], at: root)

        let store = MemoStore(rootURL: root)
        store.loadIfNeeded()

        // A capture whose creation date is far older than the indexed memo.
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let id = UUID()
        let capture = captures.appendingPathComponent("\(id.uuidString).caf")
        try Self.writeCapture(seconds: 2, to: capture)
        let old = recent.createdAt.addingTimeInterval(-86_400)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: capture.path)

        let recovered = await store.finalize(captureURL: capture, id: id)

        // Guard the guard: if finalize bailed, every assertion below is vacuous.
        try #require(recovered != nil, "finalize rejected a valid capture — test proves nothing")
        #expect(store.memos.count == 2)

        let dates = store.memos.map(\.createdAt)
        #expect(dates == dates.sorted(by: >), "index is not newest-first: \(dates)")
        #expect(store.memos.first?.filename == "recent.m4a",
                "older recovered capture displaced the newer memo")
        #expect(store.memos.last?.id == id,
                "recovered capture should sort last, by its own date")
    }

    /// The ordinary path: a memo recorded now belongs at the top.
    @Test("a freshly recorded capture lands first")
    func freshCaptureSortsFirst() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let older = Self.memo("older", secondsAgo: 86_400)
        try Self.seedIndex([older], at: root)

        let store = MemoStore(rootURL: root)
        store.loadIfNeeded()

        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let id = UUID()
        let capture = captures.appendingPathComponent("\(id.uuidString).caf")
        try Self.writeCapture(seconds: 1.5, to: capture)

        let saved = await store.finalize(captureURL: capture, id: id)

        try #require(saved != nil, "finalize rejected a valid capture")
        #expect(store.memos.first?.id == id, "a just-recorded memo should be first")
        #expect(store.memos.count == 2)
        let dates = store.memos.map(\.createdAt)
        #expect(dates == dates.sorted(by: >))
        #expect(!FileManager.default.fileExists(atPath: capture.path),
                "the capture should be consumed once compressed")
    }

    /// A pre-armed recorder creates a header-only file. It must be rejected
    /// before an AAC encoder is ever started, and removed from disk.
    @Test("a header-only capture is rejected and deleted before compression")
    func headerOnlyCaptureRejected() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MemoStore(rootURL: root)
        store.loadIfNeeded()

        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let id = UUID()
        let capture = captures.appendingPathComponent("\(id.uuidString).caf")
        // 4096 bytes is what `prepareToRecord()` leaves behind — below the
        // 0.3s minimum, which is 13230 audio bytes.
        try Data(count: 4096).write(to: capture)

        let memo = await store.finalize(captureURL: capture, id: id)

        #expect(memo == nil, "header-only capture should not become a memo")
        #expect(store.memos.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: capture.path),
                "rejected capture should be removed from disk")
    }

    @Test("the byte threshold matches the documented capture format")
    func captureFormatArithmetic() {
        // 22050 Hz * 2 bytes * 0.3s
        #expect(CaptureFormat.bytes(forSeconds: 0.3) == 13_230)
        #expect(CaptureFormat.bytes(forSeconds: 1) == 44_100)
    }
}
