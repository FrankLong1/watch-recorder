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

    /// What the microphone is doing, and nothing else.
    ///
    /// There is deliberately no `saving` or `saved` case. Compression and sync
    /// take seconds and the user must never wait on them: a stop returns to
    /// `idle` at once, ready for the next thought, while the memo finishes
    /// filing itself. See `stop()`.
    ///
    /// `recording` is load-bearing beyond the state machine — it is what turns
    /// the screen red, so it may only be entered once `AVAudioRecorder` is
    /// actually writing. `starting` exists to keep that promise honest.
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
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

    /// A word shown in place of READY, then cleared on its own.
    ///
    /// Deliberately not a phase. Everything that can go wrong here goes wrong
    /// *after* the recording ended — compression, mostly — by which point the
    /// user may already have started the next memo, and an error that seizes
    /// the screen would take the microphone with it.
    private(set) var notice: String?

    /// Red on the screen, and the only state that means audio is being written.
    var isRecording: Bool { phase == .recording }

    /// Elapsed time and input level are still measured; nothing displays them.
    /// They feed the silence detector and the duration cap, which are the two
    /// things that end a recording when the user forgets to.
    private var elapsed: TimeInterval = 0
    private var level: Double = 0
    /// Seconds left before silence ends the recording, or nil when nothing is
    /// pending. Not shown — the warning is a haptic, because the whole premise
    /// is that the user is not looking at the watch.
    private var autoStopRemaining: TimeInterval?

    let store = MemoStore()
    let sync = WatchSyncClient()

    // MARK: - Limits

    /// The backstop that makes every other stop mechanism safe to tune. A
    /// pocketed watch whose silence detector never fires still cannot record all
    /// day — which is the privacy problem, not just the battery one.
    private static let maximumDuration: TimeInterval = 10 * 60
    /// How long before the cap the warning haptic fires.
    private static let capWarningLead: TimeInterval = 60

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
    private var silence = SilenceMonitor()
    /// The monitor is fed real elapsed time rather than the ticker's nominal
    /// 0.1s: `Timer` drifts, and the thresholds are in seconds of silence.
    private var lastTick: Date?
    private var didWarnAboutCap = false
    /// Not derivable from `phase`: `init` sets `.starting` synchronously, so a
    /// phase-based guard would reject the very task `init` queues.
    private var startInFlight = false
    private var noticeTask: Task<Void, Never>?

    /// Long enough to read a single word on a wrist that has just come up.
    private static let noticeDuration: Duration = .seconds(3)

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
        for memo in recovered { sync.send(memo) }

        // After recovery, so a memo rebuilt from a capture is judged on the
        // sync state it has just been given rather than the one it had before.
        store.purgeDeliveredMemos()

        // The first arm of the session. Deliberately last: it touches the disk,
        // and a launch that is already recording must not wait on it.
        prearmIfIdle()
    }

    /// The Action button is the same control as the screen, so a press while a
    /// memo is running ends it rather than being swallowed. Unverified on
    /// hardware: it depends on the control's intent still reaching a foreground
    /// app, which only an Ultra can prove. See DEVICE_TESTING.md.
    private func handlePendingRequest() {
        guard RecordingLaunchRequest.consume() else { return }
        toggle()
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
        // The common case for the reaper: the app is opened, or foregrounded by
        // the Action button, some time after the memos it holds were delivered.
        store.purgeDeliveredMemos()
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

    /// The whole interface. One control, one gesture, both directions.
    func toggle() {
        switch phase {
        case .recording, .paused:
            stop()
        case .idle, .starting:
            Task { await startRecording() }
        }
    }

    func startRecording() async {
        // `.starting` is valid only for the task queued by `init` after it has
        // already set the optimistic first frame.
        guard !startInFlight, phase != .recording, phase != .paused else { return }
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
        // Not `.recording`: the screen goes red off the back of that case, and
        // it must not turn red until the recorder is genuinely writing.
        phase = .starting
        elapsed = 0
        accumulated = 0
        level = 0
        autoStopRemaining = nil
        didWarnAboutCap = false
        silence.reset()
        lastTick = nil
        clearNotice()

        // Acknowledges the press only. The haptic that means "speak" is fired
        // below, with the microphone confirmed open.
        Haptics.pressReceived()

        let capture: (id: UUID, url: URL)
        if let armedCapture {
            capture = armedCapture
        } else {
            let id = UUID()
            guard let url = try? store.newCaptureURL(id: id) else {
                phase = .idle
                post(notice: "CAN'T RECORD")
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
            Haptics.recordingStarted()
            startTicker()
            scheduleDebugAutoStop()
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
            currentID = nil
            recordedAt = nil
            phase = .idle
            post(notice: "CAN'T RECORD")
        }
    }

    /// Ends the recording and returns to ready *immediately*.
    ///
    /// Compression takes seconds and the memo is safe on disk as raw PCM before
    /// any of it starts, so making the user watch it is pure cost: the second
    /// thought always arrives while the first is still encoding. The commit is
    /// handed to a task that owns everything it needs, which is what makes
    /// overlapping saves safe — nothing it touches afterwards is model state a
    /// newer recording will have overwritten.
    func stop() {
        guard phase == .recording || phase == .paused else { return }
        stopTicker()
        autoStopRemaining = nil
        Haptics.recordingStopped()

        let url = engine.stop()
        let id = currentID
        let startedAt = recordedAt
        currentID = nil
        recordedAt = nil
        elapsed = 0
        phase = .idle

        guard let url, let id else { return }
        Task { await commit(captureURL: url, id: id, recordedAt: startedAt, failureNotice: "TOO SHORT") }
    }

    /// The one place a capture becomes a memo. Shared by the normal stop and the
    /// unexpected-stop path, which must never diverge from it.
    ///
    /// Touches `phase` only through `post(notice:)`, and that refuses to
    /// interrupt a recording — by the time this returns, the user may be two
    /// memos further on.
    private func commit(
        captureURL: URL,
        id: UUID,
        recordedAt: Date? = nil,
        failureNotice: String
    ) async {
        if let memo = await store.finalize(captureURL: captureURL, id: id, recordedAt: recordedAt) {
            sync.send(memo)
            Haptics.saved()
        } else {
            post(notice: failureNotice)
        }
    }

    // MARK: - Notices

    private func post(notice: String) {
        Haptics.failed()
        // A recording underway owns the screen. The log keeps the detail either
        // way; a memo in progress is worth more than a word about a dead one.
        guard phase == .idle else {
            log.error("Suppressed notice while recording: \(notice, privacy: .public)")
            return
        }
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    private func scheduleDebugAutoStop() {
        guard let seconds = DebugOptions.autoStopAfter else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            stop()
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
        let now = Date()
        // Battery is checked on wall-clock, not on a tick count, so the interval
        // does not silently change with the UI refresh rate.
        if now.timeIntervalSince(lastBatteryCheck) >= 5 {
            lastBatteryCheck = now
            checkBattery()
        }
        guard phase == .recording, let startDate else { return }
        elapsed = accumulated + now.timeIntervalSince(startDate)
        level = engine.currentLevel()

        let delta = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        guard delta > 0 else { return }

        guard !enforceDurationCap() else { return }
        updateSilence(delta: delta)
    }

    // MARK: - Automatic stops

    /// Returns true once the cap has ended the recording, so the caller stops
    /// doing anything else to state that is already on its way out.
    private func enforceDurationCap() -> Bool {
        if elapsed >= Self.maximumDuration {
            log.notice("Duration cap reached; saving recording")
            autoStopRemaining = nil
            stop()
            return true
        }
        if !didWarnAboutCap, elapsed >= Self.maximumDuration - Self.capWarningLead {
            didWarnAboutCap = true
            Haptics.durationWarning()
        }
        return false
    }

    private func updateSilence(delta: TimeInterval) {
        guard AutoStopSetting.isEnabled else {
            autoStopRemaining = nil
            return
        }

        switch silence.ingest(level: level, delta: delta) {
        case .listening:
            // Only clear on the transition, so a talking user isn't writing nil
            // over nil ten times a second.
            if autoStopRemaining != nil { autoStopRemaining = nil }

        case .armed(let remaining):
            // The haptic is the real notification here — the whole point is that
            // the user is not looking at the watch.
            if autoStopRemaining == nil { Haptics.autoStopArmed() }
            autoStopRemaining = remaining

        case .elapsed:
            log.notice("Silence auto-stop fired")
            autoStopRemaining = nil
            stop()
        }
    }

    /// The watch powers off before it warns the app, so save early rather than
    /// rely on a termination callback that may never arrive.
    private func checkBattery() {
        guard phase == .recording || phase == .paused else { return }
        let device = WKInterfaceDevice.current()
        guard device.batteryState != .charging, device.batteryLevel >= 0 else { return }
        if device.batteryLevel <= 0.05 {
            log.notice("Battery critical; saving recording")
            stop()
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
                self?.stop()
            }
        }
    }

    private func pauseTransport() {
        engine.pause()
        accumulated += Date().timeIntervalSince(startDate ?? Date())
        startDate = nil
        phase = .paused
        level = 0
        autoStopRemaining = nil
        silence.vetoStop()
    }

    private func resumeTransport() -> Bool {
        guard engine.resume() else { return false }
        startDate = Date()
        phase = .recording
        // Without this the first tick after the call would hand the monitor a
        // delta covering the entire interruption and stop the memo immediately.
        lastTick = nil
        silence.vetoStop()
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
                stop()
            }

        @unknown default:
            break
        }
    }

    /// The recorder died on its own (encoder error, session yanked). Whatever
    /// reached disk is still a valid PCM capture, so file it as a memo.
    private func handleUnexpectedStop(captureURL: URL?) {
        stopTicker()
        // Back to ready before the salvage runs, for the same reason a normal
        // stop is: the user's next thought must not wait on the last one.
        phase = .idle
        guard let captureURL, let id = currentID else { return }
        currentID = nil
        let recordedAt = recordedAt
        self.recordedAt = nil
        Task {
            await commit(
                captureURL: captureURL,
                id: id,
                recordedAt: recordedAt,
                failureNotice: "RECORDING LOST"
            )
        }
    }
}
