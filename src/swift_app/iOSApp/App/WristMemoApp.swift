import SwiftUI
import UIKit
import GoogleSignIn

final class WristMemoAppDelegate: NSObject, UIApplicationDelegate {
    private var backgroundSessionCompletionHandler: (() -> Void)?
    private let authLog = SharedConfig.logger("GoogleAuth")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if !targetEnvironment(simulator)
        // Google OAuth App Check uses the production App Attest entitlement to
        // prove this signed iPhone app before Google issues OAuth/ID tokens.
        // Capture remains entirely independent of this asynchronous warm-up.
        GIDSignIn.sharedInstance.configure { [authLog] error in
            if let error {
                authLog.error("Google App Check setup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == TranscriptionClient.sessionIdentifier else {
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

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
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
    @State private var authentication = GoogleAuthentication()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(authentication)
                .task {
                    library.start(
                        authentication: authentication,
                        onBackgroundEventsFinished: appDelegate.finishBackgroundSessionEvents
                    )
                    await authentication.restore()
                    library.authenticationDidChange()
                }
        }
        // The system relaunches the app when a background upload finishes while
        // it is not running. Without this the transfer completes but its
        // delegate callback is never delivered, so the memo would stay marked
        // as uploading and be sent again.
        .backgroundTask(.urlSession(TranscriptionClient.sessionIdentifier)) { }
    }
}
