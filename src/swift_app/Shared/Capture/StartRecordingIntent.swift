import AppIntents

/// The single in-app destination exposed by the capture control.
///
/// `OpenIntent` requires a target value. Keeping the value static preserves the
/// one-gesture capture contract: there is nothing for the wearer to configure
/// or choose before recording.
enum CaptureLaunchTarget: String, AppEnum {
    case recorder

    static let typeDisplayRepresentation = TypeDisplayRepresentation("WristMemo destination")
    static let caseDisplayRepresentations: [CaptureLaunchTarget: DisplayRepresentation] = [
        .recorder: DisplayRepresentation(title: "Recorder")
    ]
}

/// The intent behind the control the user assigns to the Action button.
///
/// It deliberately does no recording work itself. watchOS only lets a
/// *foreground* app open the microphone, so the intent's whole job is to bring
/// the app forward and leave a marker saying "start immediately". The recording
/// is then owned by the app, where the audio session, the UI and the
/// interruption handlers all live.
struct StartRecordingIntent: OpenIntent {

    static let title: LocalizedStringResource = "Control Your Agents"

    static let description = IntentDescription(
        "Opens WristMemo and immediately records an instruction for your persistent agents."
    )

    @Parameter(title: "Target")
    var target: CaptureLaunchTarget

    /// The intent exists to back the assigned Action Button Control, not to
    /// create a parallel Siri or Shortcuts start route.
    static let isDiscoverable = false

    init() {
        target = .recorder
    }

    init(target: CaptureLaunchTarget) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        RecordingLaunchRequest.post()
        return .result()
    }
}
