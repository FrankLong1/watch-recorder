import Foundation
import Testing

/// The thresholds in `SilenceMonitor` decide whether a memo survives, so they
/// are tested against the environments in docs/stop-mechanisms.md §4.4.2 rather
/// than only against a quiet room, which is the one case that always worked.
@Suite("Silence auto-stop")
struct SilenceMonitorTests {

    // MARK: - Helpers

    /// Feeds a constant level for `seconds` at the app's 10 Hz tick rate.
    ///
    /// Tick counts are integers because 0.1 does not sum cleanly in binary and
    /// the assertions here sit right on the threshold boundaries.
    @discardableResult
    private func feed(
        _ monitor: inout SilenceMonitor,
        level: Double,
        seconds: TimeInterval,
        tick: TimeInterval = 0.1
    ) -> SilenceMonitor.State {
        var state = monitor.state
        for _ in 0..<Int((seconds / tick).rounded()) {
            state = monitor.ingest(level: level, delta: tick)
        }
        return state
    }

    private var isArmed: (SilenceMonitor.State) -> Bool {
        { if case .armed = $0 { true } else { false } }
    }

    // MARK: - The quiet room

    @Test("Silence arms after the threshold, not before")
    func armsAfterThreshold() {
        var monitor = SilenceMonitor()
        #expect(feed(&monitor, level: 0, seconds: 3.5) == .listening)
        #expect(isArmed(feed(&monitor, level: 0, seconds: 1.0)))
    }

    @Test("Armed runs the full countdown before elapsing")
    func countdownRunsFull() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0, seconds: 4.5)
        // 2.0s into a 3.0s countdown: still recoverable.
        #expect(isArmed(feed(&monitor, level: 0, seconds: 2.0)))
        #expect(feed(&monitor, level: 0, seconds: 1.0) == .elapsed)
    }

    @Test("Nothing stops before arming plus countdown")
    func neverStopsEarly() {
        var monitor = SilenceMonitor()
        #expect(feed(&monitor, level: 0, seconds: 6.5) != .elapsed)
    }

    // MARK: - The case that made the absolute threshold necessary

    /// Press the Action button and start talking with no leading silence. The
    /// ambient estimate has nothing but the speaker to learn from, so the
    /// relative test cannot fire and only `absoluteSpeech` saves the memo.
    @Test("Speech from the very first sample never arms")
    func speechFromTheFirstSampleNeverArms() {
        var monitor = SilenceMonitor()
        #expect(feed(&monitor, level: 0.55, seconds: 30) == .listening)
    }

    @Test("Normal speech over a learned quiet room never arms")
    func speechOverQuietRoomNeverArms() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0, seconds: 1)
        #expect(feed(&monitor, level: 0.3, seconds: 30) == .listening)
    }

    // MARK: - Noisy rooms

    /// A café's room tone must not read as speech, or the memo never ends.
    @Test("Steady ambient noise still arms")
    func ambientNoiseStillArms() {
        var monitor = SilenceMonitor()
        #expect(isArmed(feed(&monitor, level: 0.3, seconds: 4.5)))
    }

    /// …and speech over that same room tone must still register.
    @Test("Speech above café ambient is detected")
    func speechAboveAmbientIsDetected() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0.3, seconds: 2)
        #expect(feed(&monitor, level: 0.6, seconds: 10) == .listening)
    }

    /// The failure this app would actually notice: a tracker that lets the floor
    /// climb during speech decides the room went quiet mid-sentence.
    @Test("Sustained speech does not get absorbed into the ambient estimate")
    func sustainedSpeechIsNotAbsorbed() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0.05, seconds: 1)
        let threshold = monitor.speechThreshold
        feed(&monitor, level: 0.5, seconds: 60)
        #expect(monitor.speechThreshold == threshold)
    }

    // MARK: - Veto

    @Test("Speech during the countdown takes the stop back")
    func speechVetoesTheCountdown() {
        var monitor = SilenceMonitor()
        #expect(isArmed(feed(&monitor, level: 0, seconds: 4.5)))
        #expect(feed(&monitor, level: 0.5, seconds: 0.5) == .listening)
        // And the full silence window has to elapse again from scratch.
        #expect(feed(&monitor, level: 0, seconds: 3.0) == .listening)
    }

    @Test("A tap vetoes without disturbing the ambient estimate")
    func tapVetoKeepsTheFloor() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0.3, seconds: 4.5)
        let threshold = monitor.speechThreshold
        monitor.vetoStop()
        #expect(monitor.state == .listening)
        #expect(monitor.speechThreshold == threshold)
    }

    /// A door slam is not someone resuming a thought. If a single loud sample
    /// reset the timer, a finished memo in a busy room would never end.
    @Test("A transient shorter than minimumVoiced does not reset the timer")
    func transientDoesNotReset() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0, seconds: 3.5)
        feed(&monitor, level: 0.9, seconds: 0.1)
        #expect(isArmed(feed(&monitor, level: 0, seconds: 0.5)))
    }

    // MARK: - Terminal and reset

    /// The model schedules the save asynchronously, so a tick that lands after
    /// the decision must not walk it back.
    @Test("elapsed is terminal until reset")
    func elapsedIsTerminal() {
        var monitor = SilenceMonitor()
        #expect(feed(&monitor, level: 0, seconds: 7.5) == .elapsed)
        #expect(feed(&monitor, level: 0.9, seconds: 2.0) == .elapsed)
    }

    @Test("reset clears the ambient estimate for a new room")
    func resetClearsTheFloor() {
        var monitor = SilenceMonitor()
        feed(&monitor, level: 0.4, seconds: 4.5)
        monitor.reset()
        #expect(monitor.state == .listening)
        // Back to the seeded maximum: the next recording learns its own room.
        #expect(monitor.speechThreshold > 1)
    }

    // MARK: - Tuning

    @Test("Tuning drives the thresholds")
    func tuningIsRespected() {
        var monitor = SilenceMonitor(tuning: .init(armAfter: 1, countdown: 0.5))
        #expect(isArmed(feed(&monitor, level: 0, seconds: 1.2)))
        #expect(feed(&monitor, level: 0, seconds: 0.6) == .elapsed)
    }

    /// The ticker is a `Timer`, which drifts. Thresholds are in seconds, so a
    /// coarser tick must reach the same decision at the same wall-clock time.
    @Test("Decisions follow elapsed time, not tick count")
    func decisionsFollowElapsedTime() {
        var fast = SilenceMonitor()
        var slow = SilenceMonitor()
        #expect(feed(&fast, level: 0, seconds: 7.5, tick: 0.1) == .elapsed)
        #expect(feed(&slow, level: 0, seconds: 7.5, tick: 0.5) == .elapsed)
    }
}
