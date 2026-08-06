import SwiftUI

struct RecordingView: View {

    @Environment(RecorderModel.self) private var model

    private var isPaused: Bool { model.phase == .paused }

    var body: some View {
        VStack(spacing: 6) {
            statusRow
            timer
            LevelMeter(level: model.level, isActive: !isPaused)
                .frame(height: 18)
            controls
        }
        .padding(.horizontal, 4)
    }

    private var statusRow: some View {
        HStack(spacing: 5) {
            RecordingDot(isAnimating: !isPaused)
            Text(isPaused ? "PAUSED" : "RECORDING")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPaused ? Color.secondary : Color.red)
                .monospaced()
        }
    }

    private var timer: some View {
        Text(model.elapsed.recordingClock)
            .font(.system(size: 38, weight: .semibold, design: .rounded))
            // Fixed-width digits stop the timer jittering as numbers change.
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .contentTransition(.numericText())
    }

    private var controls: some View {
        HStack(spacing: 8) {
            CircleButton(
                systemImage: "xmark",
                tint: .secondary,
                accessibilityLabel: "Cancel recording"
            ) {
                model.cancelRecording()
            }

            CircleButton(
                systemImage: isPaused ? "mic.fill" : "pause.fill",
                tint: .orange,
                accessibilityLabel: isPaused ? "Resume recording" : "Pause recording"
            ) {
                model.togglePause()
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
            .frame(width: 9, height: 9)
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
        return max(3, 18 * envelope * (isActive ? max(0.12, level) : 0.12))
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
                .font(.system(size: filled ? 19 : 15, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .frame(width: filled ? 50 : 38, height: filled ? 50 : 38)
                .background(filled ? tint : Color.white.opacity(0.14), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
