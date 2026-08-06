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
    /// in-process notification is what actually triggers recording.
    ///
    /// It is **off by default**: a free (personal) Apple ID team cannot
    /// provision App Groups, so leaving the entitlement on would break device
    /// builds for anyone without a paid membership. Without it
    /// `sharedDefaults` is nil and the in-process path carries the request.
    /// See DESIGN.md, "Hand-off between processes".
    static let appGroupIdentifier = "group.com.franklong.wristmemo"

    /// Stable identity for the control. Changing this after shipping detaches
    /// the control from any Action button or Control Center slot the user has
    /// already configured, so treat it as permanent.
    static let recordControlKind = "com.franklong.wristmemo.control.start-recording"

    /// Watch-face complication. Keeping one on the active face is what nudges
    /// the system to hold the app in memory — see LATENCY.md.
    static let complicationKind = "com.franklong.wristmemo.complication.record"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}
