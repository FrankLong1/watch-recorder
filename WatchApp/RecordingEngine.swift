import AVFoundation
import Foundation
import os

/// Thin wrapper around `AVAudioRecorder` plus the watch's audio session.
///
/// Capture format is 16-bit linear PCM in a CAF container, which is a
/// deliberate choice: PCM-in-CAF has no trailing index or `moov` atom to write
/// at stop time, so a file left behind by a killed process is still fully
/// decodable. `MemoStore` compresses it to AAC once the recording ends, and
/// recovers orphaned captures on the next launch.
@MainActor
final class RecordingEngine: NSObject {

    enum EngineError: LocalizedError {
        case sessionActivationFailed(Error?)
        case recorderRefusedToStart

        var errorDescription: String? {
            switch self {
            case .sessionActivationFailed: "Couldn't start the microphone."
            case .recorderRefusedToStart: "Couldn't start recording."
            }
        }
    }

    static let captureSampleRate = 22_050.0

    private static let captureSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: RecordingEngine.captureSampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    private let log = Logger(subsystem: "com.franklong.wristmemo", category: "RecordingEngine")
    private var recorder: AVAudioRecorder?

    private(set) var captureURL: URL?
    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Called when the recorder stops for a reason the app didn't ask for.
    var onUnexpectedStop: ((URL?) -> Void)?

    // MARK: - Session

    /// Configures the category early so `start(writingTo:)` only has to activate
    /// and roll. Cheap enough to call more than once.
    func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        } catch {
            log.error("setCategory failed: \(error.localizedDescription)")
        }
    }

    /// watchOS uses `activate(options:completionHandler:)` rather than
    /// `setActive(_:)`; the system may need to ask the user to pick a route, so
    /// activation is asynchronous here in a way it is not on iOS.
    private func activateSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AVAudioSession.sharedInstance().activate(options: []) { activated, error in
                if activated {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: EngineError.sessionActivationFailed(error))
                }
            }
        }
    }

    // MARK: - Transport

    func start(writingTo url: URL) async throws {
        configureSession()
        try await activateSession()

        let recorder = try AVAudioRecorder(url: url, settings: Self.captureSettings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.record() else { throw EngineError.recorderRefusedToStart }

        self.recorder = recorder
        self.captureURL = url
        log.info("Recording to \(url.lastPathComponent, privacy: .public)")
    }

    func pause() {
        recorder?.pause()
    }

    /// Returns `false` when the session could not be reactivated, which happens
    /// if something else (a call, Siri) still owns the microphone.
    func resume() -> Bool {
        guard let recorder else { return false }
        return recorder.record()
    }

    /// Stops the recorder and hands back the finished capture file.
    @discardableResult
    func stop() -> URL? {
        let url = captureURL
        recorder?.stop()
        recorder = nil
        captureURL = nil
        // Leaving the session active would keep the microphone indicator lit.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return url
    }

    // MARK: - Metering

    /// Normalised 0…1 input level, floored at -50 dB so the meter idles at zero
    /// in a quiet room instead of hovering.
    func currentLevel() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        guard decibels > -50 else { return 0 }
        return min(1, max(0, (decibels + 50) / 50))
    }
}

extension RecordingEngine: AVAudioRecorderDelegate {

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        let url = recorder.url
        Task { @MainActor [weak self] in
            self?.log.error("Recorder finished unsuccessfully")
            self?.recorder = nil
            self?.captureURL = nil
            self?.onUnexpectedStop?(url)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            self?.log.error("Encode error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            self?.recorder = nil
            self?.captureURL = nil
            self?.onUnexpectedStop?(url)
        }
    }
}
