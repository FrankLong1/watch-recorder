import Foundation
import os

/// On-disk home for recordings and their metadata.
///
/// Layout, under Application Support:
///
///     Captures/<uuid>.caf   in-flight PCM; an orphan here means a crash
///     Memos/<uuid>.m4a      finished, compressed memos
///     memos.json            the index
@MainActor
@Observable
final class MemoStore {

    private(set) var memos: [Memo] = []

    private let log = Logger(subsystem: "com.franklong.wristmemo", category: "MemoStore")
    private let fileManager = FileManager.default

    // A stored `let`, not a `lazy var`: @Observable synthesises an init
    // accessor for every stored `var`, and it cannot do that for a lazy one.
    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WristMemo", isDirectory: true)
    }()

    private var capturesDirectory: URL { root.appendingPathComponent("Captures", isDirectory: true) }
    private var memosDirectory: URL { root.appendingPathComponent("Memos", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("memos.json") }

    func url(for memo: Memo) -> URL {
        memosDirectory.appendingPathComponent(memo.filename)
    }

    /// A fresh path for the recorder to write into.
    func newCaptureURL(id: UUID) throws -> URL {
        try createDirectories()
        return capturesDirectory.appendingPathComponent("\(id.uuidString).caf")
    }

    private func createDirectories() throws {
        for directory in [capturesDirectory, memosDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Index

    func load() {
        do {
            try createDirectories()
            let data = try Data(contentsOf: indexURL)
            memos = try JSONDecoder().decode([Memo].self, from: data).sorted { $0.createdAt > $1.createdAt }
        } catch {
            memos = []
        }
    }

    private func persistIndex() {
        do {
            let data = try JSONEncoder().encode(memos)
            // Atomic so a kill mid-write can't leave a half-parsed index and
            // orphan every memo the user has.
            try data.write(to: indexURL, options: .atomic)
        } catch {
            log.error("Index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ memo: Memo) {
        guard let index = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        memos[index] = memo
        persistIndex()
    }

    func setSyncState(_ state: Memo.SyncState, for id: UUID) {
        guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
        memos[index].syncState = state
        persistIndex()
    }

    func delete(_ memo: Memo) {
        try? fileManager.removeItem(at: url(for: memo))
        memos.removeAll { $0.id == memo.id }
        persistIndex()
    }

    // MARK: - Finishing a recording

    /// Compresses a capture and files it as a memo.
    ///
    /// If compression fails the capture is kept as-is rather than thrown away —
    /// a large memo beats a lost one.
    func finalize(captureURL: URL, id: UUID, recovered: Bool = false) async -> Memo? {
        guard fileManager.fileExists(atPath: captureURL.path) else { return nil }

        let attributes = try? fileManager.attributesOfItem(atPath: captureURL.path)
        let createdAt = (attributes?[.creationDate] as? Date) ?? Date()
        let destination = memosDirectory.appendingPathComponent("\(id.uuidString).m4a")

        let compressed: AudioCompressor.Result? = await Task.detached(priority: .userInitiated) {
            try? AudioCompressor.compress(source: captureURL, to: destination)
        }.value

        let memo: Memo
        if let compressed {
            try? fileManager.removeItem(at: captureURL)
            memo = Memo(
                id: id,
                filename: destination.lastPathComponent,
                createdAt: createdAt,
                duration: compressed.duration,
                recovered: recovered
            )
        } else {
            log.error("Compression failed; keeping raw capture")
            let fallback = memosDirectory.appendingPathComponent("\(id.uuidString).caf")
            try? fileManager.moveItem(at: captureURL, to: fallback)
            memo = Memo(
                id: id,
                filename: fallback.lastPathComponent,
                createdAt: createdAt,
                duration: AudioCompressor.duration(of: fallback),
                recovered: recovered
            )
        }

        // Zero-length captures happen if the mic never opened; don't clutter the list.
        guard memo.duration > 0.3 else {
            try? fileManager.removeItem(at: memosDirectory.appendingPathComponent(memo.filename))
            return nil
        }

        memos.insert(memo, at: 0)
        persistIndex()
        return memo
    }

    func discardCapture(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Crash recovery

    /// Rebuilds memos from captures left behind by a previous run.
    ///
    /// Called once at launch, before any new recording claims a capture path.
    @discardableResult
    func recoverOrphanedCaptures() async -> [Memo] {
        try? createDirectories()
        let orphans = (try? fileManager.contentsOfDirectory(at: capturesDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "caf" } ?? []

        var recoveredMemos: [Memo] = []
        for orphan in orphans {
            let id = UUID(uuidString: orphan.deletingPathExtension().lastPathComponent) ?? UUID()
            log.notice("Recovering orphaned capture \(orphan.lastPathComponent, privacy: .public)")
            if let memo = await finalize(captureURL: orphan, id: id, recovered: true) {
                recoveredMemos.append(memo)
            } else {
                try? fileManager.removeItem(at: orphan)
            }
        }
        return recoveredMemos
    }
}
