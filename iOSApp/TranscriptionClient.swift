import Foundation
import Security
import UIKit

/// Ships memo audio to the WristMemo ingest service for transcription.
///
/// This is the third hop of a memo's life, and it works like the second one:
/// the file is already safe on the phone before any upload is attempted, state
/// is recorded per memo, and anything unfinished is re-queued later. Nothing
/// here can lose a memo — the audio is never moved or deleted.
///
/// It is a one-way door. The transcript is not returned; the response carries
/// only a status code, which is what drives the retry state machine. Transcripts
/// are read from the database, not from the phone. See 1_INGEST_ARCHITECTURE.md.
@MainActor
final class TranscriptionClient: NSObject {

    private let log = SharedConfig.logger("Ingest")
    private weak var library: PhoneLibrary?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 30
    private var didActivate = false
    private var backgroundEventsFinished: (() -> Void)?
    private var backgroundEventsContinuation: CheckedContinuation<Void, Never>?
    private var isBackgroundWaitCancelled = false

    private static let maximumRetryDelay: TimeInterval = 30 * 60

    /// A background session survives the app being suspended, which matters
    /// because WatchConnectivity delivers files by launching the app in the
    /// background. A default session would start an upload and lose it.
    static let sessionIdentifier = "com.franklong.wristmemo.ingest"

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

    func activate(library: PhoneLibrary, onBackgroundEventsFinished: @escaping () -> Void) {
        self.library = library
        backgroundEventsFinished = onBackgroundEventsFinished
        guard IngestCredentials.current != nil else {
            log.info("Ingest not configured; uploads are disabled")
            return
        }
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

    @objc private nonisolated func applicationDidBecomeActive() {
        Task { @MainActor [weak self] in self?.uploadPending() }
    }

    /// Suspends until the session says it has delivered every event the app was
    /// relaunched to receive.
    ///
    /// The `.backgroundTask` handler must not return before that: the app is
    /// suspended again the moment it does, and any completion still queued
    /// would be lost — which is the whole reason the system started the process.
    func waitForBackgroundEvents() async {
        // Touching the session is what matters here. On a background relaunch
        // nothing has built it yet, and building it is what reattaches the
        // delegate the queued events are waiting to be delivered to.
        _ = session
        // A cancellation recorded by an earlier wait must not end this one.
        isBackgroundWaitCancelled = false
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before it could park. Parking now would leave a
                // continuation nothing resumes, and the handler would hang
                // until the system killed the app for it.
                guard !isBackgroundWaitCancelled else {
                    continuation.resume()
                    return
                }
                backgroundEventsContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endBackgroundWait(cancelled: true) }
        }
    }

    /// The only place the continuation is handed back, because resuming one
    /// twice traps. Clears the slot as it resumes.
    private func endBackgroundWait(cancelled: Bool = false) {
        guard let continuation = backgroundEventsContinuation else {
            if cancelled { isBackgroundWaitCancelled = true }
            return
        }
        backgroundEventsContinuation = nil
        continuation.resume()
    }

    /// Re-queues anything that never landed. Safe to call repeatedly: the server
    /// keys on the memo's id, so a memo that already arrived is answered without
    /// being transcribed again.
    func uploadPending() {
        guard let library else { return }
        for item in library.items where item.uploadState == .pending {
            upload(item)
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

    private func upload(_ item: PhoneLibrary.Item) {
        guard let library, let credentials = IngestCredentials.current else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return }

        guard let endpoint = URL(string: "v1/memos/\(item.id.uuidString.lowercased())", relativeTo: credentials.baseURL) else {
            log.error("Could not build an ingest URL")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(for: item.url), forHTTPHeaderField: "Content-Type")
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

    /// Declares what the bytes actually are.
    ///
    /// Nearly every memo is AAC, but a capture the watch could not compress is
    /// transferred as raw PCM in a CAF container rather than being lost.
    /// `PhoneLibrary` converts those on arrival; one that will not convert is
    /// still uploaded, and labelling it `audio/mp4` would have the server hand
    /// the transcription service a file it silently mis-decodes. Told the
    /// truth, the server can refuse it and the memo reaches a visible failure.
    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        default: return "audio/mp4"
        }
    }

    /// A failed upload does not change any observable system state, so nothing
    /// else would ever retry it. Back off rather than spinning.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
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

        switch status {
        // 204 today. Any 2xx is treated as committed so a later contract change
        // cannot silently turn success into an infinite retry.
        case .some(let code) where (200..<300).contains(code):
            retryDelay = 30
            library.setUploadState(.uploaded, for: id)
            log.info("Transcribed \(id.uuidString, privacy: .public)")
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Both halves of "the app may now go back to sleep": the UIKit
            // completion handler, and the `.backgroundTask` that is parked.
            self.backgroundEventsFinished?()
            self.endBackgroundWait()
        }
    }

    /// The response body is deliberately ignored — the transcript never comes
    /// back to the phone. Implemented only so the body is drained.
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {}
}

/// Where the phone gets its endpoint and bearer token.
///
/// The token is bootstrapped from the environment — set it once in the Xcode
/// scheme — and then persisted to the Keychain so later launches on device work
/// without Xcode. It is deliberately not compiled in.
///
/// A leaked ingest token lets someone transcribe on your bill: revocable and
/// rate-limitable. The OpenAI key it stands in front of never leaves Cloud Run.
enum IngestCredentials {

    struct Credentials {
        let baseURL: URL
        let token: String
    }

    private static let service = "com.franklong.wristmemo.ingest"
    private static let urlKey = "WRISTMEMO_INGEST_URL"
    private static let tokenKey = "WRISTMEMO_INGEST_TOKEN"

    static var current: Credentials? {
        let environment = ProcessInfo.processInfo.environment
        let environmentURL = environment[urlKey]?.trimmed.nilIfEmpty
        let environmentToken = environment[tokenKey]?.trimmed.nilIfEmpty

        // Persistence is best-effort and must not gate the values. An unsigned
        // simulator build has no keychain entitlement, so this write fails —
        // and reading back through the keychain would then discard credentials
        // the environment had supplied perfectly well.
        if let environmentURL { keychainSet(urlKey, environmentURL) }
        if let environmentToken { keychainSet(tokenKey, environmentToken) }

        // Environment wins when present; the keychain is the fallback that makes
        // later launches work without it.
        guard let urlString = environmentURL ?? keychainGet(urlKey),
              let token = environmentToken ?? keychainGet(tokenKey),
              // A relative URL needs the trailing slash or the last path
              // component is replaced rather than appended.
              let baseURL = URL(string: urlString.hasSuffix("/") ? urlString : urlString + "/"),
              baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil
        else { return nil }

        return Credentials(baseURL: baseURL, token: token)
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychainGet(_ account: String) -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func keychainSet(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let attributes = query(account)

        let updated = SecItemUpdate(
            attributes as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updated != errSecSuccess else { return }

        var insert = attributes
        insert[kSecValueData as String] = data
        // The upload runs in the background, so the item has to be readable
        // while the device is locked.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
