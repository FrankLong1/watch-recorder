import Foundation
import Testing

@Suite("Duration formatting")
struct FormattingTests {

    @Test("memoClock pads seconds and rolls minutes")
    func memoClockBasics() {
        #expect(TimeInterval(0).memoClock == "0:00")
        #expect(TimeInterval(4).memoClock == "0:04")
        #expect(TimeInterval(64).memoClock == "1:04")
        #expect(TimeInterval(723).memoClock == "12:03")
    }

    /// `memoClock` rounds rather than truncates, so 59.6s reads as a minute.
    /// The interesting case is the carry: it must not produce "0:60".
    @Test("memoClock rounds at the minute boundary without producing :60")
    func memoClockRounding() {
        #expect(TimeInterval(59.4).memoClock == "0:59")
        #expect(TimeInterval(59.6).memoClock == "1:00")
        #expect(TimeInterval(119.6).memoClock == "2:00")
    }

    @Test("recordingClock shows tenths")
    func recordingClockTenths() {
        #expect(TimeInterval(0).recordingClock == "0:00.0")
        #expect(TimeInterval(4.7).recordingClock == "0:04.7")
        #expect(TimeInterval(64.2).recordingClock == "1:04.2")
    }

    /// `elapsed` is computed from wall-clock subtraction, so a clock adjustment
    /// mid-recording can hand it a negative value. It clamps rather than
    /// rendering "-1:-3".
    @Test("recordingClock clamps negatives")
    func recordingClockClamp() {
        #expect(TimeInterval(-5).recordingClock == "0:00.0")
    }
}
