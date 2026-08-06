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
                        .accessibilityIdentifier(AccessibilityID.emptyHint)
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
            .accessibilityIdentifier(AccessibilityID.memoList)
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
        .accessibilityIdentifier(AccessibilityID.recordButton)
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

    private var syncBadge: some View {
        let (symbol, tint, label): (String, Color, String) = switch memo.syncState {
        case .synced:       ("iphone", .green, "Synced to iPhone")
        case .transferring: ("arrow.triangle.2.circlepath", .blue, "Syncing")
        case .pending:      ("clock", .secondary, "Waiting to sync")
        }
        return Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }
}
