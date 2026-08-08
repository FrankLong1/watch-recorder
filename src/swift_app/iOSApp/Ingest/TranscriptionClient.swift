import Foundation
import UIKit

/// Ships memo audio to the WristMemo ingest service for transcription.
///
/// This is the third hop of a memo's life, and it works like the second one:
/// the file is already safe on the phone before any upload is attempted, state
/// is recorded per memo, and anything unfinished is re-queued later. Nothing
/// here can lose a memo — the audio is never moved or deleted.
///
/// The upload response is deliberately status-only, which keeps the durable
/// retry state machine independent of text rendering. A separate authenticated
/// history client reads transcripts later for the phone review surface. See
/// 1_INGEST_ARCHITECTURE.md.
@MainActor
final class TranscriptionClient: NSObject {

    private let log = SharedConfig.logger("Ingest")
    private weak var library: PhoneLibrary?
    private weak var authentication: GoogleAuthentication?
    private var authorizationTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 30
    private var didActivate = false
    private var backgroundEventsFinished: (() -> Void)?

    private static let maximumRetryDelay: TimeInterval = 30 * 60

    /// A background session survives the app being suspended, which matters
    /// because WatchConnectivity delivers files by launching the app in the
    /// background. A default session would start an upload and lose it.
    static let sessionIdentifier = "\(SharedConfig.identifierPrefix).ingest"

