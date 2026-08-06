import AVFoundation
import Foundation
import WatchConnectivity
import os

/// Receives memos from the watch and plays them back.
@MainActor
@Observable
final class PhoneLibrary: NSObject {

    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let receivedAt: Date
        let duration: TimeInterval
    }

    private(set) var items: [Item] = []
    private(set) var playingID: UUID?

    private let log = Logger(subsystem: "com.wristmemo.app", category: "PhoneLibrary")
    private let fileManager = FileManager.default
    private var player: AVAudioPlayer?

    private lazy var directory: URL = {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Memos", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func start() {
        reload()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func reload() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        items = urls
            .filter { ["m4a", "caf"].contains($0.pathExtension) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey])
                let asset = try? AVAudioFile(forReading: url)
                let duration = asset.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                return Item(
                    id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
                    url: url,
                    receivedAt: values?.creationDate ?? Date(),
                    duration: duration
                )
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    // MARK: - Playback

    func play(_ item: Item) {
        if playingID == item.id {
            stop()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: item.url)
            player.delegate = self
            player.play()
            self.player = player
            playingID = item.id
        } catch {
            log.error("Playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func delete(_ item: Item) {
        if playingID == item.id { stop() }
        try? fileManager.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
    }
}

extension PhoneLibrary: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}

extension PhoneLibrary: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS so the session can re-pair with a new watch.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The inbox copy is deleted as soon as this returns, so move it now
        // rather than on a hop to the main actor.
        let destination = inboxDestination(for: file)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            try? FileManager.default.copyItem(at: file.fileURL, to: destination)
        }
        Task { @MainActor [weak self] in self?.reload() }
    }

    private nonisolated func inboxDestination(for file: WCSessionFile) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let name = (file.metadata?["id"] as? String) ?? UUID().uuidString
        return base.appendingPathComponent(name).appendingPathExtension(file.fileURL.pathExtension)
    }
}
