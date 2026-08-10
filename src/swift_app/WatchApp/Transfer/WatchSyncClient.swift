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
    private var receiptRetryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 30

    private static let maximumRetryDelay: TimeInterval = 30 * 60
    private static let receiptRetryDelay: TimeInterval = 5 * 60

    func activate(store: MemoStore) {
        self.store = store
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ memo: Memo) {
        guard memo.syncState != .synced else { return }
        guard let store, let session, session.activationState == .activated else { return }
        let url = store.url(for: memo)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        store.setSyncState(.transferring, for: memo.id)
        session.transferFile(
            url,
            metadata: MemoDelivery.metadata(
                id: memo.id,
                recordedAt: memo.createdAt,
                duration: memo.duration
            )
        )
        log.info("Queued \(memo.filename, privacy: .public)")
    }

    /// Re-queues anything that never made it, when the session activates or the
    /// phone comes back within range.
    func sendPending() {
        guard let store, let session, session.activationState == .activated else { return }

        // A wedged transfer must not hold every later thought hostage. If the
        // system still owns a transfer for an ID, leave it alone; otherwise a
        // pending or interrupted transfer is safe to queue again because the
        // phone commits by UUID and acknowledges idempotently.
        let outstandingIDs = Set(session.outstandingFileTransfers.compactMap {
            MemoDelivery.id(in: $0.file.metadata)
        })
        for memo in store.memos where memo.syncState != .synced && !outstandingIDs.contains(memo.id) {
            send(memo)
        }
    }

    private func receivePhoneReceipt(for id: UUID) {
        guard let store, store.memos.contains(where: { $0.id == id }) else { return }
        store.setSyncState(.synced, for: id)
        retryDelay = 30
        log.info("Phone committed \(id.uuidString, privacy: .public)")
    }

    /// A successful file-transfer callback only proves the system accepted the
    /// transfer, not that a phone receipt will arrive. Requeue any unreceipted
    /// source after a quiet interval; duplicate delivery is harmless because the
    /// phone commits and acknowledges by the immutable watch UUID.
    private func scheduleReceiptRetry() {
        guard receiptRetryTask == nil else { return }
        receiptRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.receiptRetryDelay))
            guard !Task.isCancelled else { return }
            self?.receiptRetryTask = nil
            self?.sendPending()
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
        let id = MemoDelivery.id(in: fileTransfer.file.metadata)
        Task { @MainActor [weak self] in
            guard let self, let id else { return }
            if let error {
                self.store?.setSyncState(.pending, for: id)
                self.log.error("Transfer failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleRetry()
            } else {
                self.retryDelay = 30
                // Delivery to WatchConnectivity's inbox is not proof that the
                // phone committed the file. Retain this source until the phone
                // sends its UUID-only receipt.
                self.log.info("Transfer finished; awaiting phone receipt for \(id.uuidString, privacy: .public)")
                self.scheduleReceiptRetry()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let id = MemoDelivery.phoneReceiptID(in: userInfo) else { return }
        Task { @MainActor [weak self] in self?.receivePhoneReceipt(for: id) }
    }
}
