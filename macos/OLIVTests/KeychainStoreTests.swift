// KeychainStore tests (W3-T4) — the secure home for the opt-in Groq API key.
//
// The round-trip is exercised through the InMemoryKeychain SEAM (the injectable
// backend) so these are fully hermetic and never touch the real login keychain
// (which an unsigned test host can't reliably write). A best-effort probe of the
// REAL KeychainStore runs too, but skips itself if the host denies keychain
// access rather than failing the suite.

import XCTest
@testable import OLIV

final class KeychainStoreTests: XCTestCase {

    // The seam round-trips: set → get → overwrite → delete (nil) → empty deletes.
    func testInMemorySeamRoundTrip() {
        let kc = InMemoryKeychain()
        XCTAssertNil(kc.groqAPIKey(), "absent key reads as nil")

        kc.setGroqAPIKey("gsk_live_abc123")
        XCTAssertEqual(kc.groqAPIKey(), "gsk_live_abc123")

        kc.setGroqAPIKey("gsk_live_xyz789")   // overwrite
        XCTAssertEqual(kc.groqAPIKey(), "gsk_live_xyz789")

        kc.setGroqAPIKey(nil)                  // delete
        XCTAssertNil(kc.groqAPIKey())

        kc.setGroqAPIKey("something")
        kc.setGroqAPIKey("")                   // empty == delete
        XCTAssertNil(kc.groqAPIKey(), "empty string clears the secret")
    }

    // Distinct accounts don't collide through the same store.
    func testSeamKeysAreAccountScoped() {
        let kc = InMemoryKeychain()
        kc.set("one", forAccount: "a")
        kc.set("two", forAccount: "b")
        XCTAssertEqual(kc.string(forAccount: "a"), "one")
        XCTAssertEqual(kc.string(forAccount: "b"), "two")
        kc.set(nil, forAccount: "a")
        XCTAssertNil(kc.string(forAccount: "a"))
        XCTAssertEqual(kc.string(forAccount: "b"), "two")
    }

    // Best-effort: the REAL Security-framework store round-trips under a throwaway
    // service so it can't clobber a real key. Skips (not fails) if the host denies
    // keychain access — the load-bearing coverage is the seam above.
    func testRealKeychainRoundTripBestEffort() throws {
        let service = "com.oliv.tests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        let account = "probe"

        store.set("secret-value", forAccount: account)
        guard store.string(forAccount: account) == "secret-value" else {
            throw XCTSkip("host keychain not writable in this test environment")
        }
        store.set(nil, forAccount: account)   // cleanup + delete assertion
        XCTAssertNil(store.string(forAccount: account))
    }
}
