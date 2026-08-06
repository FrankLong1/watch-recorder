import AVFoundation
import Foundation
import WatchConnectivity

/// Receives memos from the watch and plays them back.
@MainActor
@Observable
final class PhoneLibrary: NSObject {

    /// Where a memo has got to on its third and last hop, to the ingest
    /// service. Mirrors `Memo.SyncState` on the watch, one link further along.
    enum UploadState: String, Codable, Sendable {
        case pending, uploading, uploaded, failed
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let recordedAt: Date
        let duration: TimeInterval
        var uploadState: UploadState = .pending
    }

    /// What the watch sends alongside the audio, written next to each file so
    /// the phone never has to open an AAC file just to learn its duration.
    private struct Sidecar: Codable {
        let recordedAt: Date
        let duration: TimeInterval
        /// Optional so a sidecar written before uploads existed still decodes;
        /// a missing value means the memo has not been sent yet.
        var uploadState: UploadState?
    }

    /// One instance per process. A background relaunch has to reach the same
    /// library the window would have built, and two of them would mean two
    /// `WCSession` delegates and two views of the same files on disk.
    static let shared = PhoneLibrary()

    private(set) var items: [Item] = []
    private(set) var playingID: UUID?

    private let log = SharedConfig.logger("PhoneLibrary")
    private var player: AVAudioPlayer?
    private let ingest = TranscriptionClient()
    private var didStart = false

    /// `nonisolated` because `session(_:didReceive:)` has to move the inbox file
    /// before it returns, and cannot hop to the main actor to look up a path.
    nonisolated static let memosDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Memos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Idempotent: the window's `.task` and a background relaunch both call it,
    /// and on a relaunch that is later foregrounded, both happen in one process.
    func start(onBackgroundEventsFinished: @escaping () -> Void) {
        guard !didStart else { return }
        didStart = true
        // Before the session is activated, so this cannot delete a file an
        // import is in the middle of staging.
        purgeStagedImports()
        reload()
        // Anything an earlier run left as a raw capture, including a memo a
        // previous upload attempt was refused for being one.
        Task { [weak self] in await self?.compressFallbackMemos() }
        // Started before the session so anything left over from a previous run
        // is retried even if the watch never becomes reachable again.
        ingest.activate(library: self, onBackgroundEventsFinished: onBackgroundEventsFinished)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// iOS relaunches the app in the background when a queued upload finishes.
    /// The window is never built in that launch, so the `.task` that calls
    /// `start` never runs — and without it the background session is rebuilt
    /// with no delegate, and the completion is delivered nowhere.
    ///
    /// Takes the delegate rather than its method so the reference is formed
    /// here, on the main actor, instead of in the `@Sendable` scene closure.
    func handleBackgroundSessionEvents(finishing delegate: WristMemoAppDelegate) async {
        start(onBackgroundEventsFinished: delegate.finishBackgroundSessionEvents)
        await ingest.waitForBackgroundEvents()
    }

    /// Replaces a raw-PCM fallback memo with the AAC the watch would have sent.
    ///
    /// When compression fails on the watch it keeps the capture rather than
    /// losing it, and transfers that instead — but nothing downstream reads a
    /// raw-PCM CAF, so a rescued memo would arrive at the transcription service
    /// as a file it cannot decode. The phone has the power budget the watch was
    /// short of, so it is the right place to finish the job.
    ///
    /// Best-effort, and never destructive: a memo that will not convert is left
    /// exactly as it is, still playable, and is uploaded under its true type.
    func compressFallbackMemos() async {
        var converted: [UUID] = []
        // `.uploading` is skipped so a conversion never deletes a file a
        // background task is still reading from.
        for item in items where item.url.pathExtension == "caf" && item.uploadState != .uploading {
            if await compress(item) { converted.append(item.id) }
        }
        guard !converted.isEmpty else { return }

        reload()
        // The converted file is a different upload from the one that may
        // already have been rejected, so it starts again from the beginning.
        for id in converted { setUploadState(.pending, for: id) }
        ingest.uploadPending()
    }

    private func compress(_ item: PhoneLibrary.Item) async -> Bool {
        let destination = item.url.deletingPathExtension().appendingPathExtension("m4a")
        // Same trailing extension rule as the watch: AVAudioFile picks its
        // container from the extension, so the temporary name has to end in
        // the one it is being written as.
        let temporary = item.url.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: temporary)

        let compressed = await Task.detached(priority: .utility) {
            try? AudioCompressor.compress(source: item.url, to: temporary)
        }.value
        guard compressed != nil else {
            try? FileManager.default.removeItem(at: temporary)
            log.error("Could not convert \(item.id.uuidString, privacy: .public) from raw capture")
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }

        // Only once the replacement is committed. The sidecar needs no move:
        // both names share a stem, so it already describes the new file.
        try? FileManager.default.removeItem(at: item.url)
        log.info("Converted \(item.id.uuidString, privacy: .public) to AAC")
        return true
    }

