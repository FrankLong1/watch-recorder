import SwiftUI
import WidgetKit

/// A watch-face complication that starts a memo.
///
/// It exists as much for latency as for convenience. Apple's guidance is that a
/// complication on the active face tells the system to keep the owning app in a
/// ready-to-launch state — the system tries to keep it resident in memory. A
/// resident app turns the Action button press into a warm launch, which is the
/// single largest lever on press-to-record time. See LATENCY.md.
///
/// It also gives a second one-tap entry point that does not need an Ultra.
struct RecordComplication: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedConfig.complicationKind, provider: Provider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Button(intent: StartRecordingIntent()) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Your Agents")
        .description("Speak an instruction to your persistent agents from the watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

extension RecordComplication {

    struct Entry: TimelineEntry {
        let date: Date
    }

    /// Nothing changes over time, so the timeline is a single never-expiring
    /// entry. Cheap timelines matter: a complication that constantly reloads
    /// costs the background budget that keeps the app warm.
    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: .now)
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: .now))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now)], policy: .never))
        }
    }
}
