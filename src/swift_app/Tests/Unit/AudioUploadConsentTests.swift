import Foundation
import Testing

@Suite("Audio upload consent")
struct AudioUploadConsentTests {

    @Test("sign-in alone never authorizes audio upload")
    func defaultsToDenied() {
        withStore { store in
            #expect(store.authorizedAccountID == nil)
            #expect(!store.allows(accountID: "google-subject-a"))
        }
    }

    @Test("approval is durable and bound to one exact Google account")
    func accountBoundPersistence() {
        withStore { store, defaults, key in
            #expect(store.grant(accountID: " google-subject-a "))

            let restored = AudioUploadConsent(defaults: defaults, storageKey: key)
            #expect(restored.authorizedAccountID == "google-subject-a")
            #expect(restored.allows(accountID: "google-subject-a"))
            #expect(!restored.allows(accountID: "google-subject-b"))
            #expect(!restored.allows(accountID: nil))
        }
    }

    @Test("empty identities cannot be approved")
    func rejectsEmptyIdentity() {
        withStore { store in
            #expect(!store.grant(accountID: nil))
            #expect(!store.grant(accountID: "   "))
            #expect(store.authorizedAccountID == nil)
        }
    }

    @Test("sign-out revokes the durable authorization")
    func revoke() {
        withStore { store, defaults, key in
            #expect(store.grant(accountID: "google-subject-a"))
            store.revoke()

            let restored = AudioUploadConsent(defaults: defaults, storageKey: key)
            #expect(restored.authorizedAccountID == nil)
            #expect(!restored.allows(accountID: "google-subject-a"))
        }
    }

    private func withStore(_ body: (AudioUploadConsent) -> Void) {
        withStore { store, _, _ in body(store) }
    }

    private func withStore(
        _ body: (AudioUploadConsent, UserDefaults, String) -> Void
    ) {
        let suiteName = "WristMemoTests.AudioUploadConsent.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "authorized-account"
        body(AudioUploadConsent(defaults: defaults, storageKey: key), defaults, key)
    }
}
