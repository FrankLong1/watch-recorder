import Foundation

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

    private let log = SharedConfig.logger("MemoStore")
    private let fileManager = FileManager.default

    // Stored, not computed: these are rebuilt on every access otherwise, and
    // `memosDirectory` alone is hit four times per save.
    private let capturesDirectory: URL
    private let memosDirectory: URL
    private let indexURL: URL

    private var didCreateDirectories = false
    private var didLoad = false

    /// Captures shorter than this are the mic never having opened, or a
    /// pre-armed file that was never recorded into.
    private static let minimumDuration: TimeInterval = 0.3

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("WristMemo", isDirectory: true)
        capturesDirectory = root.appendingPathComponent("Captures", isDirectory: true)
        memosDirectory = root.appendingPathComponent("Memos", isDirectory: true)
        indexURL = root.appendingPathComponent("memos.json")
    }

    func url(for memo: Memo) -> URL {
        memosDirectory.appendingPathComponent(memo.filename)
    }

    /// A fresh path for the recorder to write into.
    func newCaptureURL(id: UUID) throws -> URL {
        try createDirectories()
        return capturesDirectory.appendingPathComponent("\(id.uuidString).caf")
    }

    /// Memoised — this sits on the record path and would otherwise re-issue two
    /// `mkdir` syscalls on every call.
    private func createDirectories() throws {
        guard !didCreateDirectories else { return }
        for directory in [capturesDirectory, memosDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        didCreateDirectories = true
    }

    // MARK: - Index

    /// Idempotent, and never on the recording hot path. `finalize` calls it too:
    /// saving before the index has loaded would persist an array containing only
    /// the new memo and orphan every earlier one.
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        do {
            try createDirectories()
        } catch {
            log.error("Couldn't create memo storage: \(error.localizedDescription, privacy: .public)")
            memos = []
            return
        }

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([Memo].self, from: data) {
            memos = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            memos = []
        }

        recoverUnindexedMemos()
    }

    /// Rebuilds index entries for a finished file that reached `Memos` just
    /// before a termination. The capture directory handles interrupted
    /// recordings; this closes the smaller window between promoting the final
    /// file and writing the index.
    private func recoverUnindexedMemos() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: memosDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        // A temporary output is never the committed memo. Its source capture is
        // still present, so it is safe to clear and retry on the next recovery.
        for temporary in urls where temporary.pathExtension == "partial" {
            try? fileManager.removeItem(at: temporary)
        }

        var knownIDs = Set(memos.map(\.id))
        let finished = urls
            .filter { ["m4a", "caf"].contains($0.pathExtension) }
            .sorted { lhs, rhs in
                // Prefer compressed AAC if a previous crash left both forms.
                lhs.pathExtension == "m4a" && rhs.pathExtension != "m4a"
            }

        var recovered: [Memo] = []
        for url in finished {
            guard
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                !knownIDs.contains(id)
            else { continue }

            let duration = AudioDuration.of(url)
            guard duration > Self.minimumDuration else { continue }
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            recovered.append(Memo(
                id: id,
                filename: url.lastPathComponent,
                createdAt: createdAt,
                duration: duration
            ))
            knownIDs.insert(id)
        }

        guard !recovered.isEmpty else { return }
        memos.append(contentsOf: recovered)
        memos.sort { $0.createdAt > $1.createdAt }
        persistIndex()
        log.notice("Recovered \(recovered.count) finished memo(s) missing from the index")
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
    func finalize(captureURL: URL, id: UUID, recordedAt: Date? = nil) async -> Memo? {
        loadIfNeeded()
        guard let attributes = try? fileManager.attributesOfItem(atPath: captureURL.path) else { return nil }
        let createdAt = recordedAt ?? (attributes[.creationDate] as? Date) ?? Date()

        // Cheap reject before spinning up an AAC encoder: a header-only capture
        // is a pre-arm that was never recorded into.
        let bytes = (attributes[.size] as? Int) ?? 0
        let minimumBytes = Int(RecordingEngine.captureSampleRate * 2 * Self.minimumDuration)
        guard bytes > minimumBytes else {
            try? fileManager.removeItem(at: captureURL)
            return nil
        }

        let destination = memosDirectory.appendingPathComponent("\(id.uuidString).m4a")
        let temporary = memosDirectory.appendingPathComponent("\(id.uuidString).m4a.partial")
        try? fileManager.removeItem(at: temporary)
        let compressedDuration: TimeInterval? = await Task.detached(priority: .userInitiated) {
            try? AudioCompressor.compress(source: captureURL, to: temporary)
        }.value

        var filename: String?
        var duration: TimeInterval?
        if let compressedDuration {
            do {
                // A move within this directory is atomic: startup sees either
                // the old temporary file or the complete final memo, never a
                // partially written `.m4a` under its permanent name.
                try fileManager.moveItem(at: temporary, to: destination)
                try? fileManager.removeItem(at: captureURL)
                filename = destination.lastPathComponent
                duration = compressedDuration
            } catch {
                log.error("Couldn't promote compressed memo; keeping raw capture: \(error.localizedDescription, privacy: .public)")
                try? fileManager.removeItem(at: temporary)
            }
        } else {
            try? fileManager.removeItem(at: temporary)
        }

        if filename == nil {
            log.error("Compression failed; keeping raw capture")
            let fallback = memosDirectory.appendingPathComponent("\(id.uuidString).caf")
            do {
                try fileManager.moveItem(at: captureURL, to: fallback)
                filename = fallback.lastPathComponent
                duration = AudioDuration.of(fallback)
            } catch {
                log.error("Couldn't file raw capture: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        guard let filename, let duration else { return nil }
        guard duration > Self.minimumDuration else {
            try? fileManager.removeItem(at: memosDirectory.appendingPathComponent(filename))
            return nil
        }

        let memo = Memo(id: id, filename: filename, createdAt: createdAt, duration: duration)
        // Newest first, matching how `loadIfNeeded` builds the array. Position 0
        // for a just-recorded memo, but a capture recovered from a crash carries
        // its original date and belongs wherever that date falls.
        let position = memos.firstIndex { $0.createdAt < memo.createdAt } ?? memos.endIndex
        memos.insert(memo, at: position)
        persistIndex()
        return memo
    }

    func discardCapture(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Crash recovery

    /// Rebuilds memos from captures left behind by a previous run.
    ///
    /// Runs after recording may already have started, so anything the engine
    /// currently owns has to be excluded — otherwise this transcodes and deletes
    /// the file being recorded into right now.
    @discardableResult
    func recoverOrphanedCaptures(excluding inFlight: Set<URL> = []) async -> [Memo] {
        loadIfNeeded()
        try? createDirectories()
        let claimed = Set(inFlight.map(\.standardizedFileURL))
        let orphans = (try? fileManager.contentsOfDirectory(at: capturesDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "caf" && !claimed.contains($0.standardizedFileURL) } ?? []

        var recoveredMemos: [Memo] = []
        for orphan in orphans {
            let id = UUID(uuidString: orphan.deletingPathExtension().lastPathComponent) ?? UUID()
            if let memo = memos.first(where: { $0.id == id }),
               fileManager.fileExists(atPath: url(for: memo).path) {
                // The final file was committed before a termination, but its
                // source capture remained. It has already been reconstructed
                // above, so keeping the capture would create a duplicate memo.
                try? fileManager.removeItem(at: orphan)
                continue
            }
            log.notice("Recovering orphaned capture \(orphan.lastPathComponent, privacy: .public)")
            if let memo = await finalize(captureURL: orphan, id: id) {
                recoveredMemos.append(memo)
            } else {
                try? fileManager.removeItem(at: orphan)
            }
        }
        return recoveredMemos
    }
}
