import Foundation
import WatchConnectivity

/// Ships finished memos to the paired iPhone.
///
/// `transferFile` is the right primitive: it is queued and persistent, so it
/// survives the watch app being killed and delivers whenever the phone next
/// becomes available. Nothing here blocks recording — a memo is safe on the
/// watch the moment it is saved, and sync is best-effort on top of that.
@MainActor
final class WatchSyncClient: NSObject {

    private let log = SharedConfig.logger("Sync")
    private weak var store: MemoStore?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 30

    private static let maximumRetryDelay: TimeInterval = 30 * 60

    func activate(store: MemoStore) {
        self.store = store
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ memo: Memo) {
        guard let store, let session, session.activationState == .activated else { return }
        let url = store.url(for: memo)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        store.setSyncState(.transferring, for: memo.id)
        // The phone reads these instead of re-deriving them from the audio.
        session.transferFile(url, metadata: [
            "id": memo.id.uuidString,
            "createdAt": memo.createdAt.timeIntervalSince1970,
            "duration": memo.duration
        ])
        log.info("Queued \(memo.filename, privacy: .public)")
    }

    /// Re-queues anything that never made it, when the session activates or the
    /// phone comes back within range.
    func sendPending() {
        guard let store, session?.outstandingFileTransfers.isEmpty ?? false else { return }
        for memo in store.memos where memo.syncState != .synced {
            send(memo)
        }
    }

    /// A failed transfer does not necessarily change reachability or activation
    /// state, so those delegate callbacks alone cannot guarantee a retry. Back
    /// off to avoid re-queuing in a tight loop when the phone is unavailable.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.sendPending()
        }
    }
}

extension WatchSyncClient: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor [weak self] in self?.sendPending() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in self?.sendPending() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let idString = fileTransfer.file.metadata?["id"] as? String
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self, let idString, let id = UUID(uuidString: idString) else { return }
            self.store?.setSyncState(failed ? .pending : .synced, for: id)
            if failed {
                self.log.error("Transfer failed: \(error?.localizedDescription ?? "?", privacy: .public)")
                self.scheduleRetry()
            } else {
                self.retryDelay = 30
                // This may be the last outstanding transfer that was keeping
                // an earlier failed memo from being re-queued.
                self.sendPending()
            }
        }
    }
}
