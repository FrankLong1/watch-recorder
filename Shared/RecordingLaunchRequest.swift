import Foundation

/// The hand-off channel between `StartRecordingIntent` and the running app.
///
/// Two paths are written on every request because the system decides which
/// process performs the intent:
///
/// 1. **In-process** — with `.foreground(.immediate)` the system brings the app
///    forward and performs the intent there, so a plain `NotificationCenter`
///    post reaches the recorder directly. This is the path that runs in
///    practice and the one that makes the launch feel instant.
/// 2. **Cross-process** — a timestamp in the shared App Group container, read by
///    the app during start-up. This covers the case where the intent is
///    performed outside the app (for example from Shortcuts) and the app is
///    launched afterwards.
///
/// Both paths converge on the same boolean in `RecorderModel`, so handling a
/// request twice is harmless.
enum RecordingLaunchRequest {

    /// Posted when the intent runs inside the app's own process.
    static let inProcessNotification = Notification.Name("com.franklong.wristmemo.startRecordingRequested")

    /// Requests older than this are ignored. Without an age limit, opening the
    /// app days later from the app grid would start an unwanted recording
    /// because the stored flag was never consumed.
    static let maxAge: TimeInterval = 20

    private static let timestampKey = "pendingRecordingRequestAt"

    static func post() {
        SharedConfig.sharedDefaults?.set(Date().timeIntervalSince1970, forKey: timestampKey)
        NotificationCenter.default.post(name: inProcessNotification, object: nil)
    }

    /// Clears any stored request and reports whether it was recent enough to act on.
    static func consume() -> Bool {
        guard let defaults = SharedConfig.sharedDefaults else { return false }
        let stamp = defaults.double(forKey: timestampKey)
        guard stamp > 0 else { return false }
        defaults.removeObject(forKey: timestampKey)
        return Date().timeIntervalSince1970 - stamp <= maxAge
    }

    static func clear() {
        SharedConfig.sharedDefaults?.removeObject(forKey: timestampKey)
    }
}
