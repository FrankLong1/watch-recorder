import SwiftUI

struct LibraryView: View {

    @Environment(PhoneLibrary.self) private var library

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView(
                        "No Memos Yet",
                        systemImage: "mic",
                        description: Text("Memos recorded on your Apple Watch appear here once it syncs, and are removed a day after they are transcribed.")
                    )
                } else {
                    List {
                        ForEach(library.items) { item in
                            row(for: item)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if item.uploadState == .failed {
                                        Button("Retry") { library.retryUpload(item) }
                                            .tint(.blue)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("WristMemo")
        }
    }

    private func row(for item: PhoneLibrary.Item) -> some View {
        Button {
            library.play(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: library.playingID == item.id ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.body)
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
}

/// Whether a memo reached the transcription service.
///
/// Transcripts never come back to the phone, so without this the upload is
/// entirely unobservable from the device — a memo that never arrived looks
/// exactly like one that did. Every state gets a mark, so a missing badge is
/// never mistaken for success.
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
