import SwiftUI

/// The entire app.
///
/// One control, the size of the screen. Grey OFF is the only in-app start
/// surface; red RECORDING turns that same large target into a deterministic
/// stop. Double Tap is enabled only while it stops. No timer, no meter, no
/// cancel, no list, no settings, no navigation: everything a memo needs after
/// it is spoken — compress, sync, upload, delete itself — happens without the
/// user, so there is nothing to show and nothing to decide.
///
/// **The colour is a promise, not a mood.** Red is driven by `isRecording`,
/// which the model only enters once `AVAudioRecorder` is genuinely writing. A
/// press whose audio session has not activated yet stays grey, and the haptic
/// that means "speak" fires on the same transition. If red could ever run ahead
/// of the recorder, the one thing this interface says would be a lie.
struct RecordScreen: View {

    @Environment(RecorderModel.self) private var model

    // Not `.red`: a full screen of it at 100% is a klaxon on a wrist at night,
    // and the difference from grey is what carries the meaning, not the
    // saturation. Grey is lifted off pure black so an unlit screen and a ready
    // one are not the same thing.
    private static let recordingColour = Color(red: 0.78, green: 0.10, blue: 0.12)
    private static let readyColour = Color(white: 0.13)
    private static let completionColour = Color(red: 0.08, green: 0.48, blue: 0.22)

    var body: some View {
        Button(action: model.handleScreenTap) {
            Group {
                if let receipt = model.completionReceipt {
                    VStack(spacing: 5) {
                        Text(receipt.title)
                            .font(.custom("Helvetica-Bold", size: 19, relativeTo: .headline))
                        Text(receipt.detail)
                            .font(.custom("Helvetica", size: 11, relativeTo: .caption2))
                            .opacity(0.8)
                    }
                } else {
                    if model.phase == .idle || model.phase == .starting {
                        VStack(spacing: 4) {
                            Text(AccessibilityID.StatusText.off)
                                .font(.custom("Helvetica-Bold", size: 34, relativeTo: .largeTitle))
                            Text(AccessibilityID.StatusText.tapToStartRecording)
                                .font(.custom("Helvetica", size: 12, relativeTo: .caption))
                                .opacity(0.8)
                        }
                    } else {
                    Text(status)
                        .font(.custom("Helvetica-Bold", size: 21, relativeTo: .title3))
                    }
                }
            }
            .foregroundStyle(foregroundColour)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColour)
        }
        .buttonStyle(.plain)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.12), value: model.isRecording)
        .animation(.easeOut(duration: 0.12), value: model.completionReceipt)
        // Double Tap is a stop-only gesture. Disabling it while OFF prevents
        // an incidental hand gesture from becoming a second start route.
        .handGestureShortcut(.primaryAction, isEnabled: model.canStopRecording)
        .accessibilityIdentifier(AccessibilityID.recordButton)
        .accessibilityLabel("Record")
        // The word on screen, exposed as the button's value rather than a
        // separate element: SwiftUI folds a button's label into one
        // accessibility node, so a `Text` inside it is not separately queryable.
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint(model.canStopRecording ? "Stops and saves the memo" : "Starts a memo")
    }

    private var status: String {
        if model.permission == .denied { return AccessibilityID.StatusText.micOff }
        if let notice = model.notice { return notice }
        return switch model.phase {
        case .recording: AccessibilityID.StatusText.recording
        // Paused is the interruption case — a call took the microphone. It is
        // not red, because nothing is being written, and saying OFF would
        // invite a tap that starts a second memo on top of a live one.
        case .paused: AccessibilityID.StatusText.paused
        case .idle, .starting: AccessibilityID.StatusText.idle
        }
    }

    private var accessibilityStatus: String {
        model.completionReceipt.map { "\($0.title)\n\($0.detail)" } ?? status
    }

    private var backgroundColour: Color {
        if model.completionReceipt != nil { return Self.completionColour }
        return model.isRecording ? Self.recordingColour : Self.readyColour
    }

    private var foregroundColour: Color {
        model.completionReceipt != nil || model.isRecording ? .white : Color(white: 0.62)
    }
}
