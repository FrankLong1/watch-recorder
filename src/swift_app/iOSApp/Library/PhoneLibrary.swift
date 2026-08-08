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
        /// When the ingest service acknowledged it, which is what the phone's
        /// retention window is measured from. Nil until then, and nil is what
        /// keeps a memo on the phone forever — see `Retention`.
        var uploadedAt: Date?

        /// Ingest accepts M4A, while a watch can safely retain a raw CAF when
        /// its local compressor fails. CAFs stay on the phone until they have
        /// been normalised; they are never uploaded under a false MIME type.
        var isReadyForIngest: Bool {
            url.pathExtension.lowercased() == "m4a"
        }
    }

    /// A durable, readable transcript. The UUID is the watch-generated
    /// identity, so a transcript and its temporary local audio can always be
    /// reunited without inventing a second identifier.
    struct Transcript: Codable, Identifiable, Equatable {
        let id: UUID
        let recordedAt: Date
        let duration: TimeInterval
        let text: String
        /// Kept losslessly for the server cursor; the phone never displays it.
        let transcribedAt: String
    }

    /// One chronological item for the iPhone review surface. A source audio
    /// file is optional because it is intentionally retained for only one day
    /// after verified transcription, while the transcript remains available.
    struct ReviewItem: Identifiable, Equatable {
        let id: UUID
        let recordedAt: Date
        let duration: TimeInterval
        let transcript: Transcript?
        let localMemo: Item?

        var uploadState: UploadState { localMemo?.uploadState ?? .uploaded }
        var hasSourceAudio: Bool { localMemo != nil }
    }

    /// What the watch sends alongside the audio, written next to each file so
    /// the phone never has to open an AAC file just to learn its duration.
    private struct Sidecar: Codable {
        let recordedAt: Date
        let duration: TimeInterval
        /// Optional so a sidecar written before uploads existed still decodes;
        /// a missing value means the memo has not been sent yet.
        var uploadState: UploadState?
        var uploadedAt: Date?
    }

    private struct TranscriptCursor: Codable, Equatable {
        let transcribedAt: String
        let id: UUID

        static let beginning = TranscriptCursor(
            transcribedAt: "1970-01-01T00:00:00.000000Z",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
    }

    private struct TranscriptCache: Codable {
        let cursor: TranscriptCursor
        let transcripts: [Transcript]
    }

    private(set) var items: [Item] = []
    private(set) var transcripts: [Transcript] = []
    private(set) var playingID: UUID?
    private(set) var isSynchronizingTranscripts = false
    /// True only after the currently signed-in Google account has separately
    /// received explicit permission to upload audio. Sign-in alone is read-only.
    private(set) var uploadsAreAuthorized = false

    private let log = SharedConfig.logger("PhoneLibrary")
    private var player: AVAudioPlayer?
    private let ingest = TranscriptionClient()
    private let transcriptHistory = TranscriptHistoryClient()
    private let uploadConsent = AudioUploadConsent()
    private weak var authentication: GoogleAuthentication?
    private var didStart = false
    private var transcriptCursor = TranscriptCursor.beginning

    private nonisolated static let importLog = SharedConfig.logger("PhoneImport")

    /// `nonisolated` because `session(_:didReceive:)` has to move the inbox file
    /// before it returns, and cannot hop to the main actor to look up a path.
    nonisolated static let memosDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Memos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Text is cached only inside this app's protected container so the review
    /// library remains useful offline. It is not part of the Watch hand-off or
    /// the audio transport path.
    private nonisolated static let transcriptCacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("TranscriptLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("transcripts.json")
    }()

    func start(
        authentication: GoogleAuthentication,
        onBackgroundEventsFinished: @escaping () -> Void
    ) {
        guard !didStart else { return }
        didStart = true
        self.authentication = authentication
        refreshUploadAuthorization()
        reload()
        loadTranscriptCache()
        recoverLegacyRawMemos()
        // Every launch is a chance to sweep, which matters because the app can
        // sit suspended for days between one upload finishing and the next.
        purgeUploaded()
        // Started before the session so anything left over from a previous run
        // is retried even if the watch never becomes reachable again.
        ingest.activate(
            library: self,
            authentication: authentication,
            onBackgroundEventsFinished: onBackgroundEventsFinished
        )
        transcriptHistory.activate(library: self, authentication: authentication)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        Task { [weak self] in
            guard let self else { return }
            await self.normalizePendingCaptures()
            self.ingest.uploadPending()
        }
    }

    func authenticationDidChange() {
        refreshUploadAuthorization()
        ingest.authenticationDidChange()
        transcriptHistory.authenticationDidChange()
    }

    /// Called only from the phone's counted confirmation dialog. The durable
    /// decision is tied to Google's immutable account ID, so signing into a
    /// different account can never release this backlog silently.
    func authorizeUploadsForCurrentAccount() {
        guard uploadConsent.grant(accountID: authentication?.accountIdentifier) else {
            log.error("Refusing upload authorization without a stable Google account")
            return
        }
        authenticationDidChange()
    }

    /// Signing out removes upload permission as well as the Google session.
    /// Existing background tasks are cancelled back to `pending`; audio stays
    /// on the phone and can be approved again later.
    func revokeUploadAuthorization() {
        uploadConsent.revoke()
        uploadsAreAuthorized = false
        ingest.cancelActiveUploads()
    }

    var pendingUploadCount: Int {
        items.count { $0.uploadState == .pending }
    }

    private func refreshUploadAuthorization() {
        uploadsAreAuthorized = uploadConsent.allows(
            accountID: authentication?.accountIdentifier
        )
    }

    /// Pull-to-refresh and transcript completion both use this. It fetches all
    /// pages after the durable cursor and is a no-op while signed out.
    func refreshTranscriptHistory() async {
        await transcriptHistory.refreshNow()
    }

    /// Called when an upload receives the exact ingest receipt. The watch and
    /// audio queues do not wait on this read; it only makes the new transcript
    /// appear as soon as the service has committed it.
    func transcriptHistoryMayHaveChanged() {
        transcriptHistory.refreshIfPossible()
    }

    var reviewItems: [ReviewItem] {
        let localByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var result = transcripts.map { transcript in
            ReviewItem(
                id: transcript.id,
                recordedAt: transcript.recordedAt,
                duration: transcript.duration,
                transcript: transcript,
                localMemo: localByID[transcript.id]
            )
        }
        let transcriptIDs = Set(transcripts.map(\.id))
        result.append(contentsOf: items.compactMap { item in
            guard !transcriptIDs.contains(item.id) else { return nil }
            return ReviewItem(
                id: item.id,
                recordedAt: item.recordedAt,
                duration: item.duration,
                transcript: nil,
                localMemo: item
            )
        })
        return result.sorted { $0.recordedAt > $1.recordedAt }
    }

    func reviewItems(matching query: String) -> [ReviewItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return reviewItems }
        return reviewItems.filter { item in
            item.transcript?.text.localizedCaseInsensitiveContains(trimmed) == true
        }
    }

    private func reload() {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: Self.memosDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        // If an interrupted normalisation left both files, the M4A is the
        // canonical, ingestible version. Invalid names stay on disk for manual
        // recovery but never receive a replacement UUID that would duplicate a
        // thought downstream.
        let audioURLs = urls
            .filter { ["m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.pathExtension.lowercased() == "m4a" && $1.pathExtension.lowercased() != "m4a" }

        var itemsByID: [UUID: Item] = [:]
        for url in audioURLs {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                log.error("Ignoring memo with invalid identity: \(url.lastPathComponent, privacy: .public)")
                continue
            }
            guard itemsByID[id] == nil else { continue }

            let sidecar = Self.readSidecar(for: url)
            let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            itemsByID[id] = Item(
                id: id,
                url: url,
                recordedAt: sidecar?.recordedAt ?? created ?? Date(),
                // Only decodes for a memo that arrived without metadata.
                duration: sidecar?.duration ?? AudioDuration.of(url),
                // `TranscriptionClient` reconciles persisted in-flight work
                // with URLSession's surviving background tasks before
                // requeueing it, so do not blindly duplicate it here.
                uploadState: sidecar?.uploadState ?? .pending,
                uploadedAt: sidecar?.uploadedAt
            )
        }
        items = itemsByID.values.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Older builds could mark a raw CAF as uploaded because they labelled it
    /// `audio/mp4`. Preserve it and return it to pending before retention gets a
    /// chance to delete the only usable source.
    private func recoverLegacyRawMemos() {
        for item in items where !item.isReadyForIngest && item.uploadState == .uploaded {
            setUploadState(.pending, for: item.id)
        }
    }

    /// Converts the watch's rare compression fallback after the audio has a
    /// durable home on the phone. Conversion is deliberately off the main actor
    /// and promotion is atomic, so playback/reload sees either the raw CAF or a
    /// complete M4A, never a partial output.
    private func normalizePendingCaptures() async {
        let captures = items.filter { !$0.isReadyForIngest && $0.uploadState != .uploaded }
        guard !captures.isEmpty else { return }

        let fileManager = FileManager.default
        for item in captures {
            let source = item.url
            let destination = source.deletingPathExtension().appendingPathExtension("m4a")
            let temporary = source.deletingPathExtension().appendingPathExtension("partial.m4a")

            if fileManager.fileExists(atPath: destination.path) {
                // A previous conversion reached the durable final file before a
                // termination. The raw source is redundant now.
                try? fileManager.removeItem(at: source)
                continue
            }

            try? fileManager.removeItem(at: temporary)
            let duration = await Task.detached(priority: .utility) {
                try? AudioCompressor.compress(source: source, to: temporary)
            }.value
            guard duration != nil else {
                try? fileManager.removeItem(at: temporary)
                log.error("Couldn't normalise raw memo \(item.id.uuidString, privacy: .public); retaining CAF")
                continue
            }

            do {
                try fileManager.moveItem(at: temporary, to: destination)
                try fileManager.removeItem(at: source)
            } catch {
                try? fileManager.removeItem(at: temporary)
                log.error("Couldn't promote normalised memo: \(error.localizedDescription, privacy: .public)")
            }
        }
        reload()
    }

    /// Records how far a memo has got, so an upload interrupted by the app being
    /// killed is picked up again on the next launch.
    func setUploadState(_ state: UploadState, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].uploadState = state
        // Stamped once, on the first acknowledgement, so re-sending a memo the
        // service already has cannot push its deletion out by another day.
        if state == .uploaded, items[index].uploadedAt == nil {
            items[index].uploadedAt = Date()
        }

        let item = items[index]
        let sidecar = Sidecar(
            recordedAt: item.recordedAt,
            duration: item.duration,
            uploadState: state,
            uploadedAt: item.uploadedAt
        )
        try? JSONEncoder().encode(sidecar)
            .write(to: Self.sidecarURL(for: item.url), options: .atomic)
    }

    // MARK: - Transcript history

    private func loadTranscriptCache() {
        guard let data = try? Data(contentsOf: Self.transcriptCacheURL) else { return }
        do {
            let cache = try JSONDecoder().decode(TranscriptCache.self, from: data)
            transcriptCursor = cache.cursor
            transcripts = cache.transcripts.sorted { $0.recordedAt > $1.recordedAt }
        } catch {
            log.error("Couldn't read transcript cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistTranscriptCache() {
        do {
            let cache = TranscriptCache(cursor: transcriptCursor, transcripts: transcripts)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.transcriptCacheURL, options: [.atomic, .completeFileProtection])
        } catch {
            // The server remains the durable source; a cache write failure must
            // never interfere with recording, upload, or future read retries.
            log.error("Couldn't save transcript cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    var nextTranscriptCursor: (transcribedAt: String, id: UUID) {
        (transcriptCursor.transcribedAt, transcriptCursor.id)
    }

    func mergeTranscripts(_ incoming: [Transcript]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: transcripts.map { ($0.id, $0) })
        for transcript in incoming {
            byID[transcript.id] = transcript
            advanceTranscriptCursor(with: transcript)
        }
        transcripts = byID.values.sorted { $0.recordedAt > $1.recordedAt }
        persistTranscriptCache()
    }

    func setTranscriptSyncing(_ value: Bool) {
        isSynchronizingTranscripts = value
    }

    private func advanceTranscriptCursor(with transcript: Transcript) {
        let current = transcriptCursor
        let isLater = transcript.transcribedAt > current.transcribedAt
            || (transcript.transcribedAt == current.transcribedAt
                && transcript.id.uuidString.localizedCaseInsensitiveCompare(current.id.uuidString) == .orderedDescending)
        if isLater {
            transcriptCursor = TranscriptCursor(transcribedAt: transcript.transcribedAt, id: transcript.id)
        }
    }

    /// The phone is the repair surface. Retrying here never touches audio; it
    /// only moves a terminal upload state back into the durable queue after a
    /// token, endpoint, or size issue has been corrected.
    func retryUpload(_ item: Item) {
        guard item.uploadState == .failed else { return }
        setUploadState(.pending, for: item.id)
        Task { [weak self] in
            guard let self else { return }
            await self.normalizePendingCaptures()
            self.ingest.uploadPending()
        }
    }

    // MARK: - Retention

    /// Deletes memos the ingest service has held for a day.
    ///
    /// The lasting record of a memo is its transcript in Postgres, not the
    /// audio; once the upload is acknowledged the phone is keeping a copy for
    /// convenience only, and a day is long enough to play one back or notice
    /// something went wrong. Anything unacknowledged is kept indefinitely —
    /// every memo made during a week with no network is still here when it ends.
    @discardableResult
    func purgeUploaded(now: Date = Date()) -> Int {
        // A memo uploaded by a build that predates `uploadedAt` has no stamp
        // and would never expire. Setting the state it already has stamps it,
        // so the first sweep that sees it starts its window rather than
        // granting it immortality.
        for item in items where item.uploadState == .uploaded && item.uploadedAt == nil {
            setUploadState(.uploaded, for: item.id)
        }

        let expired = items.filter {
            $0.uploadState == .uploaded && Retention.hasExpired(handedOnAt: $0.uploadedAt, now: now)
        }
        guard !expired.isEmpty else { return 0 }
        expired.forEach(remove)
        log.notice("Purged \(expired.count) memo(s) transcribed more than a day ago")
        return expired.count
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

    func play(_ item: ReviewItem) {
        guard let localMemo = item.localMemo else { return }
        play(localMemo)
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    private func remove(_ item: Item) {
        if playingID == item.id { stop() }
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: item.url))
        items.removeAll { $0.id == item.id }
    }

    private nonisolated static func importFile(_ file: WCSessionFile) -> UUID? {
        guard let metadata = MemoDelivery.decodeMetadata(file.metadata) else {
            importLog.error("Rejected watch transfer with malformed metadata")
            return nil
        }

        let fileExtension = file.fileURL.pathExtension.lowercased()
        guard ["m4a", "caf"].contains(fileExtension) else {
            importLog.error("Rejected watch transfer with unsupported format: \(fileExtension, privacy: .public)")
            return nil
        }

        let fileManager = FileManager.default
        let destination = memosDirectory
            .appendingPathComponent(metadata.id.uuidString)
            .appendingPathExtension(fileExtension)
        let compressedDestination = memosDirectory
            .appendingPathComponent(metadata.id.uuidString)
            .appendingPathExtension("m4a")
        // A staging name that does not end in an audio extension, so an import
        // interrupted halfway through cannot become a visible memo on reload.
        let staging = memosDirectory.appendingPathComponent(".\(metadata.id.uuidString).incoming")

        do {
            // A receipt may be delayed after the phone has already normalised a
            // CAF. The existing M4A is the same UUID's canonical copy; keeping
            // another raw file would create an unretained orphan.
            if fileExtension == "caf", fileManager.fileExists(atPath: compressedDestination.path) {
                try writeSidecar(metadata, preservingStateAt: compressedDestination)
                return metadata.id
            }

            try? fileManager.removeItem(at: staging)
            do {
                try fileManager.moveItem(at: file.fileURL, to: staging)
            } catch {
                try fileManager.copyItem(at: file.fileURL, to: staging)
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }

            if fileExtension == "m4a" {
                // A fresh compressed transfer supersedes an older raw fallback
                // with the same immutable identity.
                try? fileManager.removeItem(
                    at: destination.deletingPathExtension().appendingPathExtension("caf")
                )
            }

            try writeSidecar(metadata, preservingStateAt: destination)
            return metadata.id
        } catch {
            try? fileManager.removeItem(at: staging)
            importLog.error("Couldn't commit watch memo: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func writeSidecar(
        _ metadata: MemoDelivery.Metadata,
        preservingStateAt audio: URL
    ) throws {
        // Re-delivery of a UUID must not turn an acknowledged upload back into
        // pending work or extend the retention window.
        let existing = readSidecar(for: audio)
        let sidecar = Sidecar(
            recordedAt: metadata.recordedAt,
            duration: metadata.duration,
            uploadState: existing?.uploadState ?? .pending,
            uploadedAt: existing?.uploadedAt
        )
        let sidecarData = try JSONEncoder().encode(sidecar)
        try sidecarData.write(to: sidecarURL(for: audio), options: .atomic)
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
        // The inbox copy is deleted as soon as this returns, so commit it before
        // hopping to the main actor. Only a successful file-plus-sidecar commit
        // earns the status receipt that lets the watch start retention.
        guard let id = Self.importFile(file) else { return }
        session.transferUserInfo(MemoDelivery.phoneReceipt(for: id))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reload()
            self.recoverLegacyRawMemos()
            await self.normalizePendingCaptures()
            // The memo is already committed to disk; the upload is best-effort
            // on top of that, exactly as the watch treats its transfer.
            self.ingest.uploadPending()
        }
    }
}
