import SwiftUI
import GoogleSignInSwift

struct LibraryView: View {

    @Environment(PhoneLibrary.self) private var library
    @Environment(GoogleAuthentication.self) private var authentication
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if !authentication.isSignedIn {
                    authenticationSection
                }

                let reviewItems = library.reviewItems(matching: searchText)
                if reviewItems.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Thoughts Yet" : "No Matching Thoughts",
                        systemImage: searchText.isEmpty ? "text.bubble" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Thoughts captured on your Apple Watch will appear here."
                            : "Try another word or phrase.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(reviewItems) { item in
                        row(for: item)
                    }
                }
            }
            .navigationTitle("Thoughts")
            .searchable(text: $searchText, prompt: "Search thoughts")
            .refreshable {
                await library.refreshTranscriptHistory()
            }
            .toolbar {
                if case .signedIn(let email) = authentication.state {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Text(email)
                            Button("Sign Out", role: .destructive) {
                                library.prepareForSignOut()
                                authentication.signOut()
                                library.authenticationDidChange()
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .accessibilityLabel("Account")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Section {
            switch authentication.state {
            case .restoring:
                HStack {
                    ProgressView()
                    Text("Connecting…")
                }
            case .signedOut, .failed:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect Google to transcribe and sync your thoughts.")
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
                Text("Transcription is not configured in this build.")
                    .foregroundStyle(.orange)
            case .signedIn:
                EmptyView()
            }
        }
    }

    private func row(for item: PhoneLibrary.ReviewItem) -> some View {
        NavigationLink {
            MemoDetailView(item: item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let transcript = item.transcript {
                    Text(transcript.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                } else {
                    Text(processingDescription(for: item.uploadState))
                        .font(.body)
                        .foregroundStyle(item.uploadState == .failed ? .orange : .secondary)
                }
                Text(item.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func processingDescription(for state: PhoneLibrary.UploadState) -> String {
        switch state {
        case .pending:
            library.uploadsAreAuthorized
                ? "Processing…"
                : "Connect Google to transcribe"
        case .uploading, .uploaded:
            "Processing…"
        case .failed:
            "Needs attention"
        }
    }
}

private struct MemoDetailView: View {

    @Environment(PhoneLibrary.self) private var library

    let item: PhoneLibrary.ReviewItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(item.recordedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let transcript = item.transcript {
                    Text(transcript.text)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    ContentUnavailableView(
                        processingTitle,
                        systemImage: item.uploadState == .failed ? "exclamationmark.triangle" : "ellipsis",
                        description: Text(processingDescription)
                    )
                    if let localMemo = item.localMemo, localMemo.uploadState == .failed {
                        Button("Retry") {
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
                            library.playingID == item.id ? "Stop Playback" : "Play Original Recording",
                            systemImage: library.playingID == item.id ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Original audio no longer available")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if item.transcript != nil, item.hasSourceAudio {
                    Text("Transcripts can contain mistakes. Check the original when exact wording matters.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Thought")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var processingTitle: String {
        if item.uploadState == .pending && !library.uploadsAreAuthorized {
            return "Connect Google"
        }
        return item.uploadState == .failed ? "Needs Attention" : "Processing"
    }

    private var processingDescription: String {
        switch item.uploadState {
        case .pending:
            library.uploadsAreAuthorized
                ? "Your recording is safe and will continue automatically."
                : "Your recording is safe on this iPhone."
        case .uploading, .uploaded:
            "Your recording is safe and will continue automatically."
        case .failed:
            "Your recording is safe on this iPhone. Retry when you’re ready."
        }
    }
}
