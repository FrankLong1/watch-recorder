import Foundation

/// Stable identifiers for the controls the UI tests drive.
///
/// Compiled into both the watch app and the UI test bundle so a rename is a
/// build error rather than a test that mysteriously stops finding a button.
/// Labels alone were the alternative, but they break on copy edits, locale, and
/// SF Symbol changes — none of which should fail a test.
enum AccessibilityID {
    static let recordButton = "record-button"
    static let recordingStatus = "recording-status"
    static let elapsedTimer = "elapsed-timer"
    static let stopButton = "stop-button"
    static let discardButton = "discard-button"
    static let savedTitle = "saved-title"
    static let savedDuration = "saved-duration"
    static let doneButton = "done-button"
    static let deleteSavedButton = "delete-saved-button"
    static let failureMessage = "failure-message"
    static let failureDismissButton = "failure-dismiss-button"
    static let memoList = "memo-list"
    static let emptyHint = "empty-hint"
}
