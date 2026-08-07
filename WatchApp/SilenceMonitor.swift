import Foundation

/// Decides when a recording has trailed off, from the level meter alone.
///
/// The asymmetry in `docs/stop-mechanisms.md` drives the whole design: stopping
/// a few seconds late costs dead air, stopping a second early costs the end of
/// the thought. So this never decides to stop — it *arms*, `RecorderModel` warns
/// with a haptic, and any speech inside the countdown takes it back.
///
/// Deliberately free of `Date`, `AVFoundation` and the main actor: it takes
/// levels and time deltas and returns a state, which is what makes the
/// thresholds testable without a microphone.
struct SilenceMonitor {

    struct Tuning: Equatable {
        /// Quiet time before the countdown starts.
        var armAfter: TimeInterval = 4
        /// The veto window — long enough to feel the haptic and keep talking.
        var countdown: TimeInterval = 3
        /// How far above the ambient floor a level must sit to count as speech.
        /// `RecordingEngine.currentLevel()` maps a 50 dB window onto 0…1, so
        /// 0.12 is roughly 6 dB.
        var speechMargin: Double = 0.12
        /// A level loud enough to be speech regardless of the ambient estimate.
        ///
        /// This exists for one case, and it is the common one: the user presses
        /// the Action button and starts talking immediately. With no prior
        /// silence to learn from, the ambient estimate seeds itself from their
        /// voice, the relative test can never fire, and the memo would stop
        /// seven seconds into a sentence. An absolute floor breaks that tie.
        ///
        /// It is also the one number here that genuinely needs calibrating on
        /// device — see docs/stop-mechanisms.md §8.1. A room louder than this
        /// simply never auto-stops, which is the safe direction to fail.
        var absoluteSpeech: Double = 0.45
        /// Minimum time above the threshold to count as speech. Without it a
        /// door slam resets the timer on a memo that was actually finished.
        var minimumVoiced: TimeInterval = 0.2
        /// How fast the ambient estimate climbs, in level units per second.
        /// About 1 dB/s: quick enough to follow walking into a café, slow enough
        /// that it cannot chase speech upwards and swallow the speaker.
        var floorRise: Double = 0.02

        static let `default` = Tuning()
    }

    enum State: Equatable {
        /// Recording normally — speech, or not yet enough silence to matter.
        case listening
        /// Silent long enough that a stop is pending, with time left to veto it.
        case armed(remaining: TimeInterval)
        /// The countdown ran out. Stop and save.
        case elapsed
    }

    private let tuning: Tuning

    /// Ambient estimate, seeded at the top of the range so the first quiet
    /// sample pulls it straight down. Seeding at zero would classify the whole
    /// room as speech and the monitor would never arm.
    private var floor: Double = 1
    private var voicedFor: TimeInterval = 0
    private var silentFor: TimeInterval = 0
    private var countdownRemaining: TimeInterval = 0

    private(set) var state: State = .listening

    init(tuning: Tuning = .default) {
        self.tuning = tuning
    }

    /// The level that currently counts as speech — ambient plus the margin.
    var speechThreshold: Double { floor + tuning.speechMargin }

    @discardableResult
    mutating func ingest(level: Double, delta: TimeInterval) -> State {
        // Terminal until reset, so a late tick can't walk the decision back
        // after the model has already scheduled the save.
        guard state != .elapsed else { return .elapsed }

        // Instant attack downwards, at any time: a floor seeded too high by a
        // noisy first second has to recover the moment there is a gap, or the
        // whole recording reads as speech and nothing ever arms.
        floor = min(floor, level)

        // Either test is enough: the relative one catches normal speech over a
        // learned room, the absolute one catches speech that started before
        // there was any room to learn.
        if level > speechThreshold || level > tuning.absoluteSpeech {
            voicedFor += delta
        } else {
            voicedFor = 0
            // The estimate only climbs while nothing is being said, and never
            // above the current level. Letting it climb during speech is how a
            // naive tracker absorbs the speaker and then decides the room went
            // quiet while they were still talking.
            floor = min(level, floor + tuning.floorRise * delta)
        }

        if voicedFor >= tuning.minimumVoiced {
            silentFor = 0
            countdownRemaining = 0
            state = .listening
            return state
        }

        silentFor += delta

        switch state {
        case .listening:
            guard silentFor >= tuning.armAfter else { break }
            countdownRemaining = tuning.countdown
            state = .armed(remaining: countdownRemaining)
        case .armed:
            countdownRemaining -= delta
            state = countdownRemaining > 0 ? .armed(remaining: countdownRemaining) : .elapsed
        case .elapsed:
            break
        }

        return state
    }

    /// Forgets the silence but keeps the ambient estimate — after a tap or a
    /// pause it is still the same room.
    mutating func vetoStop() {
        voicedFor = 0
        silentFor = 0
        countdownRemaining = 0
        state = .listening
    }

    /// Full reset for a new recording, ambient estimate included.
    mutating func reset() {
        floor = 1
        vetoStop()
    }
}

/// Whether silence ends a recording on its own. On, and no longer switchable.
///
/// The toggle that set this went with the rest of the settings UI — a watch
/// with one control has nowhere to put a preference, and a safe default beats a
/// per-capture decision (LATENCY.md). It stays as a key rather than a constant
/// because it is still writable from outside the app, which is what lets a
/// device-testing session turn the behaviour off without a rebuild:
///
///     xcrun simctl spawn <udid> defaults write \
///       <container>/Library/Preferences/<bundle-id>.plist \
///       WristMemoAutoStopOnSilence -bool NO
enum AutoStopSetting {
    static let key = "WristMemoAutoStopOnSilence"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
