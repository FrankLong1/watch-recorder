import AVFoundation
import Foundation

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

    private static let captureSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: CaptureFormat.sampleRate,
        AVNumberOfChannelsKey: CaptureFormat.channels,
        AVLinearPCMBitDepthKey: CaptureFormat.bitDepth,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    private let log = SharedConfig.logger("RecordingEngine")
    private var recorder: AVAudioRecorder?
    private var armedRecorder: AVAudioRecorder?

    private(set) var captureURL: URL?
    private(set) var armedCaptureURL: URL?

    /// Files the engine owns right now. A directory sweep that ignores these
    /// would transcode and delete the recording in progress.
    var reservedCaptureURLs: Set<URL> {
        Set([captureURL, armedCaptureURL].compactMap { $0 })
    }

    var onUnexpectedStop: ((URL?) -> Void)?

    // MARK: - Session

    /// Sets the category only. Doing this as early as possible is the documented
    /// way to keep activation cheap: once a session is activated it is too late,
    /// and changing category mid-flight is expensive. Activation stays separate
    /// because it lights the microphone indicator.
    func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        } catch {
            log.error("setCategory failed: \(error.localizedDescription)")
        }
    }

    private enum Activation { case idle, inFlight, active, failed }

    private var activation: Activation = .idle
    private var activationWaiters: [CheckedContinuation<Void, Error>] = []

    /// Issues the activation request *now*, without a Swift concurrency hop.
    ///
    /// During launch the main actor is busy bringing SwiftUI up, so anything
    /// scheduled with `Task` — including an `async let` whose body is
    /// main-actor-isolated — queues behind it. Calling the completion-handler
    /// API directly gets the request in flight immediately; the completion
    /// lands whenever the actor frees up.
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

    private func awaitActivation() async throws {
        if activation == .active { return }
        // An early speculative attempt can fail simply because the app was not
        // frontmost yet, so a failure is retried once rather than failing the
        // recording outright.
        if activation == .failed { activation = .idle }
        beginActivation()
        // Everything here is main-actor isolated and nothing suspends between
        // the check above and this append, so `activation` is still `.inFlight`.
        try await withCheckedThrowingContinuation { activationWaiters.append($0) }
    }

    // MARK: - Pre-arming

    /// Builds the recorder and creates its file ahead of the user asking.
    ///
    /// `prepareToRecord()` does the file creation and encoder setup that would
    /// otherwise sit between the button press and the first sample.
    func prearm(url: URL) {
        guard recorder == nil, armedRecorder == nil else { return }
        guard let candidate = try? AVAudioRecorder(url: url, settings: Self.captureSettings) else { return }
        candidate.delegate = self
        candidate.isMeteringEnabled = true
        candidate.prepareToRecord()
        armedRecorder = candidate
        armedCaptureURL = url
    }

    func discardPrearm() {
        if let armedCaptureURL {
            try? FileManager.default.removeItem(at: armedCaptureURL)
        }
        armedRecorder = nil
        armedCaptureURL = nil
    }

    // MARK: - Transport

    func start(writingTo url: URL) async throws {
        // Before the recorder is built, not after: activation is the slow step.
        beginActivation()

        let target: AVAudioRecorder
        if let armedRecorder, armedCaptureURL == url {
            target = armedRecorder
        } else {
            discardPrearm()
            target = try AVAudioRecorder(url: url, settings: Self.captureSettings)
            target.delegate = self
            target.isMeteringEnabled = true
        }

        try await awaitActivation()

        guard target.record() else { throw EngineError.recorderRefusedToStart }

        recorder = target
        armedRecorder = nil
        armedCaptureURL = nil
        captureURL = url
        Latency.mark("first sample")
    }

    func pause() {
        recorder?.pause()
    }

    func resume() -> Bool {
        recorder?.record() ?? false
    }

    func stop() -> URL? {
        let url = captureURL
        recorder?.stop()
        recorder = nil
        captureURL = nil
        releaseSession()
        return url
    }

    /// Hands the microphone back.
    ///
    /// Every path that ends a recording goes through here, including the
    /// delegate's unexpected-stop path — leaving the session active would keep
    /// the microphone indicator lit with nothing recording.
    private func releaseSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        activation = .idle
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
        reportUnexpectedStop(of: recorder, reason: "finished unsuccessfully")
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        reportUnexpectedStop(of: recorder, reason: error?.localizedDescription ?? "encode error")
    }

    private nonisolated func reportUnexpectedStop(of recorder: AVAudioRecorder, reason: String) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.log.error("Recorder stopped: \(reason, privacy: .public)")
            self.recorder = nil
            self.captureURL = nil
            self.releaseSession()
            self.onUnexpectedStop?(url)
        }
    }
}
