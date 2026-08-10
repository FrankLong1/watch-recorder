import Foundation

/// Compiled into all three targets so the watch and the phone cannot drift
/// apart on what a duration looks like.
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
