import Foundation
import os

/// Identifiers shared by the watch app and its control extension.
enum SharedConfig {

    /// A public clone uses a neutral prefix; signed local builds override it
    /// through the ignored Signing.local.xcconfig file.
    static let identifierPrefix: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WristMemoIdentifierPrefix") as? String,
              !value.isEmpty,
              !value.contains("$(")
        else { return "com.example.wristmemo" }
        return value
    }()

    /// Stable identity for the control. Changing this after shipping detaches
    /// the control from any Action button or Control Center slot the user has
    /// already configured, so treat it as permanent.
    static let recordControlKind = "\(identifierPrefix).control.start-recording"

    /// Watch-face complication. Keeping one on the active face is what nudges
    /// the system to hold the app in memory — see LATENCY.md.
    static let complicationKind = "\(identifierPrefix).complication.record"

    /// One subsystem for every logger, because the documented device-debugging
    /// workflow filters on it: `log stream --predicate 'subsystem == "…"'`.
    /// A typo would drop a category out of that stream with no build error.
    static let loggingSubsystem = identifierPrefix

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: loggingSubsystem, category: category)
    }
}
