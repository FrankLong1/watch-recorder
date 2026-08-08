import Foundation

struct Memo: Identifiable, Codable, Equatable, Sendable {
    enum SyncState: String, Codable, Sendable {
        case pending      // waiting for a reachable phone
        case transferring
        case synced
    }

    var id = UUID()
    var filename: String
    var createdAt = Date()
    var duration: TimeInterval
    var syncState: SyncState = .pending
    /// When the phone took delivery, which is what the watch's retention window
    /// is measured from. Optional because "not yet" is the value that keeps a
    /// memo on the wrist indefinitely — see `Retention`.
    var syncedAt: Date?
}
