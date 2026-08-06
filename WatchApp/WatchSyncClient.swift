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
            }
        }
    }
}
