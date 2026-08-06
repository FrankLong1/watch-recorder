import SwiftUI

/// First-run and denied states.
///
/// The prompt is never shown pre-emptively at launch — it appears the first
/// time the user actually asks for a memo, so the request has obvious context.
struct PermissionView: View {

    enum State { case ask, denied }

    @Environment(RecorderModel.self) private var model
    let state: State

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: state == .ask ? "mic.circle.fill" : "mic.slash.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(state == .ask ? .red : .secondary)

                Text(state == .ask ? "Microphone Access" : "Microphone Is Off")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if state == .ask {
                    Button("Allow Microphone") {
                        Task { await model.requestPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var message: String {
        switch state {
        case .ask:
            "WristMemo records voice memos on your watch. Audio stays on device until you sync it."
        case .denied:
            "Turn it back on in Settings › Privacy & Security › Microphone on your Apple Watch."
        }
    }
}
