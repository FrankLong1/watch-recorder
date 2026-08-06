import AVFoundation
import Foundation

/// Turns a raw PCM capture into a compact AAC file.
///
/// A minute of capture PCM is ~2.6 MB; the same minute of 32 kbit/s AAC is
/// ~240 KB. That matters twice over — watch storage, and the time
/// `WCSession.transferFile` needs to move the memo to the phone.
enum AudioCompressor {

    struct Result {
        let url: URL
        let duration: TimeInterval
    }

    /// Reads `source` and writes an `.m4a` at `destination`.
    ///
    /// Runs off the main actor: this is CPU-bound and a long memo would
    /// otherwise stall the UI.
    static func compress(source: URL, to destination: URL) throws -> Result {
        let input = try AVAudioFile(forReading: source)
        let duration = Double(input.length) / input.fileFormat.sampleRate

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: Int(input.fileFormat.channelCount),
            AVEncoderBitRateKey: 32_000
        ]

        let output = try AVAudioFile(forWriting: destination, settings: settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
            throw CocoaError(.fileWriteUnknown)
        }

        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }

        return Result(url: destination, duration: duration)
    }

    /// Duration of a capture file without decoding it, for recovered memos.
    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
