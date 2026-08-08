import Foundation
import GoogleSignIn
import UIKit

/// The phone's only interactive setup step. The Watch never sees authentication
/// UI and capture never waits for a network or identity provider.
@MainActor
@Observable
final class GoogleAuthentication {

    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(email: String)
        case unavailable
        case failed
    }

    enum AuthenticationError: Error {
        case configurationMissing
        case signedOut
        case tokenMissing
    }

    private(set) var state: State
    /// Google's stable account identifier (`sub`). Audio-upload consent is
    /// bound to this value, never to a mutable email address.
    private(set) var accountIdentifier: String?
    private let log = SharedConfig.logger("GoogleAuth")
    private let clientID: String?
    private let serverClientID: String?

    init(bundle: Bundle = .main) {
        clientID = Self.configurationValue("GIDClientID", in: bundle)
        serverClientID = Self.configurationValue("GIDServerClientID", in: bundle)
        accountIdentifier = nil
        state = clientID == nil || serverClientID == nil ? .unavailable : .restoring

        if let clientID, let serverClientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                clientID: clientID,
                serverClientID: serverClientID
            )
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    func restore() async {
        guard clientID != nil, serverClientID != nil else {
            state = .unavailable
            return
        }
        state = .restoring
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            accept(user)
        } catch {
            accountIdentifier = nil
            state = .signedOut
            log.info("No restorable Google session")
        }
    }

    func signIn() async {
        guard clientID != nil, serverClientID != nil else {
            state = .unavailable
            return
        }
        guard let presenter = Self.presentingViewController() else {
            state = .failed
            log.error("Could not present Google Sign-In")
            return
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            accept(result.user)
        } catch {
            accountIdentifier = nil
            state = .signedOut
            log.info("Google Sign-In did not complete")
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        accountIdentifier = nil
        state = .signedOut
    }

    /// Returns a fresh backend-audience ID token. GoogleSignIn keeps its refresh
    /// credential in the signed app's Keychain; the ID token itself is never
    /// persisted by WristMemo.
    func idToken() async throws -> String {
        guard clientID != nil, serverClientID != nil else {
            throw AuthenticationError.configurationMissing
        }

        let user: GIDGoogleUser
        if let current = GIDSignIn.sharedInstance.currentUser {
            user = current
        } else {
            do {
                user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            } catch {
                state = .signedOut
                throw AuthenticationError.signedOut
            }
        }

        let refreshed = try await user.refreshTokensIfNeeded()
        accept(refreshed)
        guard accountIdentifier != nil,
              let token = refreshed.idToken?.tokenString,
              !token.isEmpty
        else {
            throw AuthenticationError.tokenMissing
        }
        return token
    }

    private func accept(_ user: GIDGoogleUser) {
        guard let accountIdentifier = user.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountIdentifier.isEmpty
        else {
            self.accountIdentifier = nil
            state = .failed
            log.error("Google session did not contain a stable account identifier")
            return
        }
        let email = user.profile?.email ?? "Google account"
        self.accountIdentifier = accountIdentifier
        state = .signedIn(email: email)
    }

    private static func configurationValue(_ key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var presenter = root
        while let presented = presenter?.presentedViewController { presenter = presented }
        return presenter
    }
}
