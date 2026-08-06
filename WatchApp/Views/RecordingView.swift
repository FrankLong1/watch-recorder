import SwiftUI

/// The screen the Action button lands on.
///
/// The timer and meter are separate views that read the model themselves, so
/// the 10 Hz `elapsed` and `level` writes invalidate only those leaves instead
/// of rebuilding the status row and both buttons ten times a second.
struct RecordingView: View {

    @Environment(RecorderModel.self) private var model

    private var isPaused: Bool { model.phase == .paused }

    var body: some View {
        VStack(spacing: 8) {
            statusRow
            ElapsedTimer()
            LevelMeter(isActive: !isPaused)
                .frame(height: 16)
            controls

            #if DEBUG
            if let milliseconds = model.lastStartLatencyMilliseconds {
                Text("\(Int(milliseconds))ms to first sample")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .padding(.horizontal, 4)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            RecordingDot(isAnimating: !isPaused)
            Text(isPaused ? "PAUSED" : "RECORDING")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isPaused ? Color.secondary : Color.red)
                .monospaced()
                .accessibilityIdentifier(AccessibilityID.recordingStatus)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            CircleButton(systemImage: "xmark", tint: .secondary, accessibilityLabel: "Discard recording") {
                model.cancelRecording()
            }
            .accessibilityIdentifier(AccessibilityID.discardButton)
            CircleButton(systemImage: "stop.fill", tint: .red, filled: true, accessibilityLabel: "Stop and save recording") {
                Task { await model.stopAndSave() }
            }
            .accessibilityIdentifier(AccessibilityID.stopButton)
        }
    }
}

// MARK: - Pieces

private struct ElapsedTimer: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        Text(model.elapsed.recordingClock)
            .accessibilityIdentifier(AccessibilityID.elapsedTimer)
            .font(.system(size: 42, weight: .semibold, design: .rounded))
            // Fixed-width digits stop the timer jittering as numbers change.
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

private struct RecordingDot: View {
    let isAnimating: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.25 : 1)
            .animation(
                isAnimating ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = isAnimating }
            .onChange(of: isAnimating) { _, animating in dim = animating }
    }
}

private struct LevelMeter: View {
    @Environment(RecorderModel.self) private var model
    let isActive: Bool

    private static let maximumHeight: CGFloat = 16

    /// A symmetric envelope so the bars read as a waveform rather than a bar
    /// chart. Depends only on the bar count, so it is computed once.
    private static let envelope: [CGFloat] = {
        let barCount = 13
        let centre = Double(barCount - 1) / 2
        return (0..<barCount).map { index in
            CGFloat(1 - (abs(Double(index) - centre) / centre * 0.65))
        }
    }()

    var body: some View {
        let scale = isActive ? max(0.12, model.level) : 0.12
        HStack(spacing: 2) {
            ForEach(Self.envelope.indices, id: \.self) { index in
                Capsule()
                    .fill(isActive ? Color.red : Color.secondary)
                    .opacity(isActive ? 1 : 0.4)
                    .frame(height: max(3, Self.maximumHeight * Self.envelope[index] * scale))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.level)
        .accessibilityHidden(true)
    }
}

private struct CircleButton: View {
    let systemImage: String
    let tint: Color
    var filled = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: filled ? 22 : 16, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .frame(width: filled ? 58 : 42, height: filled ? 58 : 42)
                .background(filled ? tint : Color.white.opacity(0.14), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
