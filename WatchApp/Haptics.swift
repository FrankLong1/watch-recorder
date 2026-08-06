import WatchKit

/// Haptics stand in for the visual confirmation the user doesn't get when the
/// memo starts with their wrist down.
enum Haptics {
    private static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    static func recordingStarted() { play(.start) }
    static func recordingStopped() { play(.stop) }
    static func saved() { play(.success) }
    static func discarded() { play(.click) }
    static func failed() { play(.failure) }
}
