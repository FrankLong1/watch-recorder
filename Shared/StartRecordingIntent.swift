import AppIntents

/// The intent behind the control the user assigns to the Action button.
///
/// It deliberately does no recording work itself. watchOS only lets a
/// *foreground* app open the microphone, so the intent's whole job is to bring
/// the app forward and leave a marker saying "start immediately". The recording
/// is then owned by the app, where the audio session, the UI and the
/// interruption handlers all live.
struct StartRecordingIntent: AppIntent {

    static let title: LocalizedStringResource = "Record Voice Memo"

    static let description = IntentDescription(
        "Opens WristMemo and immediately starts recording a voice memo."
    )

    /// watchOS 26 replacement for the deprecated `openAppWhenRun`.
    ///
    /// `.foreground(.immediate)` brings the app forward as soon as the button is
    /// pressed rather than waiting for `perform()` to return, which is what
    /// makes an Action button press feel like a hardware record button.
    /// `.deferred` would show the control's own animation first and foreground
    /// the app afterwards — noticeably slower here.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Also surfaces the action in Shortcuts and Siri, the only comparable
    /// route on watches without an Action button.
    static let isDiscoverable = true

    func perform() async throws -> some IntentResult {
        RecordingLaunchRequest.post()
        return .result()
    }
}
