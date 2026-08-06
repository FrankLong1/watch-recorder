import SwiftUI

/// The screen the Action button lands on.
///
/// Kept deliberately plain: at a glance, from a wrist, the only questions are
/// "is it recording?" and "how long?". Everything else is one tap away or gone.
struct RecordingView: View {

    @Environment(RecorderModel.self) private var model

    private var isPaused: Bool { model.phase == .paused }

    var body: some View {
        VStack(spacing: 8) {
            statusRow
            timer
            LevelMeter(level: model.level, isActive: !isPaused)
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
        }
    }

    private var timer: some View {
        Text(model.elapsed.recordingClock)
            .font(.system(size: 42, weight: .semibold, design: .rounded))
            // Fixed-width digits stop the timer jittering as numbers change.
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    /// Two buttons, not three. Pause still exists internally for phone-call
    /// interruptions, but a demo does not need a third target on a 49mm screen.
    private var controls: some View {
        HStack(spacing: 14) {
            CircleButton(
                systemImage: "xmark",
                tint: .secondary,
                accessibilityLabel: "Discard recording"
            ) {
                model.cancelRecording()
            }

            CircleButton(
                systemImage: "stop.fill",
                tint: .red,
                filled: true,
                accessibilityLabel: "Stop and save recording"
            ) {
                Task { await model.stopAndSave() }
            }
        }
    }
}

// MARK: - Pieces

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
    let level: Double
    let isActive: Bool

    private let barCount = 13

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(isActive ? Color.red : Color.secondary)
                    .opacity(isActive ? 1 : 0.4)
                    .frame(height: height(for: index))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    /// Shapes the bars into a symmetric envelope so the meter reads as a
    /// waveform rather than a bar chart.
    private func height(for index: Int) -> CGFloat {
        let centre = Double(barCount - 1) / 2
        let distance = abs(Double(index) - centre) / centre
        let envelope = 1 - (distance * 0.65)
        return max(3, 16 * envelope * (isActive ? max(0.12, level) : 0.12))
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
