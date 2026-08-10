import SwiftUI

@main
struct WristMemoWatchApp: App {

    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    /// Touching the singleton here runs `RecorderModel.init`, which is where a
    /// launch triggered by the Action button claims its request and opens the
    /// microphone. This is the earliest hook the app has — waiting for a view's
    /// `.task` would cost a whole frame before the recorder even starts.
    @State private var model = RecorderModel.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}
