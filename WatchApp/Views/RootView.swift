import SwiftUI

/// Routes on permission first, then on recording phase.
///
/// There is no `NavigationStack` push into the recording screen on purpose: a
/// push animates, and when the app is launched by the Action button the
/// recording UI needs to be the first thing drawn.
struct RootView: View {

    @Environment(RecorderModel.self) private var model

    var body: some View {
        Group {
            switch model.permission {
            case .undetermined:
                PermissionView(state: .ask)
            case .denied:
                PermissionView(state: .denied)
            case .granted:
                grantedContent
            }
        }
        .task { await model.bootstrap() }
    }

    @ViewBuilder
    private var grantedContent: some View {
        switch model.phase {
        case .starting, .recording, .paused:
            RecordingView()
        case .saving:
            SavingView()
        case .saved(let memo):
            SavedView(memo: memo)
        case .failed(let message):
            FailureView(message: message)
        case .idle:
            HomeView()
        }
    }
}
