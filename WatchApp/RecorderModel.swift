import AVFoundation
import Foundation
import SwiftUI
import WatchKit
import os

/// Coordinates permission, the recording engine, storage and sync, and owns the
/// state the UI renders.
///
/// The ordering in here is the whole latency story. `init()` runs before SwiftUI
/// builds a single view, so a launch triggered by the Action button starts the
/// microphone from there — not from a view's `.task`, which would wait for the
/// first frame. Everything that is not on the path to the first audio sample —
/// loading the memo index, activating WatchConnectivity, recovering orphaned
/// captures — is deferred until after recording is underway. See LATENCY.md.
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

    private(set) var phase: Phase = .idle
    private(set) var permission: MicPermission = .undetermined
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var recoveredCount = 0

    /// Milliseconds from process start to the first sample, surfaced in DEBUG so
    /// the demo can show the number rather than assert it.
    private(set) var lastStartLatencyMilliseconds: Double?

    let store = MemoStore()
    let sync = WatchSyncClient()

    // MARK: - Private

    private let engine = RecordingEngine()
    private let log = Logger(subsystem: "com.franklong.wristmemo", category: "RecorderModel")

    private var currentID: UUID?
    private var armedID: UUID?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    private var didDeferredSetup = false
    private var startRequested = false
    private var interruptedByCall = false
    private var batteryCheckCounter = 0
    private var startInFlight = false

    private init() {
        Latency.mark("model init")

        // Category first: the documented way to keep activation cheap later.
        engine.configureSession()
        engine.onUnexpectedStop = { [weak self] url in
            self?.handleUnexpectedStop(captureURL: url)
        }

        permission = Self.currentPermission()
        observeSystemEvents()

        // Claim the launch request here, before any view exists. This is what
        // makes the recording UI the *first* frame drawn rather than a swap
        // from the home screen a moment later.
        claimLaunchRequest()
        if startRequested, permission == .granted {
            phase = .starting
            // Get the session request in flight before SwiftUI takes the main
            // actor; `startRecording` will await whatever this started.
            engine.beginActivation()
            Task { await startRecording() }
        }
    }

    // MARK: - Launch

    private func claimLaunchRequest() {
        if RecordingLaunchRequest.consume() { startRequested = true }

        #if DEBUG
        // The simulator has no Action button, so this is the only way to
        // exercise the launch-straight-into-recording path there. It feeds the
        // same flag the control's intent sets, so it tests the real path:
        //   xcrun simctl launch <sim> com.franklong.wristmemo.watchkitapp -WristMemoAutoRecord YES
        if UserDefaults.standard.bool(forKey: "WristMemoAutoRecord") {
            startRequested = true
        }
        #endif
    }

    /// Called from the view's `.task`. Deliberately does nothing that the first
    /// audio sample depends on — by the time this runs, recording is already
    /// going in the common case.
    func bootstrap() async {
        handlePendingRequest()

        guard !didDeferredSetup else { return }
        didDeferredSetup = true

        store.loadIfNeeded()
        sync.activate(store: store)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        BackgroundWarmth.schedule()

        // Transcoding an orphan can take seconds. It must never sit between a
        // button press and the microphone opening, which is exactly where it
        // used to be.
        let inFlight = Set([engine.captureURL, engine.armedCaptureURL].compactMap { $0 })
        let recovered = await store.recoverOrphanedCaptures(excluding: inFlight)
        recoveredCount = recovered.count
        for memo in recovered { sync.send(memo) }

        prearmIfIdle()
    }

    /// Honours a request that arrived while the app was already running.
    private func handlePendingRequest() {
        claimLaunchRequest()
        guard startRequested else { return }
        startRequested = false

        switch permission {
        case .granted:
            Task { await startRecording() }
        case .undetermined:
            // Keep the request alive across the prompt so the memo starts the
            // moment the user allows the microphone.
            startRequested = true
            Task { await requestPermission() }
        case .denied:
            phase = .failed("Microphone access is off.")
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            permission = Self.currentPermission()
            handlePendingRequest()
            prearmIfIdle()
        case .background:
            // Recording deliberately continues here; watchOS keeps the audio
            // session alive for a foreground-started recording. See LIMITATIONS.md.
            break
        default:
            break
        }
    }

    /// Builds the next recorder while the user is doing nothing, so a press only
    /// has to activate the session and call `record()`.
    private func prearmIfIdle() {
        guard phase == .idle, permission == .granted, armedID == nil else { return }
        let id = UUID()
        guard let url = try? store.newCaptureURL(id: id) else { return }
        engine.prearm(url: url)
        armedID = id
    }

    // MARK: - Permission

    private static func currentPermission() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// `AVAudioApplication.requestRecordPermission` replaced the deprecated
    /// `AVAudioSession.requestRecordPermission` in watchOS 10.
    func requestPermission() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        permission = granted ? .granted : .denied
        if granted, startRequested {
            startRequested = false
            await startRecording()
        } else if !granted {
            startRequested = false
            Haptics.failed()
        }
    }

    // MARK: - Transport

    func startRecording() async {
        // `init` and the view's `.task` can both reach here for the same press.
        guard !startInFlight, phase != .recording, phase != .paused else { return }
        guard permission == .granted else {
            await requestPermission()
            return
        }
        startInFlight = true
        defer { startInFlight = false }

        Latency.mark("start requested")
        phase = .starting
        elapsed = 0
        accumulated = 0
        level = 0

        // Fired before the microphone is confirmed open, on purpose. The haptic
        // is the user's acknowledgement that the press registered, and holding
        // it back until `record()` returns makes the whole thing feel slower
        // than it is. A failure haptic follows if it does not work out.
        Haptics.recordingStarted()

        let id: UUID
        let url: URL
        if let armedID, let armedURL = engine.armedCaptureURL {
            id = armedID
            url = armedURL
        } else {
            id = UUID()
            guard let fresh = try? store.newCaptureURL(id: id) else {
                phase = .failed("Couldn't create the recording file.")
                Haptics.failed()
                return
            }
            url = fresh
        }

        do {
            try await engine.start(writingTo: url)
            armedID = nil
            currentID = id
            startDate = Date()
            phase = .recording
            lastStartLatencyMilliseconds = Latency.millisecondsSinceLaunch
            startTicker()
            scheduleDebugAutoStopIfRequested()
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
            armedID = nil
            currentID = nil
            phase = .failed(error.localizedDescription)
            Haptics.failed()
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            engine.pause()
            accumulated += Date().timeIntervalSince(startDate ?? Date())
            startDate = nil
            phase = .paused
            level = 0
            Haptics.recordingStopped()
        case .paused:
            guard engine.resume() else {
                phase = .failed("Couldn't resume recording.")
                Haptics.failed()
                return
            }
            startDate = Date()
            phase = .recording
            Haptics.recordingStarted()
        default:
            break
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
            phase = .idle
            return
        }
        currentID = nil
        phase = .saving

        if let memo = await store.finalize(captureURL: url, id: id) {
            sync.send(memo)
            phase = .saved(memo)
            Haptics.saved()
        } else {
            phase = .failed("That memo was too short to save.")
            Haptics.failed()
        }
        prearmIfIdle()
    }

    func cancelRecording() {
        guard phase == .recording || phase == .paused else { return }
        stopTicker()
        if let url = engine.stop() {
            store.discardCapture(at: url)
        }
        currentID = nil
        phase = .idle
        elapsed = 0
        Haptics.discarded()
        prearmIfIdle()
    }

    func dismissResult() {
        phase = .idle
        elapsed = 0
        prearmIfIdle()
    }

    func delete(_ memo: Memo) {
        store.delete(memo)
        Haptics.discarded()
    }

    /// Simulator-only: `-WristMemoAutoStopAfter 5` stops and saves after five
    /// seconds, so the whole pipeline can be verified without a tap.
    private func scheduleDebugAutoStopIfRequested() {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "WristMemoAutoStopAfter")
        guard seconds > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await stopAndSave()
        }
        #endif
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
        guard phase == .recording else { return }
        elapsed = accumulated + Date().timeIntervalSince(startDate ?? Date())
        level = engine.currentLevel()

        batteryCheckCounter += 1
        if batteryCheckCounter >= 50 {  // ~5 s
            batteryCheckCounter = 0
            checkBattery()
        }
    }

    /// The watch powers off before it warns the app, so save early rather than
    /// rely on a termination callback that may never arrive.
    private func checkBattery() {
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

        center.addObserver(
            forName: RecordingLaunchRequest.inProcessNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.startRequested = true
                self.handlePendingRequest()
            }
        }

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }

        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // The session and recorder are gone; salvage what was written.
                self?.log.error("Media services reset mid-recording")
                await self?.stopAndSave()
            }
        }
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
            engine.pause()
            accumulated += Date().timeIntervalSince(startDate ?? Date())
            startDate = nil
            phase = .paused
            level = 0

        case .ended:
            guard interruptedByCall, phase == .paused else { return }
            interruptedByCall = false
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            }
            if options?.contains(.shouldResume) == true, engine.resume() {
                startDate = Date()
                phase = .recording
            } else {
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
        phase = .saving
        Task {
            if let memo = await store.finalize(captureURL: captureURL, id: id, recovered: true) {
                sync.send(memo)
                phase = .saved(memo)
                Haptics.saved()
            } else {
                phase = .failed("Recording stopped unexpectedly.")
                Haptics.failed()
            }
        }
    }
}
