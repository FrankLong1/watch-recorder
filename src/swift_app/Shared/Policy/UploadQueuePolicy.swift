import Foundation

/// Keeps transcription delivery deliberately narrow.
///
/// A normal watch produces one memo at a time, but a restored phone can have a
/// sizeable durable backlog. Starting that entire backlog at once exhausts the
/// ingest service and makes retries collide with requests that are still being
/// transcribed. The background URLSession therefore owns one upload lane.
enum UploadQueuePolicy {
    /// Google Sign-In is the only setup gate. Requiring the immutable account
    /// ID as well as the UI state prevents a half-restored session from
    /// releasing audio before it can obtain the backend-audience token.
    static func isAuthorizedByGoogleSignIn(
        isSignedIn: Bool,
        accountID: String?
    ) -> Bool {
        isSignedIn && accountID?.isEmpty == false
    }

    static func nextPendingID(
        pendingIDs: [UUID],
        activeTaskCount: Int
    ) -> UUID? {
        guard activeTaskCount == 0 else { return nil }
        return pendingIDs.first
    }

    /// These client-shaped responses do not mean the audio or request is
    /// permanently bad. In particular, 429 is the response older builds saw
    /// after releasing a restored backlog all at once.
    static func isTransientClientStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429
    }
}
