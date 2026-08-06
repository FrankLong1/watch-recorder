import Foundation

/// Values shared by the watch app and its control extension.
///
/// This file is a member of both the `WristMemo Watch App` and
/// `WristMemoControls` targets so the two processes agree on identifiers.
enum SharedConfig {

    /// App Group used to hand a "start recording" request from the control
    /// extension's process to the app's process.
    ///
    /// The group is a *fallback* path only. When `StartRecordingIntent` runs in
    /// foreground mode the system performs it inside the app itself, and the
    /// in-process notification is what actually triggers recording. If you do
    /// not want to provision an App Group, delete the entitlement and the app
    /// still works — see ARCHITECTURE.md, "Hand-off".
    static let appGroupIdentifier = "group.com.wristmemo.shared"

    /// Stable identity for the control. Changing this after shipping detaches
    /// the control from any Action button or Control Center slot the user has
    /// already configured, so treat it as permanent.
    static let recordControlKind = "com.wristmemo.control.start-recording"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}
