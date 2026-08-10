import Foundation

/// The status-only protocol shared by the watch and phone.
///
/// Audio travels through WatchConnectivity as a file. Its durable receipts do
/// not: the phone returns only the original UUID once the file and its sidecar
/// are safely committed, and the ingest service returns only `204 No Content`
/// once the transcript is durable. Keeping this contract in one small type
/// prevents either device from inferring success from transport mechanics.
enum MemoDelivery {

    struct Metadata: Equatable, Sendable {
        let id: UUID
        let recordedAt: Date
        let duration: TimeInterval
    }

    private static let idKey = "id"
    private static let createdAtKey = "createdAt"
    private static let durationKey = "duration"
    private static let receiptIDKey = "memoReceiptID"

    static func metadata(id: UUID, recordedAt: Date, duration: TimeInterval) -> [String: Any] {
        [
            idKey: id.uuidString,
            createdAtKey: recordedAt.timeIntervalSince1970,
            durationKey: duration
        ]
    }

    /// Reject malformed metadata instead of manufacturing a replacement UUID.
    /// A new ID turns a recoverable transfer failure into a duplicate thought.
    static func decodeMetadata(_ raw: [String: Any]?) -> Metadata? {
        guard
            let raw,
            let idString = raw[idKey] as? String,
            let id = UUID(uuidString: idString),
            let createdAt = raw[createdAtKey] as? TimeInterval,
            let duration = raw[durationKey] as? TimeInterval,
            createdAt.isFinite,
            createdAt > 0,
            duration.isFinite,
            duration > 0
        else { return nil }

        return Metadata(
            id: id,
            recordedAt: Date(timeIntervalSince1970: createdAt),
            duration: duration
        )
    }

    static func id(in metadata: [String: Any]?) -> UUID? {
        guard let idString = metadata?[idKey] as? String else { return nil }
        return UUID(uuidString: idString)
    }

    static func phoneReceipt(for id: UUID) -> [String: Any] {
        [receiptIDKey: id.uuidString]
    }

    static func phoneReceiptID(in userInfo: [String: Any]) -> UUID? {
        guard let idString = userInfo[receiptIDKey] as? String else { return nil }
        return UUID(uuidString: idString)
    }

    /// The ingest contract is intentionally narrow. A captive portal can answer
    /// `200` with HTML, but only WristMemo's committed response is `204`.
    static func isIngestReceipt(status: Int?) -> Bool {
        status == 204
    }
}
