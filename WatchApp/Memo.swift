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
}
