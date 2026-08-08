import AppIntents

/// Exposes the same intent to Siri and the Shortcuts app.
///
/// This is what gives non-Ultra watches a comparable one-press route: a
/// shortcut wrapping `StartRecordingIntent` can be pinned or invoked by voice,
/// even though only Ultra models have an Action button.
struct WristMemoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Control your agents in \(.applicationName)",
                "Send an instruction with \(.applicationName)"
            ],
            shortTitle: "Control Your Agents",
            systemImageName: "mic.fill"
        )
    }
}
