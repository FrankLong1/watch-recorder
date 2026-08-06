import Foundation

struct Memo: Identifiable, Codable, Equatable, Sendable {
    enum SyncState: String, Codable, Sendable {
        case pending      // waiting for a reachable phone
        case transferring
        case synced
    }

    let id: UUID
    var filename: String
    var createdAt: Date
    var duration: TimeInterval
    var syncState: SyncState
    /// True when the memo was rebuilt from a capture the app never got to
    /// finish — surfaced in the list so the user knows why it appeared.
    var recovered: Bool

    init(
        id: UUID = UUID(),
        filename: String,
        createdAt: Date = Date(),
        duration: TimeInterval,
        syncState: SyncState = .pending,
        recovered: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.duration = duration
        self.syncState = syncState
        self.recovered = recovered
    }
}

extension TimeInterval {
    /// `1:04` / `12:03` — the watch never has room for hours of memo.
    var memoClock: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `0:04.7` — tenths while recording, so the UI visibly moves.
    var recordingClock: String {
        let total = max(0, self)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let tenths = Int((total - floor(total)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
