import WatchKit

/// WristMemo has exactly two haptic meanings: the microphone is live, and the
/// recording has ended. Nothing else vibrates — no press acknowledgement, save
/// receipt, warning, or failure — so each signal stays unmistakable.
enum Haptics {
    private static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    /// The microphone is open and audio is reaching the disk. This is the one
    /// the user is trained on, and it fires at the same instant the screen turns
    /// red — neither may run ahead of the recorder.
    static func recordingStarted() { play(.start) }

    /// A recording ended, regardless of why: an explicit stop, Double Tap,
    /// wrist-down timeout, app exit, silence, safety cap, or a lost recorder.
    static func recordingStopped() { play(.stop) }
}
