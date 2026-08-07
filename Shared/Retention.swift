import Foundation

/// When a device may stop keeping its copy of a memo.
///
/// Both devices run the same rule at different points in the chain: the watch
/// drops a memo a day after the phone has taken delivery, the phone drops it a
/// day after the ingest service has acknowledged it. Each hop only ever deletes
/// behind a copy that already exists further along, so at no point is a memo
/// held by nobody.
///
/// The `nil` case is the whole safety property, and it is why this is a
/// function rather than a date comparison written twice. A memo that has not
/// reached the next hop has no timestamp and therefore never expires — a phone
/// left at home, a week with no network, a revoked token: the audio stays,
/// however old it gets.
enum Retention {

    /// Measured from the hand-off, not from when the memo was recorded. A memo
    /// that syncs three days late still gets its full day on the device.
    static let window: TimeInterval = 24 * 60 * 60

    static func hasExpired(handedOnAt: Date?, now: Date = Date()) -> Bool {
        guard let handedOnAt else { return false }
        return now.timeIntervalSince(handedOnAt) >= window
    }
}
