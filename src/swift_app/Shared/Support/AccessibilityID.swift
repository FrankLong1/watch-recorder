import Foundation

/// Stable identifiers for the controls the UI tests drive.
///
/// Compiled into both the watch app and the UI test bundle so a rename is a
/// build error rather than a test that mysteriously stops finding a button.
/// Labels alone were the alternative, but they break on copy edits, locale, and
/// SF Symbol changes — none of which should fail a test.
enum AccessibilityID {

    /// The whole screen. There is nothing else to identify.
    static let recordButton = "record-button"

    /// The word on the screen, which is also the button's accessibility value.
    ///
    /// These are user-visible copy *and* the tests' only view into the state
    /// machine, which is the price of an interface with one element: there is
    /// no separate status element to query, because SwiftUI folds a button's
    /// label into a single accessibility node. Shared so a copy edit breaks the
    /// build rather than the test.
    enum StatusText {
        static let ready = "READY"
        static let recording = "RECORDING"
        static let paused = "PAUSED"
        static let micOff = "MIC OFF\nALLOW IN SETTINGS"
        static let messageReceived = "MESSAGE RECEIVED"
        static let launchingBackgroundAgent = "Launching background agent…"
        static let completionReceipt = "\(messageReceived)\n\(launchingBackgroundAgent)"
    }
}