    /// Created once. Constructing two background sessions with the same
    /// identifier traps.
    private lazy var session: URLSession = {
        let configuration: URLSessionConfiguration

        #if targetEnvironment(simulator)
        // The simulator has no background transfer daemon, so every upload on a
        // background session fails with NSURLErrorUnknown before it leaves the
        // machine. A default session lets the simulator exercise the request,
        // the auth, the retry policy and the state machine.
        //
        // It deliberately does NOT prove the thing that matters most on device —
        // that an upload survives the app being suspended. Only hardware can
        // show that.
        configuration = .default
        #else
        configuration = .background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        #endif

        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func activate(
        library: PhoneLibrary,
        authentication: GoogleAuthentication,
        onBackgroundEventsFinished: @escaping () -> Void
    ) {
        self.library = library
        self.authentication = authentication
        backgroundEventsFinished = onBackgroundEventsFinished
        // Touch the session so it reclaims any transfer that completed while the
        // app was not running.
        _ = session
        if !didActivate {
            didActivate = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }
        recoverBackgroundTasks()
    }

    func authenticationDidChange() {
        guard authentication?.isSignedIn == true,
              library?.uploadsAreAuthorized == true
        else { return }
        recoverBackgroundTasks()
    }

    /// Revoking consent must stop work that was already scheduled, not merely
    /// prevent the next queue scan. URLSession reports each cancellation
    /// through the normal completion path, which returns its memo to `pending`.
    func cancelActiveUploads() {
        authorizationTask?.cancel()
        authorizationTask = nil
        retryTask?.cancel()
        retryTask = nil
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    @objc private nonisolated func applicationDidBecomeActive() {
        Task { @MainActor [weak self] in
            // Sweeping before uploading keeps the two in a sane order: nothing
            // is queued for a memo that is about to be deleted anyway.
            self?.library?.purgeUploaded()
            self?.recoverBackgroundTasks()
        }
    }

    /// Re-queues anything that never landed. Safe to call repeatedly: the server
    /// keys on the memo's id, so a memo that already arrived is answered without
    /// being transcribed again.
    func uploadPending() {
        guard authorizationTask == nil,
              let library,
              let authentication,
              library.uploadsAreAuthorized,
              authentication.isSignedIn,
              let configuration = IngestConfiguration.current
        else { return }
        let pending = library.items.filter { $0.uploadState == .pending }
        guard !pending.isEmpty else { return }

        authorizationTask = Task { [weak self] in
            defer { self?.authorizationTask = nil }
            do {
                let idToken = try await authentication.idToken()
                for item in pending where library.items.contains(where: { $0.id == item.id && $0.uploadState == .pending }) {
                    guard !Task.isCancelled, library.uploadsAreAuthorized else { return }
                    self?.upload(item, baseURL: configuration.baseURL, idToken: idToken)
                }
            } catch {
                self?.log.info("Google authorization unavailable; memos remain pending")
                self?.scheduleRetry()
            }
        }
    }

    /// Background URLSession tasks survive a process launch. Keep the ones the
    /// system still owns, and requeue only persisted uploads that have no task
    /// left to finish them.
    private func recoverBackgroundTasks() {
        session.getAllTasks { [weak self] tasks in
            let activeIDs = Set(tasks.compactMap(Self.memoID(for:)))
            Task { @MainActor [weak self] in
                guard let self, let library = self.library else { return }
                for item in library.items where item.uploadState == .uploading && !activeIDs.contains(item.id) {
                    library.setUploadState(.pending, for: item.id)
                }
                self.uploadPending()
            }
        }
    }

    private func upload(_ item: PhoneLibrary.Item, baseURL: URL, idToken: String) {
        guard let library, library.uploadsAreAuthorized else { return }
        // OpenAI accepts M4A, not the raw CAF capture format. The phone
        // normalises CAFs before they reach this client; never lie about one.
        guard item.isReadyForIngest else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return }

        guard let endpoint = URL(string: "v1/memos/\(item.id.uuidString.lowercased())", relativeTo: baseURL) else {
            log.error("Could not build an ingest URL")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("m4a", forHTTPHeaderField: "X-Audio-Format")
        // The server stores these rather than re-deriving them from the audio,
        // exactly as the phone does with the watch's transfer metadata.
        request.setValue(String(item.recordedAt.timeIntervalSince1970), forHTTPHeaderField: "X-Recorded-At")
        request.setValue(String(item.duration), forHTTPHeaderField: "X-Duration")

        library.setUploadState(.uploading, for: item.id)

        // A background session can only upload from a file, which is why the
        // endpoint takes a raw body: this points straight at the stored memo and
        // copies nothing.
        let task = session.uploadTask(with: request, fromFile: item.url)
        // The only way to recover which memo a background task belonged to when
        // the delegate fires in a relaunched process.
        task.taskDescription = item.id.uuidString
        task.resume()

        log.info("Uploading \(item.id.uuidString, privacy: .public)")
    }

    /// A failed upload does not change any observable system state, so nothing
    /// else would ever retry it. Back off rather than spinning.
    private func scheduleRetry() {
        guard retryTask == nil,
              library?.uploadsAreAuthorized == true,
              authentication?.isSignedIn == true
        else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.uploadPending()
        }
    }

    private func finish(id: UUID, status: Int?, error: Error?) {
        guard let library else { return }

        if let error {
            log.error("Upload failed: \(error.localizedDescription, privacy: .public)")
            library.setUploadState(.pending, for: id)
            scheduleRetry()
            return
        }

        if MemoDelivery.isIngestReceipt(status: status) {
            retryDelay = 30
            library.setUploadState(.uploaded, for: id)
            library.transcriptHistoryMayHaveChanged()
            log.info("Transcribed \(id.uuidString, privacy: .public)")
            // This memo has a day left, but an upload finishing may be the only
            // thing that wakes the app all day, so sweep the older ones now.
            library.purgeUploaded()
            return
        }

        switch status {
        case .some(let code) where (200..<300).contains(code):
            // A success-shaped response that is not the receipt is unsafe. The
            // usual example is a captive portal serving HTML with a 200.
            library.setUploadState(.pending, for: id)
            log.error("Upload returned unexpected success \(code, privacy: .public); will retry")
            scheduleRetry()
        case 401:
            // Google ID tokens are intentionally short-lived. A background task
            // can start after the token used to schedule it expires; requeue so
            // the next attempt silently refreshes instead of stranding audio.
            library.setUploadState(.pending, for: id)
            log.info("Google authorization expired; will refresh and retry")
            scheduleRetry()
        case .some(let code) where (400..<500).contains(code):
            // The request itself is wrong — a bad token, an oversized memo, a
            // malformed header. Retrying sends exactly the same bytes.
            library.setUploadState(.failed, for: id)
            log.error("Upload rejected with \(code, privacy: .public); not retrying")
        case .some(let code):
            library.setUploadState(.pending, for: id)
            log.error("Upload got \(code, privacy: .public); will retry")
            scheduleRetry()
        case nil:
            library.setUploadState(.pending, for: id)
            scheduleRetry()
        }
    }
}

/// Pulls the memo owner's transcript history after audio has reached the
/// service. It deliberately uses a regular foreground session: capture and
/// audio delivery must survive suspension, whereas reading text is a review
/// operation and must never compete with the recording hot path.
@MainActor
final class TranscriptHistoryClient {

    private struct Response: Decodable {
        let memos: [Memo]
    }

    private struct Memo: Decodable {
        let id: UUID
        let recordedAt: TimeInterval
        let durationSeconds: TimeInterval
        let transcript: String
        let transcribedAt: String

