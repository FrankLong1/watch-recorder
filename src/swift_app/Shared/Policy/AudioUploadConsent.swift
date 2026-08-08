import Foundation

/// Persists the one consequential phone-side decision separately from Google
/// authentication: which exact Google account may receive this phone's audio.
///
/// Google Sign-In credentials remain owned by GoogleSignIn in the Keychain.
/// This store contains only the stable Google account identifier that the user
/// explicitly approved for automatic transcription.
struct AudioUploadConsent {

    static let defaultStorageKey = "WristMemo.authorizedGoogleUploadAccount.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    var authorizedAccountID: String? {
        Self.normalized(defaults.string(forKey: storageKey))
    }

    func allows(accountID: String?) -> Bool {
        guard let accountID = Self.normalized(accountID) else { return false }
        return authorizedAccountID == accountID
    }

    /// Returns false rather than storing a missing or malformed identity. The
    /// caller must have a verified Google session before presenting approval.
    @discardableResult
    func grant(accountID: String?) -> Bool {
        guard let accountID = Self.normalized(accountID) else { return false }
        defaults.set(accountID, forKey: storageKey)
        return true
    }

    func revoke() {
        defaults.removeObject(forKey: storageKey)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
