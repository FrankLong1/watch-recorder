import SwiftUI

struct HomeView: View {

    @Environment(RecorderModel.self) private var model

    var body: some View {
        NavigationStack {
            // A List rather than a ScrollView: swipe-to-delete only works in
            // List, and it brings the crown scrolling behaviour watchOS users
            // expect for free.
            List {
                Section {
                    recordButton
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if model.recoveredCount > 0 {
                    Label(
                        "^[\(model.recoveredCount) recovered memo](inflect: true)",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
                }

                if model.store.memos.isEmpty {
                    Text("Press the Action button to start a memo.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(model.store.memos) { memo in
                        MemoRow(memo: memo)
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.delete(memo)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .navigationTitle("WristMemo")
        }
    }

    private var recordButton: some View {
        Button {
            Task { await model.startRecording() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text("Record")
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.red, in: .rect(cornerRadius: 22))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct MemoRow: View {
    let memo: Memo

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(memo.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 15, weight: .medium))
                Text(memo.createdAt, format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(memo.duration.memoClock)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            syncBadge
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var syncBadge: some View {
        switch memo.syncState {
        case .synced:
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .accessibilityLabel("Synced to iPhone")
        case .transferring:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .accessibilityLabel("Syncing")
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting to sync")
        }
    }
}
