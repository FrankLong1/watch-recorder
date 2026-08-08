import Foundation

/// The hand-off between `StartRecordingIntent` and the recorder.
///
/// `.foreground(.immediate)` means the system performs the intent inside the
/// app's own process, so this is deliberately just an in-process latch. It is a
/// latch rather than a notification because ordering is not guaranteed: the
/// intent can run before `RecorderModel` exists, and a notification posted then
/// would be dropped. A flag set before and read after works either way.
enum RecordingLaunchRequest {

    /// Posted in addition to setting the latch, so an app that is already
    /// running reacts immediately instead of at the next scene-phase change.
    static let notification = Notification.Name("com.franklong.wristmemo.startRecordingRequested")

    private static var isPending = false

    static func post() {
        isPending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// Reads and clears the latch.
    static func consume() -> Bool {
        #if DEBUG
        // The simulator has no Action button, so this stands in for one:
        //   xcrun simctl launch <sim> <bundle-id> -WristMemoAutoRecord YES
        // Keeping it here rather than in RecorderModel means the production
        // start decision has no `#if DEBUG` in it.
        if UserDefaults.standard.bool(forKey: "WristMemoAutoRecord") { isPending = true }
        #endif

        defer { isPending = false }
        return isPending
    }
}
