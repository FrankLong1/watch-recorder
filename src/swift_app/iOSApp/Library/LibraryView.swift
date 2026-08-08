import SwiftUI
import GoogleSignInSwift

struct LibraryView: View {

    @Environment(PhoneLibrary.self) private var library
    @Environment(GoogleAuthentication.self) private var authentication
    @State private var searchText = ""
    @State private var isShowingUploadApproval = false

    var body: some View {
        NavigationStack {
            List {
                if !authentication.isSignedIn || !library.uploadsAreAuthorized {
                    authenticationSection
                }

                let reviewItems = library.reviewItems(matching: searchText)
                if reviewItems.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Memos Yet" : "No Matching Memos",
                        systemImage: searchText.isEmpty ? "mic" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Memos recorded on your Apple Watch appear here once they sync. Their transcripts stay here after temporary audio is removed."
                            : "Try another word from a transcript.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("Voice Memos") {
                        ForEach(reviewItems) { item in
                            row(for: item)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if let localMemo = item.localMemo, localMemo.uploadState == .failed {
                                        Button("Retry") { library.retryUpload(localMemo) }
                                            .tint(.blue)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("WristMemo")
            .searchable(text: $searchText, prompt: "Search transcripts")
            .refreshable {
                await library.refreshTranscriptHistory()
            }
            .toolbar {
                if library.isSynchronizingTranscripts {
                    ToolbarItem(placement: .topBarLeading) {
                        ProgressView()
                            .accessibilityLabel("Refreshing transcripts")
                    }
                }
                if case .signedIn(let email) = authentication.state {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Text(email)
                            Button("Sign Out", role: .destructive) {
                                library.revokeUploadAuthorization()
                                authentication.signOut()
                                library.authenticationDidChange()
                            }
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .accessibilityLabel("Google account")
                        }
                    }
                }
            }
            .alert(uploadApprovalTitle, isPresented: $isShowingUploadApproval) {
                Button("Cancel", role: .cancel) {}
                Button(uploadApprovalButtonTitle) {
                    library.authorizeUploadsForCurrentAccount()
                }
            } message: {
                Text(uploadApprovalMessage)
            }
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Section("Transcription") {
            switch authentication.state {
            case .restoring:
                HStack {
                    ProgressView()
                    Text("Restoring Google sign-in…")
                }
            case .signedOut, .failed:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in with Google to verify your identity and read your transcript history. Signing in does not upload audio.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    GoogleSignInButton {
                        Task {
                            await authentication.signIn()
                            library.authenticationDidChange()
                        }
                    }
                    .frame(height: 48)
                }
                .padding(.vertical, 4)
            case .unavailable:
                Label("Google Sign-In is not configured in this build.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .signedIn:
                VStack(alignment: .leading, spacing: 12) {
                    Text(uploadAuthorizationDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(uploadAuthorizationButtonTitle) {
                        isShowingUploadApproval = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var uploadAuthorizationDescription: String {
        let count = library.pendingUploadCount
        if count == 0 {
            return "Transcription is off. Enable it once to send future Watch recordings automatically after they are safe on this iPhone."
        }
        return "Transcription is off. \(count) recording\(count == 1 ? " is" : "s are") safe on this iPhone and will not upload until you approve."
    }

    private var uploadAuthorizationButtonTitle: String {
        let count = library.pendingUploadCount
        return count == 0
            ? "Enable Automatic Transcription"
            : "Review Upload of \(count) Recording\(count == 1 ? "" : "s")"
    }

    private var uploadApprovalTitle: String {
        let count = library.pendingUploadCount
        return count == 0
            ? "Enable automatic transcription?"
            : "Upload and transcribe \(count) recording\(count == 1 ? "" : "s")?"
    }

    private var uploadApprovalButtonTitle: String {
        let count = library.pendingUploadCount
        return count == 0
            ? "Enable Transcription"
            : "Upload \(count) Recording\(count == 1 ? "" : "s")"
    }

    private var uploadApprovalMessage: String {
        let count = library.pendingUploadCount
        if count == 0 {
            return "Future recordings will upload to WristMemo's Cloud Run service for OpenAI transcription. Audio is streamed through and is not stored in GCP."
        }
        return "The original audio will be streamed through WristMemo's Cloud Run service to OpenAI, then retained only on your devices until the verified hand-off window expires. GCP stores the transcript, not the audio."
    }

    private func row(for item: PhoneLibrary.ReviewItem) -> some View {
        NavigationLink {
            MemoDetailView(item: item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.transcript == nil ? "waveform" : "text.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(item.transcript == nil ? Color.secondary : Color.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.headline)
                    if let transcript = item.transcript {
                        Text(transcript.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                    } else {
                        Text(processingDescription(for: item.uploadState))
                            .font(.subheadline)
                            .foregroundStyle(item.uploadState == .failed ? .orange : .secondary)
                    }
                    Text(item.duration.memoClock)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                UploadBadge(state: item.uploadState)
            }
        }
        .buttonStyle(.plain)
    }

    private func processingDescription(for state: PhoneLibrary.UploadState) -> String {
        switch state {
        case .pending:
            library.uploadsAreAuthorized
                ? "Waiting to send securely"
                : "Safe on this iPhone — transcription is off"
        case .uploading: "Transcribing in background…"
        case .uploaded: "Transcript is syncing to this iPhone…"
        case .failed: "Couldn’t transcribe — swipe to retry"
        }
    }
}

private struct MemoDetailView: View {

    @Environment(PhoneLibrary.self) private var library

    let item: PhoneLibrary.ReviewItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.recordedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.headline)
                    Text(item.duration.memoClock)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let transcript = item.transcript {
                    Text(transcript.text)
                        .font(.body)
                        .textSelection(.enabled)
                    Text("Transcript generated from the recording; names and exact wording may need a quick check.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(
                        processingTitle,
                        systemImage: item.uploadState == .failed ? "exclamationmark.triangle" : "waveform",
                        description: Text(processingDescription)
                    )
                    if let localMemo = item.localMemo, localMemo.uploadState == .failed {
                        Button("Retry Transcription") {
                            library.retryUpload(localMemo)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if item.hasSourceAudio {
                    Button {
                        library.play(item)
                    } label: {
                        Label(
                            library.playingID == item.id ? "Stop Recording" : "Play Original Recording",
                            systemImage: library.playingID == item.id ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Label("The temporary source recording has expired; the transcript is retained.", systemImage: "checkmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Voice Memo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var processingTitle: String {
        if item.uploadState == .pending && !library.uploadsAreAuthorized {
            return "Transcription Is Off"
        }
        return item.uploadState == .failed ? "Transcription Needs Attention" : "Transcribing in Background"
    }

    private var processingDescription: String {
        switch item.uploadState {
        case .pending:
            library.uploadsAreAuthorized
                ? "This memo is safely queued on the phone and will send when it can."
                : "This memo is safe on the phone. Approve transcription from the library before any audio is uploaded."
        case .uploading: "The original recording is being transcribed."
        case .uploaded: "The service has finished; the transcript is downloading to this iPhone."
        case .failed: "The recording is still safe on this iPhone. Retry after correcting the sign-in, connection, or size issue."
        }
    }
}

/// Shows whether a memo has arrived at transcription while the full transcript
/// is loading or awaiting the next secure sync.
private struct UploadBadge: View {

    let state: PhoneLibrary.UploadState

    var body: some View {
        switch state {
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Uploading")
        case .pending:
            icon("clock", .secondary, "Waiting to upload")
        case .uploaded:
            icon("checkmark.icloud", .secondary, "Uploaded")
        case .failed:
            icon("exclamationmark.triangle.fill", .orange, "Upload failed")
        }
    }

    // Typed as Color rather than a shape style so `.secondary` and `.orange`
    // can share one signature — the hierarchical `.secondary` is not a Color.
    private func icon(_ symbol: String, _ tint: Color, _ label: String) -> some View {
        Image(systemName: symbol)
            .font(.footnote)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }
}