        var libraryTranscript: PhoneLibrary.Transcript {
            PhoneLibrary.Transcript(
                id: id,
                recordedAt: Date(timeIntervalSince1970: recordedAt),
                duration: durationSeconds,
                text: transcript,
                transcribedAt: transcribedAt
            )
        }
    }

    private static let pageSize = 100

    private weak var library: PhoneLibrary?
    private weak var authentication: GoogleAuthentication?
    private let log = SharedConfig.logger("TranscriptHistory")
    private var syncTask: Task<Void, Never>?

    func activate(library: PhoneLibrary, authentication: GoogleAuthentication) {
        self.library = library
        self.authentication = authentication
    }

    func authenticationDidChange() {
        refreshIfPossible()
    }

    func refreshIfPossible() {
        guard authentication?.isSignedIn == true else { return }
        startRefreshIfNeeded()
    }

    func refreshNow() async {
        refreshIfPossible()
        await syncTask?.value
    }

    private func startRefreshIfNeeded() {
        guard syncTask == nil,
              let library,
              let authentication,
              let configuration = IngestConfiguration.current
        else { return }

        library.setTranscriptSyncing(true)
        syncTask = Task { [weak self, weak library, weak authentication] in
            defer {
                self?.syncTask = nil
                library?.setTranscriptSyncing(false)
            }
            guard let self, let library, let authentication else { return }
            do {
                let idToken = try await authentication.idToken()
                try await self.fetchAllNewTranscripts(
                    into: library,
                    baseURL: configuration.baseURL,
                    idToken: idToken
                )
            } catch {
                // The existing cache remains readable and the next activation
                // or pull-to-refresh retries. Never surface server details.
                self.log.info("Transcript history refresh deferred")
            }
        }
    }

    private func fetchAllNewTranscripts(
        into library: PhoneLibrary,
        baseURL: URL,
        idToken: String
    ) async throws {
        while true {
            let cursor = library.nextTranscriptCursor
            guard var components = URLComponents(
                url: URL(string: "v1/memos", relativeTo: baseURL)!,
                resolvingAgainstBaseURL: true
            ) else { return }
            components.queryItems = [
                URLQueryItem(name: "after", value: cursor.transcribedAt),
                URLQueryItem(name: "after_id", value: cursor.id.uuidString.lowercased()),
                URLQueryItem(name: "limit", value: String(Self.pageSize))
            ]
            guard let url = components.url else { return }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode(Response.self, from: data)
            library.mergeTranscripts(page.memos.map(\.libraryTranscript))
            guard page.memos.count == Self.pageSize else { return }
        }
    }
}

extension TranscriptionClient: URLSessionDataDelegate {

    private nonisolated static func memoID(for task: URLSessionTask) -> UUID? {
        if let description = task.taskDescription, let id = UUID(uuidString: description) {
            return id
        }
        // Written out rather than chained: `?.lastPathComponent.flatMap` binds
        // flatMap to the unwrapped String, which is a Sequence, not Optional.
        guard let lastPathComponent = task.originalRequest?.url?.lastPathComponent else { return nil }
        return UUID(uuidString: lastPathComponent)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let id = Self.memoID(for: task)
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor [weak self] in
            guard let id else { return }
            self?.finish(id: id, status: status, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in self?.backgroundEventsFinished?() }
    }

    /// The response body is deliberately ignored — the transcript never comes
    /// back to the phone. Implemented only so the body is drained.
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {}
}

/// The ingest URL is public configuration. Authentication comes from a fresh
/// Google ID token and is never persisted by WristMemo.
///
/// The environment override keeps the simulator integration harness useful;
/// signed device builds compile the URL from ignored local configuration.
enum IngestConfiguration {

    struct Configuration {
        let baseURL: URL
    }

    private static let urlKey = "WRISTMEMO_INGEST_URL"

    static var current: Configuration? {
        let environment = ProcessInfo.processInfo.environment
        let environmentURL = environment[urlKey]?.trimmed.nilIfEmpty
        let bundledURL = (Bundle.main.object(forInfoDictionaryKey: "WristMemoIngestURL") as? String)?
            .trimmed.nilIfEmpty
        guard let urlString = environmentURL ?? bundledURL,
              // A relative URL needs the trailing slash or the last path
              // component is replaced rather than appended.
              let baseURL = URL(string: urlString.hasSuffix("/") ? urlString : urlString + "/"),
              baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil
        else { return nil }

        return Configuration(baseURL: baseURL)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
