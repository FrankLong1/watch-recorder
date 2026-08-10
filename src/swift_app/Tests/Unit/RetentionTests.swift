import Foundation
import Testing

/// The rule both devices delete by, tested once rather than twice.
///
/// The cases that matter are the ones where nothing should happen: a memo that
/// has not moved on is the memo a user is most likely to still need, and the
/// only thing standing between it and deletion is `nil` meaning "never".
@Suite("Retention")
struct RetentionTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a memo that has not been handed on never expires")
    func neverHandedOn() {
        #expect(!Retention.hasExpired(handedOnAt: nil, now: now))
        // However old it gets. This is the offline case: the phone is at home
        // for a fortnight, and every memo made in that time is still there.
        #expect(!Retention.hasExpired(handedOnAt: nil, now: now.addingTimeInterval(14 * 86_400)))
    }

    @Test("the window is a full day from the hand-off, not from recording")
    func windowBoundary() {
        let handedOn = now.addingTimeInterval(-Retention.window)
        #expect(Retention.hasExpired(handedOnAt: handedOn, now: now))
        #expect(!Retention.hasExpired(handedOnAt: handedOn.addingTimeInterval(1), now: now))
        #expect(Retention.window == 24 * 60 * 60)
    }

    @Test("a memo handed on moments ago is kept")
    func freshlyHandedOn() {
        #expect(!Retention.hasExpired(handedOnAt: now, now: now))
        #expect(!Retention.hasExpired(handedOnAt: now.addingTimeInterval(-60), now: now))
    }

    /// A watch whose clock is ahead, or a timestamp written by the other device.
    /// Subtracting gives a negative interval, which must not read as expired.
    @Test("a timestamp in the future is not expired")
    func clockSkew() {
        #expect(!Retention.hasExpired(handedOnAt: now.addingTimeInterval(3_600), now: now))
    }
}
