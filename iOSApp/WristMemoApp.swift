import SwiftUI
import UIKit

final class WristMemoAppDelegate: NSObject, UIApplicationDelegate {
    private var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == "com.franklong.wristmemo.ingest" else {
            completionHandler()
            return
        }
        backgroundSessionCompletionHandler = completionHandler
    }

    func finishBackgroundSessionEvents() {
        let completionHandler = backgroundSessionCompletionHandler
        backgroundSessionCompletionHandler = nil
        completionHandler?()
    }
}

/// The companion app.
///
/// It exists for two reasons: `WCSession.transferFile` needs a counterpart to
/// deliver to, and a watch app that ships inside an iOS app is the only way to
/// distribute one that has a phone-side library. Recording itself never happens
/// here.
@main
struct WristMemoApp: App {

    @UIApplicationDelegateAdaptor(WristMemoAppDelegate.self) private var appDelegate
    @State private var library = PhoneLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .task {
                    library.start(onBackgroundEventsFinished: appDelegate.finishBackgroundSessionEvents)
                }
        }
        // The system relaunches the app when a background upload finishes while
        // it is not running. Without this the transfer completes but its
        // delegate callback is never delivered, so the memo would stay marked
        // as uploading and be sent again.
        .backgroundTask(.urlSession(TranscriptionClient.sessionIdentifier)) { }
    }
}
