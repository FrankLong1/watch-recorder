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
                        description: Text("Memos recorded on your Apple Watch appear here once it syncs.")
                    )
                } else {
                    List {
                        ForEach(library.items) { item in
                            row(for: item)
                        }
                        .onDelete { offsets in
                            offsets.map { library.items[$0] }.forEach(library.delete)
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
                    Text(item.receivedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.body)
                    Text(item.duration.memoDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

extension TimeInterval {
    var memoDuration: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
