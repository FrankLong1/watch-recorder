import SwiftUI

/// There is one screen, so this is only a place to hang `bootstrap`.
///
/// It used to route on phase and permission. Both branches are gone: the
/// recording state is a colour rather than a different view, and an
/// undetermined microphone is handled by the first press, which is where a
/// permission prompt belongs anyway. A denied microphone is the one thing the
/// screen has to say in words, and `RecordScreen` says it.
struct RootView: View {

    @Environment(RecorderModel.self) private var model

    var body: some View {
        RecordScreen()
            .task { await model.bootstrap() }
    }
}
