import Testing

@Suite("Capture start failures")
struct CaptureStartFailureTests {

    @Test("each start failure gives the Watch an actionable notice")
    func noticesAreActionable() {
        #expect(CaptureStartFailure.microphoneBusy.notice == "MIC BUSY")
        #expect(CaptureStartFailure.storageUnavailable.notice == "STORAGE FULL")
        #expect(CaptureStartFailure.recorderUnavailable.notice == "TRY AGAIN")
    }
}
