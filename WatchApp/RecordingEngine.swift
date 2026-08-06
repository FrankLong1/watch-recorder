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
///
/// Everything here is arranged around time-to-first-sample; see LATENCY.md.
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

    private var armedRecorder: AVAudioRecorder?
    private var armedURL: URL?

    private(set) var captureURL: URL?
    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Called when the recorder stops for a reason the app didn't ask for.
    var onUnexpectedStop: ((URL?) -> Void)?

    // MARK: - Session

    /// Sets the category only. Doing this as early as possible is the documented
    /// way to avoid a stall later: once a session is activated it is too late to
    /// configure it cheaply, and changing category mid-flight is expensive.
    /// Activation stays deferred because it lights the microphone indicator.
    func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        } catch {
            log.error("setCategory failed: \(error.localizedDescription)")
        }
    }

    private enum Activation {
        case idle
        case inFlight
        case active
        case failed
    }

    private var activation: Activation = .idle
    private var activationWaiters: [CheckedContinuation<Void, Error>] = []

    /// Issues the activation request *now*, without waiting for a Swift
    /// concurrency hop.
    ///
    /// On a launch triggered by the Action button the main actor is busy
    /// bringing SwiftUI up, so anything scheduled with `Task` queues behind it.
    /// Calling the completion-handler API directly gets the request in flight
    /// during launch instead of after it, and the completion lands whenever the
    /// main actor frees up.
    func beginActivation() {
        guard activation == .idle else { return }
        activation = .inFlight
        Latency.mark("activation requested")
        AVAudioSession.sharedInstance().activate(options: []) { [weak self] activated, error in
            Task { @MainActor in
                self?.completeActivation(activated: activated, error: error)
            }
        }
    }

    private func completeActivation(activated: Bool, error: Error?) {
        activation = activated ? .active : .failed
        if activated {
            Latency.mark("session active")
        } else {
            log.error("Activation failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        }
        let waiters = activationWaiters
        activationWaiters.removeAll()
        for waiter in waiters {
            activated ? waiter.resume() : waiter.resume(throwing: EngineError.sessionActivationFailed(error))
        }
    }

    /// watchOS uses `activate(options:completionHandler:)` rather than
    /// `setActive(_:)`; the system may need to ask the user to pick a route, so
    /// activation is asynchronous here in a way it is not on iOS.
    private func activateSession() async throws {
        switch activation {
        case .active:
            return
        case .idle:
            beginActivation()
            try await waitForActivation()
        case .inFlight:
            try await waitForActivation()
        case .failed:
            // An early speculative attempt can fail simply because the app was
            // not frontmost yet. Retry once, now that the user is definitely
            // looking at it, rather than failing the recording outright.
            activation = .idle
            beginActivation()
            try await waitForActivation()
        }
    }

    private func waitForActivation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            switch activation {
            case .active: continuation.resume()
            case .failed: continuation.resume(throwing: EngineError.sessionActivationFailed(nil))
            default: activationWaiters.append(continuation)
            }
        }
    }

    // MARK: - Pre-arming

    /// Builds the recorder and creates its file ahead of the user asking.
    ///
    /// `prepareToRecord()` does the file creation and encoder setup that would
    /// otherwise sit between the button press and the first sample. On a warm
    /// app this turns starting into little more than `record()`.
    func prearm(url: URL) {
        guard recorder == nil, armedRecorder == nil else { return }
        guard let candidate = try? AVAudioRecorder(url: url, settings: Self.captureSettings) else { return }
        candidate.delegate = self
        candidate.isMeteringEnabled = true
        candidate.prepareToRecord()
        armedRecorder = candidate
        armedURL = url
        log.debug("Pre-armed \(url.lastPathComponent, privacy: .public)")
    }

    var armedCaptureURL: URL? { armedURL }

    func discardPrearm() {
        if let armedURL {
            try? FileManager.default.removeItem(at: armedURL)
        }
        armedRecorder = nil
        armedURL = nil
    }

    // MARK: - Transport

    func start(writingTo url: URL) async throws {
        // Session activation is the slowest step and does not depend on the
        // recorder, so overlap the two rather than paying for them in series.
        async let activation: Void = activateSession()

        let target: AVAudioRecorder
        if let armedRecorder, armedURL == url {
            target = armedRecorder
        } else {
            discardPrearm()
            target = try AVAudioRecorder(url: url, settings: Self.captureSettings)
            target.delegate = self
            target.isMeteringEnabled = true
        }

        try await activation

        guard target.record() else { throw EngineError.recorderRefusedToStart }

        recorder = target
        armedRecorder = nil
        armedURL = nil
        captureURL = url
        Latency.mark("first sample")
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
        // The session is down, so the next recording has to activate again.
        activation = .idle
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
            guard let self, self.recorder === recorder else { return }
            self.log.error("Recorder finished unsuccessfully")
            self.recorder = nil
            self.captureURL = nil
            self.onUnexpectedStop?(url)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.log.error("Encode error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            self.recorder = nil
            self.captureURL = nil
            self.onUnexpectedStop?(url)
        }
    }
}
