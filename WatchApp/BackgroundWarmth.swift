import WatchKit

/// Keeps the app resident so an Action button press is a *warm* launch.
///
/// Cold launch dominates press-to-record time and there is no public "pre-warm
/// my watch app" API. What exists is indirect: watchOS keeps apps in the Dock
/// in memory, a complication on the active face asks the system to keep the app
/// ready to launch, and background refresh keeps the process from being
/// jettisoned. This schedules the refresh half. See LATENCY.md.
///
/// The budget is shared across apps in the Dock — roughly one wake per hour —
/// so this is a nudge, not a guarantee.
enum BackgroundWarmth {

    private static let log = SharedConfig.logger("Warmth")

    /// Slightly under the hourly budget so a wake is always pending.
    private static let interval: TimeInterval = 45 * 60

    static func schedule() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { error in
            if let error {
                log.error("Refresh scheduling failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Handles the refresh wake and re-arms it, so a wake is always pending.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        Latency.mark("didFinishLaunching")
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if task is WKApplicationRefreshBackgroundTask {
                BackgroundWarmth.schedule()
            }
            task.setTaskCompletedWithSnapshot(false)
        }
    }
}
