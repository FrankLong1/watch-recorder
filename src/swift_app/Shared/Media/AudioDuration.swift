import AVFoundation
import Foundation

/// Duration of an audio file without decoding it.
///
/// Shared by all three targets: the watch needs it when compression fails, and
/// the phone needs it for any memo that arrived without metadata.
enum AudioDuration {
    static func of(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
