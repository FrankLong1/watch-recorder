import Foundation
import Testing

@Suite("Upload queue policy")
struct UploadQueuePolicyTests {

    @Test("Google Sign-In is the single upload authorization gate")
    func googleSignInAuthorizesUploads() {
        #expect(
            UploadQueuePolicy.isAuthorizedByGoogleSignIn(
                isSignedIn: true,
                accountID: "google-subject"
            )
        )
        #expect(
            !UploadQueuePolicy.isAuthorizedByGoogleSignIn(
                isSignedIn: false,
                accountID: "google-subject"
            )
        )
        #expect(
            !UploadQueuePolicy.isAuthorizedByGoogleSignIn(
                isSignedIn: true,
                accountID: nil
            )
        )
    }

    @Test("only one pending memo enters an empty upload lane")
    func selectsOneMemo() {
        let first = UUID()
        let second = UUID()

        #expect(
            UploadQueuePolicy.nextPendingID(
                pendingIDs: [first, second],
                activeTaskCount: 0
            ) == first
        )
    }

    @Test("an active background task blocks another upload")
    func activeTaskBlocksQueue() {
        #expect(
            UploadQueuePolicy.nextPendingID(
                pendingIDs: [UUID(), UUID()],
                activeTaskCount: 1
            ) == nil
        )
    }

    @Test("an empty queue stays idle")
    func emptyQueueStaysIdle() {
        #expect(
            UploadQueuePolicy.nextPendingID(
                pendingIDs: [],
                activeTaskCount: 0
            ) == nil
        )
    }

    @Test("rate limits and timeout-shaped client responses remain retryable")
    func transientClientResponsesRemainRetryable() {
        #expect(UploadQueuePolicy.isTransientClientStatus(408))
        #expect(UploadQueuePolicy.isTransientClientStatus(425))
        #expect(UploadQueuePolicy.isTransientClientStatus(429))
        #expect(!UploadQueuePolicy.isTransientClientStatus(400))
        #expect(!UploadQueuePolicy.isTransientClientStatus(403))
        #expect(!UploadQueuePolicy.isTransientClientStatus(413))
    }
}
