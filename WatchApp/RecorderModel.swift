import AVFoundation
import Foundation
import SwiftUI
import WatchKit
import os

/// Coordinates permission, the recording engine, storage and sync, and owns the
/// state the UI renders.
///
/// A singleton because `StartRecordingIntent` may be performed inside this
/// process before SwiftUI has built any view, and the request has to land
/// somewhere that outlives the view tree.
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

    let store = MemoStore()
    let sync = WatchSyncClient()

    // MARK: - Private

    private let engine = RecordingEngine()
    private let log = Logger(subsystem: "com.franklong.wristmemo", category: "RecorderModel")

    private var currentID: UUID?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    private var isBootstrapped = false
    private var startRequested = false
    private var interruptedByCall = false

    private init() {
        permission = Self.currentPermission()
        observeSystemEvents()
    }

    // MARK: - Launch

    func bootstrap() async {
        guard !isBootstrapped else {
            // Re-entering from the background still needs to honour a request.
            handlePendingRequest()
            return
        }
        isBootstrapped = true

        #if DEBUG
        // The simulator has no Action button, so this is the only way to
        // exercise the launch-straight-into-recording path there. It feeds the
        // same `startRequested` flag the control's intent sets, so it tests the
        // real code path rather than a parallel one:
        //   xcrun simctl launch <sim> com.franklong.wristmemo.watchkitapp -WristMemoAutoRecord YES
        if UserDefaults.standard.bool(forKey: "WristMemoAutoRecord") {
            startRequested = true
        }
        #endif

        // Configure the audio category before anything else: it costs nothing
        // and removes a step from the critical path when recording starts.
        engine.configureSession()
        engine.onUnexpectedStop = { [weak self] url in
            self?.handleUnexpectedStop(captureURL: url)
        }

        store.load()
        sync.activate(store: store)

        let recovered = await store.recoverOrphanedCaptures()
        recoveredCount = recovered.count
        for memo in recovered { sync.send(memo) }

        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true

        handlePendingRequest()
    }

    /// Called on every foreground transition and when the intent fires in-process.
    private func handlePendingRequest() {
        if RecordingLaunchRequest.consume() { startRequested = true }
        guard startRequested else { return }
        startRequested = false

        switch permission {
        case .granted:
            Task { await startRecording() }
        case .undetermined:
            // Keep the request alive across the permission prompt so the memo
            // starts the moment the user allows the microphone.
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
        case .background:
            // Recording deliberately continues here; watchOS keeps the audio
            // session alive for a foreground-started recording. See LIMITATIONS.md.
            break
        default:
            break
        }
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
        guard phase != .recording, phase != .starting else { return }
        guard permission == .granted else {
            await requestPermission()
            return
        }

        phase = .starting
        elapsed = 0
        accumulated = 0
        level = 0

        let id = UUID()
        do {
            let url = try store.newCaptureURL(id: id)
            try await engine.start(writingTo: url)
            currentID = id
            startDate = Date()
            phase = .recording
            Haptics.recordingStarted()
            startTicker()
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
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
    }

    func dismissResult() {
        phase = .idle
        elapsed = 0
    }

    func delete(_ memo: Memo) {
        store.delete(memo)
        Haptics.discarded()
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

    private var batteryCheckCounter = 0

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
                if self.isBootstrapped { self.handlePendingRequest() }
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
