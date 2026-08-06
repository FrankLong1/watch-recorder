import AVFoundation
import Foundation

/// Turns a raw PCM capture into a compact AAC file.
///
/// A minute of capture PCM is ~2.6 MB; the same minute of 32 kbit/s AAC is
/// ~240 KB. That matters twice over — watch storage, and the time
/// `WCSession.transferFile` needs to move the memo to the phone.
enum AudioCompressor {

    /// Reads `source`, writes an `.m4a` at `destination`, returns its duration.
    static func compress(source: URL, to destination: URL) throws -> TimeInterval {
        let input = try AVAudioFile(forReading: source)
        let totalFrames = input.length
        let duration = Double(totalFrames) / input.fileFormat.sampleRate

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

        while input.framePosition < totalFrames {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }

        return duration
    }
}
