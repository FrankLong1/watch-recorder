import AVFoundation
import Foundation
import SwiftUI
import WatchKit

/// Simulator-only switches, isolated here so the production launch path has no
/// conditional compilation in it.
private enum DebugOptions {
    static var autoStopAfter: TimeInterval? {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "WristMemoAutoStopAfter")
        return seconds > 0 ? seconds : nil
        #else
        nil
        #endif
    }
}

/// Coordinates permission, the recording engine, storage and sync, and owns the
/// state the UI renders.
///
/// The ordering in here is the whole latency story. `init()` runs before SwiftUI
/// builds a single view, so a launch triggered by the Action button starts the
/// microphone from there. Everything that is not on the path to the first audio
/// sample — the memo index, WatchConnectivity, recovering orphaned captures —
/// is deferred until after recording is underway. See LATENCY.md.
@MainActor
@Observable
final class RecorderModel {

    static let shared = RecorderModel()

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
        case saving
        case saved(Memo)
        case failed(String)
    }

    enum MicPermission {
        case undetermined, granted, denied
    }

    // MARK: - Observable state

    /// Returning to idle re-arms the next recorder. Attached to the transition
    /// rather than called from each path that reaches idle — as five separate
    /// calls it had already drifted, with the one after a save unreachable
    /// behind its own `phase == .idle` guard.
    private(set) var phase: Phase = .idle {
        didSet { if phase == .idle { prearmIfIdle() } }
    }
    private(set) var permission: MicPermission = .undetermined
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var recoveredCount = 0
    private(set) var lastStartLatencyMilliseconds: Double?

    let store = MemoStore()
    let sync = WatchSyncClient()

    // MARK: - Private

    private let engine = RecordingEngine()
    private let log = SharedConfig.logger("RecorderModel")

    private var currentID: UUID?
    /// The moment the user actually started this memo. A pre-armed capture file
    /// can be created long before that, so its filesystem creation date is not
    /// suitable metadata for the finished memo.
    private var recordedAt: Date?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    private var didDeferredSetup = false
    private var interruptedByCall = false
    private var lastBatteryCheck = Date.distantPast
    /// Not derivable from `phase`: `init` sets `.starting` synchronously, so a
    /// phase-based guard would reject the very task `init` queues.
    private var startInFlight = false

    private init() {
        Latency.mark("model init")

        engine.configureSession()
        engine.onUnexpectedStop = { [weak self] url in
            self?.handleUnexpectedStop(captureURL: url)
        }

        permission = Self.currentPermission()
        observeSystemEvents()

        // Claimed here, before any view exists, so the recording UI is the first
        // frame drawn rather than a swap from the home screen.
        if RecordingLaunchRequest.consume() {
            if permission == .granted {
                phase = .starting
                engine.beginActivation()
            }
            Task { await startRecording() }
        }
    }

    // MARK: - Launch

    /// Called from the view's `.task`. Deliberately does nothing the first audio
    /// sample depends on — recording is already underway in the common case.
    func bootstrap() async {
        handlePendingRequest()

        guard !didDeferredSetup else { return }
        didDeferredSetup = true

        store.loadIfNeeded()
        sync.activate(store: store)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        BackgroundWarmth.schedule()

        // Transcoding an orphan can take seconds, so it must never sit between
        // a button press and the microphone opening.
        let recovered = await store.recoverOrphanedCaptures(excluding: engine.reservedCaptureURLs)
        recoveredCount = recovered.count
        for memo in recovered { sync.send(memo) }

        // The first arm of the session. Deliberately last: it touches the disk,
        // and a launch that is already recording must not wait on it.
        prearmIfIdle()
    }

    private func handlePendingRequest() {
        guard RecordingLaunchRequest.consume() else { return }
        Task { await startRecording() }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard scenePhase == .active else { return }
        // Recording deliberately continues in the background; watchOS keeps a
        // foreground-started session alive. See LIMITATIONS.md.
        permission = Self.currentPermission()
        handlePendingRequest()
        // Not covered by the `phase` observer: granting the microphone in
        // Settings and coming back changes `permission` while phase is already
        // idle, so no transition fires.
        prearmIfIdle()
    }

    /// Builds the next recorder while the user is doing nothing, so a press only
    /// has to activate the session and call `record()`.
    private func prearmIfIdle() {
        guard phase == .idle, permission == .granted, engine.armedCaptureURL == nil else { return }
        guard let url = try? store.newCaptureURL(id: UUID()) else { return }
        engine.prearm(url: url)
    }

    /// The pre-armed capture, with its id recovered from the filename so the
    /// engine stays the single owner of pre-arm state.
    private var armedCapture: (id: UUID, url: URL)? {
        guard
            let url = engine.armedCaptureURL,
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        else { return nil }
        return (id, url)
    }

    // MARK: - Permission

    private static func currentPermission() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    @discardableResult
    func requestPermission() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        permission = granted ? .granted : .denied
        return granted
    }

    // MARK: - Transport

    func startRecording() async {
        // `.starting` is valid only for the task queued by `init` after it has
        // already set the optimistic first frame. A save must finish before a
        // new recording can replace the model state it will update on return.
        guard !startInFlight, phase != .recording, phase != .paused, phase != .saving else { return }
        startInFlight = true
        defer { startInFlight = false }

        // Not `||` — the right-hand side of a short-circuit is an autoclosure,
        // which cannot be async.
        if permission != .granted {
            guard await requestPermission() else {
                Haptics.failed()
                return
            }
        }

        // First real work, and synchronous: the request has to be in flight
        // before anything else, including the haptic, which is an IPC hop.
        engine.beginActivation()

        Latency.mark("start requested")
        phase = .starting
        elapsed = 0
        accumulated = 0
        level = 0

        // Fired before the microphone is confirmed open, on purpose. The haptic
        // acknowledges the press; holding it back until `record()` returns makes
        // the whole thing feel slower than it is.
        Haptics.recordingStarted()

        let capture: (id: UUID, url: URL)
        if let armedCapture {
            capture = armedCapture
        } else {
            let id = UUID()
            guard let url = try? store.newCaptureURL(id: id) else {
                phase = .failed("Couldn't create the recording file.")
                Haptics.failed()
                return
            }
            capture = (id, url)
        }

        do {
            try await engine.start(writingTo: capture.url)
            currentID = capture.id
            let now = Date()
            recordedAt = now
            startDate = now
            phase = .recording
            lastStartLatencyMilliseconds = Latency.millisecondsSinceLaunch
            startTicker()
            scheduleDebugAutoStop()
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
            currentID = nil
            recordedAt = nil
            phase = .failed(error.localizedDescription)
            Haptics.failed()
        }
    }

    /// Stops and saves. There is no separate "save" step by design: on a watch
    /// the memo is committed the instant recording ends, so nothing can be lost
    /// between stopping and confirming.
    func stopAndSave() async {
        guard phase == .recording || phase == .paused else { return }
        stopTicker()
        Haptics.recordingStopped()

        guard let url = engine.stop(), let id = currentID else {
            currentID = nil
            recordedAt = nil
            phase = .idle
            return
        }
        currentID = nil
        let recordedAt = recordedAt
        self.recordedAt = nil
        await commit(
            captureURL: url,
            id: id,
            recordedAt: recordedAt,
            failureMessage: "That memo was too short to save."
        )
    }

    /// The one place a capture becomes a memo. Shared by the normal stop and the
    /// unexpected-stop path, which must never diverge from it.
    private func commit(
        captureURL: URL,
        id: UUID,
        recordedAt: Date? = nil,
        failureMessage: String
    ) async {
        phase = .saving
        if let memo = await store.finalize(captureURL: captureURL, id: id, recordedAt: recordedAt) {
            sync.send(memo)
            phase = .saved(memo)
            Haptics.saved()
        } else {
            phase = .failed(failureMessage)
            Haptics.failed()
        }
    }

    func cancelRecording() {
        guard phase == .recording || phase == .paused else { return }
        stopTicker()
        if let url = engine.stop() {
            store.discardCapture(at: url)
        }
        currentID = nil
        recordedAt = nil
        phase = .idle
        elapsed = 0
        Haptics.discarded()
    }

    func dismissResult() {
        phase = .idle
        elapsed = 0
    }

    func delete(_ memo: Memo) {
        store.delete(memo)
        Haptics.discarded()
    }

    private func scheduleDebugAutoStop() {
        guard let seconds = DebugOptions.autoStopAfter else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await stopAndSave()
        }
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common` keeps the timer running while the user scrolls the crown.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        // Battery is checked on wall-clock, not on a tick count, so the interval
        // does not silently change with the UI refresh rate.
        if Date().timeIntervalSince(lastBatteryCheck) >= 5 {
            lastBatteryCheck = Date()
            checkBattery()
        }
        guard phase == .recording, let startDate else { return }
        elapsed = accumulated + Date().timeIntervalSince(startDate)
        level = engine.currentLevel()
    }

    /// The watch powers off before it warns the app, so save early rather than
    /// rely on a termination callback that may never arrive.
    private func checkBattery() {
        guard phase == .recording || phase == .paused else { return }
        let device = WKInterfaceDevice.current()
        guard device.batteryState != .charging, device.batteryLevel >= 0 else { return }
        if device.batteryLevel <= 0.05 {
            log.notice("Battery critical; saving recording")
            Task { await stopAndSave() }
        }
    }

    // MARK: - Interruptions

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // `queue: nil` runs the block inline on the posting thread; each block
        // already hops to the main actor itself, and `queue: .main` would add a
        // second run-loop turn to the path that starts recording.
        center.addObserver(forName: RecordingLaunchRequest.notification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.handlePendingRequest() }
        }

        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }

        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Task { @MainActor in
                // The session and recorder are gone; salvage what was written.
                self?.log.error("Media services reset mid-recording")
                await self?.stopAndSave()
            }
        }
    }

    private func pauseTransport() {
        engine.pause()
        accumulated += Date().timeIntervalSince(startDate ?? Date())
        startDate = nil
        phase = .paused
        level = 0
    }

    private func resumeTransport() -> Bool {
        guard engine.resume() else { return false }
        startDate = Date()
        phase = .recording
        return true
    }

    /// A phone call or Siri takes the microphone away. Pause rather than stop,
    /// so a short interruption doesn't chop the memo in two.
    private func handleInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            guard phase == .recording else { return }
            interruptedByCall = true
            pauseTransport()

        case .ended:
            guard interruptedByCall, phase == .paused else { return }
            interruptedByCall = false
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            }
            if options?.contains(.shouldResume) != true || !resumeTransport() {
                // Can't get the microphone back — keep what was captured.
                Task { await stopAndSave() }
            }

        @unknown default:
            break
        }
    }

    /// The recorder died on its own (encoder error, session yanked). Whatever
    /// reached disk is still a valid PCM capture, so file it as a memo.
    private func handleUnexpectedStop(captureURL: URL?) {
        stopTicker()
        guard let captureURL, let id = currentID else {
            phase = .idle
            return
        }
        currentID = nil
        let recordedAt = recordedAt
        self.recordedAt = nil
        Task {
            await commit(
                captureURL: captureURL,
                id: id,
                recordedAt: recordedAt,
                failureMessage: "Recording stopped unexpectedly."
            )
        }
    }
}
