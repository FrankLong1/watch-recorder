import SwiftUI
import WidgetKit

/// A button control that starts a voice memo.
///
/// `ControlWidgetButton` is the right template rather than
/// `ControlWidgetToggle`: a toggle would have to report recording state from
/// the extension's process, and the extension cannot observe the app's live
/// audio session. A button models "start a new memo" exactly, and stopping
/// happens in the app where the recording actually lives.
///
/// `StaticControlConfiguration` is used because the control has nothing to
/// configure. Switching to `AppIntentControlConfiguration` would let the user
/// pick, say, an audio quality per control instance.
struct StartRecordingControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedConfig.recordControlKind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record Memo", systemImage: "mic.fill")
            }
            .tint(.red)
        }
        .displayName("Record Voice Memo")
        .description("Start recording a voice memo instantly.")
    }
}
