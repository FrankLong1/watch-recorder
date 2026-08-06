import Foundation
import Testing

/// Serialized on purpose: the latch is process-global static state, and Swift
/// Testing runs tests in parallel by default. Without `.serialized` these would
/// consume each other's pending flag intermittently.
///
/// The DEBUG simulator switch is cleared around every case for the same reason —
/// `consume()` reads `WristMemoAutoRecord` from UserDefaults in DEBUG builds and
/// would otherwise always report a pending request.
@Suite("RecordingLaunchRequest", .serialized)
struct RecordingLaunchRequestTests {

    private static let debugKey = "WristMemoAutoRecord"

    private func clearDebugSwitch() {
        UserDefaults.standard.removeObject(forKey: Self.debugKey)
        // Drain any latch a previous case left set.
        _ = RecordingLaunchRequest.consume()
    }

    @Test("nothing pending by default")
    func idleByDefault() {
        clearDebugSwitch()
        defer { clearDebugSwitch() }

        #expect(RecordingLaunchRequest.consume() == false)
    }

    @Test("post makes exactly one consume succeed")
    func consumedExactlyOnce() {
        clearDebugSwitch()
        defer { clearDebugSwitch() }

        RecordingLaunchRequest.post()

        #expect(RecordingLaunchRequest.consume() == true, "first consume should see the request")
        #expect(RecordingLaunchRequest.consume() == false, "latch should clear after being read")
        #expect(RecordingLaunchRequest.consume() == false)
    }

    /// The intent can fire more than once before the app reads it; that is still
    /// one pending request, not a queue.
    @Test("repeated posts collapse into a single pending request")
    func postsCollapse() {
        clearDebugSwitch()
        defer { clearDebugSwitch() }

        RecordingLaunchRequest.post()
        RecordingLaunchRequest.post()
        RecordingLaunchRequest.post()

        #expect(RecordingLaunchRequest.consume() == true)
        #expect(RecordingLaunchRequest.consume() == false)
    }

    @Test("the DEBUG simulator switch stands in for an Action button press")
    func debugSwitchTriggersRequest() {
        clearDebugSwitch()
        defer { clearDebugSwitch() }

        UserDefaults.standard.set(true, forKey: Self.debugKey)
        #expect(RecordingLaunchRequest.consume() == true,
                "WristMemoAutoRecord should present as a pending request in DEBUG")
    }
}