    /// Clears what a crash left half-finished: a staged import, or a conversion
    /// that never got as far as replacing its source. Neither is ever the
    /// committed file, and both have a source that is still on disk.
    ///
    /// Safe only before the session is activated and before any conversion
    /// starts — the one moment nothing can be mid-write.
    private func purgeStagedImports() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.memosDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls
        where url.pathExtension == "part" || url.lastPathComponent.hasSuffix(".partial.m4a") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func reload() {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: Self.memosDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        items = urls
            .filter { ["m4a", "caf"].contains($0.pathExtension) }
            // A conversion in progress is not a memo. Its name still ends in
            // `.m4a` because AVAudioFile chooses its container from that.
            .filter { !$0.lastPathComponent.hasSuffix(".partial.m4a") }
            .map { url in
                let sidecar = Self.readSidecar(for: url)
                let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                return Item(
                    id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
                    url: url,
                    recordedAt: sidecar?.recordedAt ?? created ?? Date(),
                    // Only decodes for a memo that arrived without metadata.
                    duration: sidecar?.duration ?? AudioDuration.of(url),
                    // `TranscriptionClient` reconciles persisted in-flight
                    // work with URLSession's surviving background tasks before
                    // requeueing it, so do not blindly duplicate it here.
                    uploadState: sidecar?.uploadState ?? .pending
                )
            }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Records how far a memo has got, so an upload interrupted by the app being
    /// killed is picked up again on the next launch.
    func setUploadState(_ state: UploadState, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].uploadState = state

        let item = items[index]
        let sidecar = Sidecar(
            recordedAt: item.recordedAt,
            duration: item.duration,
            uploadState: state
        )
        try? JSONEncoder().encode(sidecar)
            .write(to: Self.sidecarURL(for: item.url), options: .atomic)
    }

    private nonisolated static func sidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("json")
    }

    private nonisolated static func readSidecar(for audio: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(for: audio)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    // MARK: - Playback

    func play(_ item: Item) {
        if playingID == item.id {
            stop()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: item.url)
            player.delegate = self
            player.play()
            self.player = player
            playingID = item.id
        } catch {
            log.error("Playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func delete(_ item: Item) {
        if playingID == item.id { stop() }
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: item.url))
        items.removeAll { $0.id == item.id }
    }
}

extension PhoneLibrary: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}

extension PhoneLibrary: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS so the session can re-pair with a new watch.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The inbox copy is deleted as soon as this returns, so import it now
        // rather than on a hop to the main actor.
        let metadata = file.metadata
        let name = (metadata?["id"] as? String) ?? UUID().uuidString
        let destination = Self.memosDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(file.fileURL.pathExtension)

        do {
            try Self.importReceived(file.fileURL, to: destination, metadata: metadata)
        } catch {
            // Nothing was removed, so whatever was already at `destination`
            // is still there and still playable. The watch marks the memo
            // synced the moment this callback returns either way, so a log
            // line is the only signal left that the copy did not land.
            Task { @MainActor [weak self] in
                self?.log.error("Could not import received memo: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reload()
            // A capture the watch could not compress is finished here first,
            // so what goes upstream is something that can be transcribed.
            await self.compressFallbackMemos()
            // The memo is already committed to disk; the upload is best-effort
            // on top of that, exactly as the watch treats its transfer.
            self.ingest.uploadPending()
        }
    }

    /// Files an inbox copy without ever leaving the destination missing.
    ///
    /// Removing the old memo first and *then* importing is the one ordering
    /// that can lose audio: the inbox file is deleted when the callback
    /// returns, so a failure between the two — a full disk, a transient I/O
    /// error — destroys the only remaining copy. Staging under a name nothing
    /// reads and swapping it in at the end means a failure costs the new memo
    /// at worst, never the one already on the phone.
    private nonisolated static func importReceived(
        _ inbox: URL,
        to destination: URL,
        metadata: [String: Any]?
    ) throws {
        let fileManager = FileManager.default
        // `.part` deliberately does not match the extensions `reload` lists, so
        // a staged file is never mistaken for a memo while it is being written.
        let staged = memosDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString)")
            .appendingPathExtension("part")

        do {
            // Same volume, so this is a rename. The copy is the fallback for
            // the case where the inbox is not.
            try fileManager.moveItem(at: inbox, to: staged)
        } catch {
            try fileManager.copyItem(at: inbox, to: staged)
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                // Within a directory this is an atomic rename: the destination
                // is either absent or the complete file, never a partial one.
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }

        guard let recordedAt = metadata?["createdAt"] as? TimeInterval,
              let duration = metadata?["duration"] as? TimeInterval
        else { return }

        // Written after the audio, and best-effort: a memo whose sidecar is
        // missing still plays, and `reload` falls back to the file's own
        // creation date and a decoded duration. Writing it first would instead
        // leave a retained older memo describing itself with this memo's
        // metadata if the swap above failed.
        let sidecar = Sidecar(
            recordedAt: Date(timeIntervalSince1970: recordedAt),
            duration: duration,
            uploadState: .pending
        )
        try? JSONEncoder().encode(sidecar).write(to: sidecarURL(for: destination), options: .atomic)
    }
}
