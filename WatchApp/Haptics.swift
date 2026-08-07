import WatchKit

/// Haptics stand in for the visual confirmation the user doesn't get when the
/// memo starts with their wrist down.
enum Haptics {
    private static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    /// The press landed. Fired immediately, before the microphone is anywhere
    /// near open, because the alternative is a button that feels dead for the
    /// couple of hundred milliseconds the audio session takes to activate.
    /// Deliberately slight: it acknowledges the press, it does not claim to be
    /// recording. `recordingStarted` is the one that means "speak".
    static func pressReceived() { play(.click) }

    /// The microphone is open and audio is reaching the disk. This is the one
    /// the user is trained on, and it fires at the same instant the screen turns
    /// red — neither may run ahead of the recorder.
    static func recordingStarted() { play(.start) }

    static func recordingStopped() { play(.stop) }
    static func saved() { play(.success) }
    static func failed() { play(.failure) }

    /// Silence is about to end the recording. Deliberately *not* `.stop` — the
    /// user has three seconds to talk their way out of it, and a buzz they read
    /// as "already finished" is a veto window they never use. `.directionDown`
    /// is the closest thing watchOS has to "winding down".
    static func autoStopArmed() { play(.directionDown) }

    /// A minute left before the duration cap. `.notification` because this one
    /// is news rather than an acknowledgement of something the user did.
    static func durationWarning() { play(.notification) }
}
