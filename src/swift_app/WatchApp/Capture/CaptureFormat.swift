import Foundation

/// The on-disk capture format, in one place.
///
/// Deliberately separate from `RecordingEngine`: the store has to decide whether
/// a capture is long enough to keep, which is arithmetic on the format, not a
/// question for the audio session. Keeping it here lets storage logic — and its
/// tests — reason about capture bytes without linking AVFoundation.
enum CaptureFormat {

    /// 16-bit mono linear PCM in a CAF container. See `RecordingEngine` for why
    /// the capture stage is uncompressed.
    static let sampleRate = 22_050.0
    static let bitDepth = 16
    static let channels = 1

    private static var bytesPerFrame: Int { (bitDepth / 8) * channels }

    /// Audio bytes a capture of `seconds` occupies, ignoring the container
    /// header. Kept here so storage and tests can reason about capture sizes
    /// without linking AVFoundation.
    static func bytes(forSeconds seconds: TimeInterval) -> Int {
        Int(sampleRate * Double(bytesPerFrame) * seconds)
    }

    /// `AVAudioRecorder.prepareToRecord()` creates this CAF before it has
    /// written a single sample. It is the only safe size-based rejection: a
    /// spoken one-word memo can be much shorter than an arbitrary duration
    /// threshold, but a file with only this header is not a capture.
    static let prearmedFileBytes = 4_096
}
