import AVFoundation
import Foundation
import WatchConnectivity

/// Receives memos from the watch and plays them back.
@MainActor
@Observable
final class PhoneLibrary: NSObject {

    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let recordedAt: Date
        let duration: TimeInterval
    }

    /// What the watch sends alongside the audio, written next to each file so
    /// the phone never has to open an AAC file just to learn its duration.
    private struct Sidecar: Codable {
        let recordedAt: Date
        let duration: TimeInterval
    }

    private(set) var items: [Item] = []
    private(set) var playingID: UUID?

    private let log = SharedConfig.logger("PhoneLibrary")
    private var player: AVAudioPlayer?

    /// `nonisolated` because `session(_:didReceive:)` has to move the inbox file
    /// before it returns, and cannot hop to the main actor to look up a path.
    nonisolated static let memosDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Memos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func start() {
        reload()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func reload() {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: Self.memosDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        items = urls
            .filter { ["m4a", "caf"].contains($0.pathExtension) }
            .map { url in
                let sidecar = Self.readSidecar(for: url)
                let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                return Item(
                    id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
                    url: url,
                    recordedAt: sidecar?.recordedAt ?? created ?? Date(),
                    // Only decodes for a memo that arrived without metadata.
                    duration: sidecar?.duration ?? AudioDuration.of(url)
                )
            }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private nonisolated static func sidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("json")
    }

    private nonisolated static func readSidecar(for audio: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(for: audio)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
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
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: item.url))
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
        let metadata = file.metadata
        let name = (metadata?["id"] as? String) ?? UUID().uuidString
        let destination = Self.memosDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(file.fileURL.pathExtension)

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            try? FileManager.default.copyItem(at: file.fileURL, to: destination)
        }

        if let recordedAt = metadata?["createdAt"] as? TimeInterval,
           let duration = metadata?["duration"] as? TimeInterval {
            let sidecar = Sidecar(recordedAt: Date(timeIntervalSince1970: recordedAt), duration: duration)
            try? JSONEncoder().encode(sidecar).write(to: Self.sidecarURL(for: destination), options: .atomic)
        }

        Task { @MainActor [weak self] in self?.reload() }
    }
}
