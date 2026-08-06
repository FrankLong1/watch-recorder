import SwiftUI

/// The companion app.
///
/// It exists for two reasons: `WCSession.transferFile` needs a counterpart to
/// deliver to, and a watch app that ships inside an iOS app is the only way to
/// distribute one that has a phone-side library. Recording itself never happens
/// here.
@main
struct WristMemoApp: App {

    @State private var library = PhoneLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .task { library.start() }
        }
    }
}
