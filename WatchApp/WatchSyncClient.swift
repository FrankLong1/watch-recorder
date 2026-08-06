import Foundation
import WatchConnectivity
import os

/// Ships finished memos to the paired iPhone.
///
/// `transferFile` is the right primitive: it is queued and persistent, so it
/// survives the watch app being killed and delivers whenever the phone next
/// becomes available. Nothing here blocks recording — a memo is safe on the
/// watch the moment it is saved, and sync is best-effort on top of that.
@MainActor
@Observable
final class WatchSyncClient: NSObject {

    private let log = Logger(subsystem: "com.wristmemo.app", category: "Sync")
    private weak var store: MemoStore?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    private(set) var isReachable = false

    func activate(store: MemoStore) {
        self.store = store
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Queues a memo, tolerating a missing or inactive session.
    func send(_ memo: Memo) {
        guard let store, let session, session.activationState == .activated else { return }
        let url = store.url(for: memo)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        store.setSyncState(.transferring, for: memo.id)
        session.transferFile(url, metadata: [
            "id": memo.id.uuidString,
            "createdAt": memo.createdAt.timeIntervalSince1970,
            "duration": memo.duration
        ])
        log.info("Queued \(memo.filename, privacy: .public)")
    }

    /// Re-queues anything that never made it, called when the session activates
    /// or the phone comes back within range.
    func sendPending() {
        guard let store else { return }
        let outstanding = session?.outstandingFileTransfers.count ?? 0
        guard outstanding == 0 else { return }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = session.isReachable
            if activationState == .activated { self.sendPending() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = session.isReachable
            if session.isReachable { self.sendPending() }
        }
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
