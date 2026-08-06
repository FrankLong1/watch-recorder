import AVFoundation
import Foundation
import Testing

/// Covers the compression step on its own, because both devices now depend on
/// it: the watch runs it on every memo it files, and the phone runs it again on
/// a capture the watch had to keep raw. Nothing downstream of the phone can
/// read PCM in a CAF, so this conversion is the only thing standing between a
/// rescued memo and one that cannot be transcribed at all.
@Suite("AudioCompressor")
struct AudioCompressorTests {

    private static func makeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real capture in the format `RecordingEngine` writes. Silence is fine —
    /// what is under test is the container and the framing, not the audio.
    private static func writeCapture(seconds: Double, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: CaptureFormat.sampleRate,
            channels: AVAudioChannelCount(CaptureFormat.channels),
            interleaved: true
        ) else { throw CocoaError(.fileWriteUnknown) }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(CaptureFormat.sampleRate * seconds)
        // Must be the file's *processing* format, not its on-disk one: a
        // mismatched buffer raises an ObjC exception and takes the whole test
        // process down rather than failing a single test.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    @Test("turns a raw PCM capture into a readable, much smaller AAC file")
    func compressesCapture() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = directory.appendingPathComponent("capture.caf")
        let compressed = directory.appendingPathComponent("memo.m4a")
        try Self.writeCapture(seconds: 2, to: capture)

        let duration = try AudioCompressor.compress(source: capture, to: compressed)

        #expect(abs(duration - 2) < 0.2)
        // Readable as an M4A specifically — the point of the conversion is that
        // something other than AVFoundation can decode what comes out.
        #expect(AudioDuration.of(compressed) > 1.5)

        let captureBytes = (try FileManager.default
            .attributesOfItem(atPath: capture.path)[.size] as? Int) ?? 0
        let compressedBytes = (try FileManager.default
            .attributesOfItem(atPath: compressed.path)[.size] as? Int) ?? 0
        #expect(compressedBytes > 0)
        #expect(compressedBytes < captureBytes / 2)
    }

    @Test("throws rather than leaving a plausible-looking output when the source is not audio")
    func rejectsGarbage() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notAudio = directory.appendingPathComponent("capture.caf")
        try Data("not a caf file".utf8).write(to: notAudio)
        let destination = directory.appendingPathComponent("memo.m4a")

        // The callers on both devices key on this throwing: it is what makes
        // them keep the original file instead of filing an empty memo.
        #expect(throws: (any Error).self) {
            try AudioCompressor.compress(source: notAudio, to: destination)
        }
    }
}
