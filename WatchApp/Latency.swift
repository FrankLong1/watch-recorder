import Foundation
import os

/// Measurement for the only number that matters here: how long after the app's
/// process starts does the first audio sample hit disk.
///
/// The Action button press happens before the process exists, so no in-process
/// timer can see it. Process start is the closest observable proxy — everything
/// before it is system launch cost the app cannot influence except by staying
/// warm (see LATENCY.md).
enum Latency {

    private static let log = Logger(subsystem: "com.franklong.wristmemo", category: "Latency")

    /// True process exec time, via sysctl. Falls back to first-touch time if the
    /// sandbox refuses the query.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 {
            let started = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
        }
        return Date()
    }()

    static var millisecondsSinceLaunch: Double {
        Date().timeIntervalSince(processStart) * 1000
    }

    /// Logged, not just measured — on device this is readable with
    /// `log stream --predicate 'subsystem == "com.franklong.wristmemo"'`.
    static func mark(_ label: String) {
        let value = String(format: "%.0f", millisecondsSinceLaunch)
        // `notice`, not `info`: info-level entries are not persisted to the log
        // store by default, so they never show up in `log show` after the fact.
        log.notice("[latency] \(label, privacy: .public) at \(value, privacy: .public)ms")
    }
}
