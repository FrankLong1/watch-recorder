import SwiftUI

struct SavingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Saving…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown after a memo is already on disk. Nothing here can lose the recording —
/// "Delete" is an explicit undo, not a required confirmation step.
struct SavedView: View {

    @Environment(RecorderModel.self) private var model
    let memo: Memo

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)

            Text("Saved")
                .font(.headline)

            Text(memo.duration.memoClock)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Delete", role: .destructive) {
                    model.delete(memo)
                    model.dismissResult()
                }
                .font(.caption)

                Button("Done") { model.dismissResult() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 6)
    }
}

struct FailureView: View {

    @Environment(RecorderModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)

            Button("OK") { model.dismissResult() }
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 6)
    }
}
