// The opt-in free trial while the models download (CloudTrial, issue #19):
// offered only by a build that names a server, every refusal leaves it off
// with its own reason, the key goes to Keychain, dictation returns to this Mac
// when the models are ready, and a cloud engine the user chose always wins.
//
// Hermetic: throwaway UserDefaults suites, the in-memory Keychain (or a
// throwaway Keychain service), and the native loopback stub server
// (oliv-test-worker), never the live /try/key.

import XCTest
@testable import OLIV

@MainActor
final class CloudTrialTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let typhoon = OLIVSettings.Engine.typhoon.id
    private let week: TimeInterval = 7 * 86_400

    override func setUpWithError() throws {
        suite = "oliv.trial.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    /// A trial whose sign-up never touches the network.
    private func trial(serverURL: String = "https://oliv.example.com", keychain: KeychainStoring,
                       now: @escaping () -> Date = Date.init,
                       requests: (() -> Void)? = nil) -> CloudTrial {
        CloudTrial(serverURL: serverURL, keychain: keychain, defaults: defaults, now: now, requestKey: { _ in
            requests?()
            return TrialGrant(token: "trial-dummy", expiresAt: now().addingTimeInterval(7 * 86_400),
                              requestsPerMinute: 6, dailyRequests: 60)
        })
    }

    private func counts(_ server: LoopbackAPIServer) async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: server.url + "/counts")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Int]
    }

    // MARK: The offer

    func testOfferedOnlyByABuildThatNamesAServer() {
        let keychain = InMemoryKeychain()
        // Source builds bake no URL (this test host is one).
        XCTAssertEqual(OLIVAPIConfiguration.defaultURL, "")
        XCTAssertFalse(CloudTrial(keychain: keychain, defaults: defaults)
            .isOffered(selectedEngine: typhoon, modelsReady: false))
        XCTAssertFalse(trial(serverURL: "", keychain: keychain).isOffered(selectedEngine: typhoon, modelsReady: false))
        // A URL the app would refuse for the API is no offer either.
        XCTAssertFalse(trial(serverURL: "http://public.example.test", keychain: keychain)
            .isOffered(selectedEngine: typhoon, modelsReady: false))

        let baked = trial(keychain: keychain)
        XCTAssertTrue(baked.isOffered(selectedEngine: typhoon, modelsReady: false))
        XCTAssertTrue(baked.isOffered(selectedEngine: OLIVSettings.Engine.mlxLarge.id, modelsReady: false))
        XCTAssertFalse(baked.isOffered(selectedEngine: typhoon, modelsReady: true), "models ready: nothing to wait for")
        XCTAssertFalse(baked.isOffered(selectedEngine: OLIVSettings.Engine.olivAPI.id, modelsReady: false))
        XCTAssertFalse(baked.isOffered(selectedEngine: OLIVSettings.Engine.groq.id, modelsReady: false))
    }

    func testNothingIsUsedBeforeTheUserOptsIn() {
        let t = trial(keychain: InMemoryKeychain(), requests: { XCTFail("asked for a key without opt-in") })
        XCTAssertEqual(t.phase, .off)
        XCTAssertNil(t.configuration)
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
    }

    // MARK: Sign-up over the loopback stub

    func testKeyFromTheServerGoesToKeychainAndIsReusedAfterAStop() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let keychain = InMemoryKeychain()
        let t = CloudTrial(serverURL: server.url, keychain: keychain, defaults: defaults)
        XCTAssertTrue(t.isOffered(selectedEngine: typhoon, modelsReady: false))
        await t.start()
        XCTAssertEqual(t.phase, .on)
        XCTAssertNil(t.note)
        XCTAssertEqual(keychain.string(forAccount: KeychainStore.olivTrialAccount), "dummy")
        XCTAssertNil(keychain.string(forAccount: KeychainStore.olivAPIAccount), "the user's own API key is untouched")
        XCTAssertEqual(t.record?.requestsPerMinute, 6)
        XCTAssertEqual(t.record?.dailyRequests, 60)
        XCTAssertGreaterThan(t.record?.expiresAt ?? .distantPast, Date())
        let stored = String(decoding: defaults.data(forKey: CloudTrial.recordKey) ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.isEmpty)
        XCTAssertFalse(stored.contains("dummy"), "the key is in Keychain, never in UserDefaults")
        XCTAssertEqual(t.configuration?.apiKey, "dummy")
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), CloudTrial.engineID)

        // The download stops: off, said once, the key kept.
        let stopped = t.reconcile(selectedEngine: typhoon, modelsReady: false, downloading: false)
        XCTAssertEqual(stopped?.text, "Download stopped — the OLIV server trial is off")
        XCTAssertEqual(t.note, .downloadStopped)
        XCTAssertNil(t.reconcile(selectedEngine: typhoon, modelsReady: false, downloading: false))
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
        XCTAssertEqual(keychain.string(forAccount: KeychainStore.olivTrialAccount), "dummy")

        // Starting again, or after a relaunch, uses the same key: no second sign-up.
        await t.start()
        XCTAssertEqual(t.phase, .on)
        let relaunched = CloudTrial(serverURL: server.url, keychain: keychain, defaults: defaults)
        XCTAssertEqual(relaunched.phase, .off, "a relaunch never resumes sending on its own")
        await relaunched.start()
        XCTAssertEqual(relaunched.configuration?.apiKey, "dummy")
        let seen = try await counts(server)
        XCTAssertEqual(seen["trial_keys"], 1, "one POST /try/key with the app's User-Agent")
    }

    func testEachRefusalLeavesTheTrialOffWithItsOwnReason() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let refusals: [(String, TrialRefusal)] = [("client_limit", .clientLimit), ("daily_limit", .dailyLimit),
                                                  ("full", .full), ("closed", .closed), ("unavailable", .unavailable)]
        for (code, refusal) in refusals {
            let keychain = InMemoryKeychain()
            let t = CloudTrial(serverURL: server.url + "/refuse/" + code, keychain: keychain, defaults: defaults)
            await t.start()
            XCTAssertEqual(t.phase, .off, code)
            XCTAssertEqual(t.note, .refused(refusal), code)
            XCTAssertNil(t.configuration, code)
            XCTAssertNil(keychain.string(forAccount: KeychainStore.olivTrialAccount), code)
            XCTAssertNil(defaults.data(forKey: CloudTrial.recordKey), code)
            // Back to waiting for the download, and still offered.
            XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon, code)
            XCTAssertTrue(t.isOffered(selectedEngine: typhoon, modelsReady: false), code)
        }
        // A server without the trial (404) reads as closed.
        let none = CloudTrial(serverURL: server.url + "/no-trial", keychain: InMemoryKeychain(), defaults: defaults)
        await none.start()
        XCTAssertEqual(none.note, .refused(.closed))
        let seen = try await counts(server)
        XCTAssertEqual(seen["trial_refusals"], 5)
        XCTAssertEqual(seen["trial_keys"], 0)
    }

    func testRefusalCodesAndStatusesMapLikeTheIssuer() {
        XCTAssertEqual(TrialRefusal(status: 429, code: "client_limit"), .clientLimit)
        XCTAssertEqual(TrialRefusal(status: 429, code: "daily_limit"), .dailyLimit)
        XCTAssertEqual(TrialRefusal(status: 429, code: "full"), .full)
        XCTAssertEqual(TrialRefusal(status: 503, code: "closed"), .closed)
        XCTAssertEqual(TrialRefusal(status: 503, code: "unavailable"), .unavailable)
        XCTAssertEqual(TrialRefusal(status: 503, code: "expired"), .unavailable)
        XCTAssertEqual(TrialRefusal(status: 404, code: nil), .closed)
        XCTAssertEqual(TrialRefusal(status: 429, code: nil), .full)
        XCTAssertEqual(TrialRefusal(status: 503, code: "something-new"), .unavailable)
        XCTAssertEqual(CloudTrial.note(for: OLIVAPIError.network), .unreachable)
        XCTAssertEqual(CloudTrial.note(for: OLIVAPIError.timeout), .unreachable)
        XCTAssertEqual(CloudTrial.note(for: OLIVAPIError.invalidReply), .failed)
    }

    func testSignUpRedirectIsRefused() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let keychain = InMemoryKeychain()
        let t = CloudTrial(serverURL: server.url + "/redirect/302", keychain: keychain, defaults: defaults)
        await t.start()
        XCTAssertEqual(t.phase, .off)
        XCTAssertEqual(t.note, .failed)
        XCTAssertNil(keychain.string(forAccount: KeychainStore.olivTrialAccount))
        let seen = try await counts(server)
        XCTAssertEqual(seen["redirects"], 1)
        XCTAssertEqual(seen["targets"], 0, "the redirect is not followed")
    }

    func testUnreachableServerSaysSo() async throws {
        // Port 9 (discard) on loopback: nothing listens there.
        let t = CloudTrial(serverURL: "http://127.0.0.1:9", keychain: InMemoryKeychain(), defaults: defaults)
        await t.start()
        XCTAssertEqual(t.phase, .off)
        XCTAssertEqual(t.note, .unreachable)
    }

    func testRealKeychainHoldsTheKeyUnderItsOwnAccount() async throws {
        let store = KeychainStore(service: "com.oliv.tests.\(UUID().uuidString)")
        defer {
            store.set(nil, forAccount: KeychainStore.olivTrialAccount)
            store.set(nil, forAccount: "probe")
        }
        store.set("probe-value", forAccount: "probe")
        guard store.string(forAccount: "probe") == "probe-value" else {
            throw XCTSkip("host keychain not writable in this test environment")
        }
        let t = trial(keychain: store)
        await t.start()
        XCTAssertEqual(t.phase, .on)
        XCTAssertEqual(store.string(forAccount: KeychainStore.olivTrialAccount), "trial-dummy")
        _ = t.reconcile(selectedEngine: typhoon, modelsReady: true, downloading: false)
        XCTAssertNil(store.string(forAccount: KeychainStore.olivTrialAccount))
    }

    // MARK: Switching back

    func testModelsReadySwitchesBackToThisMacOnceAndForgetsTheKey() async {
        let keychain = InMemoryKeychain()
        let t = trial(keychain: keychain)
        await t.start()
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), CloudTrial.engineID)
        XCTAssertNil(t.reconcile(selectedEngine: typhoon, modelsReady: false, downloading: true), "still downloading")
        XCTAssertEqual(t.phase, .on)

        let told = t.reconcile(selectedEngine: typhoon, modelsReady: true, downloading: false)
        XCTAssertEqual(told, TrialAnnouncement(text: "Models ready — dictating on this Mac again",
                                               systemImage: "desktopcomputer"))
        XCTAssertNil(t.reconcile(selectedEngine: typhoon, modelsReady: true, downloading: false), "said once")
        XCTAssertEqual(t.phase, .off)
        XCTAssertNil(t.note)
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: true), typhoon)
        // Even if models went missing again, the trial doesn't come back by itself.
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
        XCTAssertNil(keychain.string(forAccount: KeychainStore.olivTrialAccount))
        XCTAssertNil(defaults.data(forKey: CloudTrial.recordKey))
    }

    func testStoppedWhileTheKeyWasOnItsWaySendsNothing() async {
        let keychain = InMemoryKeychain()
        var t: CloudTrial!
        t = CloudTrial(serverURL: "https://oliv.example.com", keychain: keychain, defaults: defaults,
                       requestKey: { _ in
            await MainActor.run { t.stop() }
            return TrialGrant(token: "trial-dummy", expiresAt: Date().addingTimeInterval(7 * 86_400))
        })
        await t.start()
        XCTAssertEqual(t.phase, .off)
        XCTAssertNil(t.configuration)
        XCTAssertNil(t.note)
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
        XCTAssertEqual(keychain.string(forAccount: KeychainStore.olivTrialAccount), "trial-dummy",
                       "kept, so starting later doesn't spend another sign-up")
    }

    func testStopKeepsTheKeyAndSendsNothingMore() async {
        let keychain = InMemoryKeychain()
        let t = trial(keychain: keychain)
        await t.start()
        t.stop()
        XCTAssertEqual(t.phase, .off)
        XCTAssertNil(t.configuration)
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
        XCTAssertEqual(keychain.string(forAccount: KeychainStore.olivTrialAccount), "trial-dummy")
    }

    func testExpiredKeyIsNotUsedAndIsForgotten() async {
        var clock = Date()
        let keychain = InMemoryKeychain()
        let t = trial(keychain: keychain, now: { clock })
        await t.start()
        XCTAssertNotNil(t.configuration)
        clock = clock.addingTimeInterval(week + 1)
        XCTAssertNil(t.configuration, "an expired key is never sent")
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
        let told = t.reconcile(selectedEngine: typhoon, modelsReady: false, downloading: true)
        XCTAssertEqual(told?.text, "Free trial ended — wait for the download to finish")
        XCTAssertEqual(t.note, .ended)
        XCTAssertNil(keychain.string(forAccount: KeychainStore.olivTrialAccount))
        // A relaunch with an expired record cleans up too.
        let stale = Record(issuer: "https://oliv.example.com", expiresAt: clock.addingTimeInterval(-1))
        defaults.set(try? JSONEncoder().encode(stale), forKey: CloudTrial.recordKey)
        keychain.set("old", forAccount: KeychainStore.olivTrialAccount)
        _ = trial(keychain: keychain, now: { clock })
        XCTAssertNil(keychain.string(forAccount: KeychainStore.olivTrialAccount))
        XCTAssertNil(defaults.data(forKey: CloudTrial.recordKey))
    }

    func testKeyFromAnotherServerIsNotSentToThisOne() async {
        let keychain = InMemoryKeychain()
        let first = trial(serverURL: "https://one.example.com", keychain: keychain)
        await first.start()
        var asked = 0
        let second = trial(serverURL: "https://two.example.com", keychain: keychain, requests: { asked += 1 })
        XCTAssertNil(second.record)
        await second.start()
        XCTAssertEqual(asked, 1, "a new key from the new server")
        XCTAssertEqual(second.configuration?.baseURL.host, "two.example.com")
    }

    func testRejectedKeyEndsTheTrial() async {
        let keychain = InMemoryKeychain()
        let t = trial(keychain: keychain)
        await t.start()
        XCTAssertTrue(CloudTrial.rejectsKey(OLIVAPIError.http(401)))
        XCTAssertFalse(CloudTrial.rejectsKey(OLIVAPIError.http(403)), "a 403 can be the edge, not the key")
        XCTAssertFalse(CloudTrial.rejectsKey(OLIVAPIError.http(429)))
        t.keyRejected()
        XCTAssertEqual(t.phase, .off)
        XCTAssertEqual(t.note, .ended)
        XCTAssertNil(keychain.string(forAccount: KeychainStore.olivTrialAccount))
        XCTAssertEqual(t.effectiveEngine(selected: typhoon, modelsReady: false), typhoon)
    }

    // MARK: The user's own choice

    func testNeverOverridesACloudEngineTheUserChose() async {
        let keychain = InMemoryKeychain()
        let settings = OLIVSettings(defaults: defaults, keychain: keychain)
        settings.olivAPIURL = "https://mine.example.com"
        settings.olivAPIKey = "mine"
        settings.olivAPIEnabled = true
        settings.groqCloudEnabled = true
        settings.groqAPIKey = "groq-dummy"
        let t = trial(keychain: keychain)
        await t.start()
        for engine in [OLIVSettings.Engine.olivAPI.id, OLIVSettings.Engine.groq.id] {
            XCTAssertFalse(t.isOffered(selectedEngine: engine, modelsReady: false))
            XCTAssertEqual(t.effectiveEngine(selected: engine, modelsReady: false), engine)
            XCTAssertEqual(t.effectiveEngine(selected: engine, modelsReady: true), engine)
        }
        // Choosing one ends the trial quietly: no "back on this Mac" claim,
        // although no local models are required for OLIV API.
        settings.engineID = OLIVSettings.Engine.olivAPI.id
        XCTAssertTrue(settings.requiredModelRepos.isEmpty)
        XCTAssertNil(t.reconcile(selectedEngine: settings.engineID, modelsReady: true, downloading: true))
        XCTAssertEqual(t.phase, .off)
        XCTAssertEqual(settings.engineID, OLIVSettings.Engine.olivAPI.id)
        XCTAssertEqual(settings.olivAPIKey, "mine")
        XCTAssertEqual(settings.olivAPIConfiguration?.baseURL.host, "mine.example.com")
        XCTAssertEqual(keychain.string(forAccount: KeychainStore.olivTrialAccount), "trial-dummy",
                       "kept for later, in its own account")
    }

    func testTrialNeverBecomesTheDictionarySyncAccount() async {
        // The trial key lives outside the settings, so Dictionary sync (which
        // follows only the user's own OLIV API configuration) stays local.
        let keychain = InMemoryKeychain()
        let settings = OLIVSettings(defaults: defaults, keychain: keychain)
        settings.addDictionaryEntry(word: "Grafana", correction: nil)
        let t = trial(keychain: keychain)
        await t.start()
        XCTAssertEqual(t.phase, .on)
        XCTAssertNil(settings.olivAPIConfiguration)
        XCTAssertEqual(settings.engineID, typhoon, "the trial never becomes the selected engine")
        let server = FakeDictionaryServer()
        let sync = DictionarySync(defaults: defaults, autoSync: false, makeRemote: { _ in server })
        sync.attach(to: settings)
        await sync.syncNow()
        XCTAssertEqual(sync.status, .localOnly)
        XCTAssertTrue(server.calls.isEmpty, "nothing uploaded to any server profile")
    }

    // MARK: Dictation through the trial

    func testTrialDictationIsLabelledAndCarriesNoDictionary() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let state = OLIVAPIRequestState(defaults: defaults, deadlineKey: "trial-test")
        let configuration = try OLIVAPIConfiguration(url: server.url, apiKey: "dummy")
        let result = try await CloudTrialProvider(configuration: configuration, state: state)
            .dictate(samples: [0.25], options: DictationOptions(cleanup: false))
        XCTAssertEqual(result.final, "ไทย English")
        XCTAssertEqual(result.engineID, CloudTrial.engineID, "labelled as the trial, not as the user's OLIV API")
        XCTAssertNil(result.dictionaryRevision, "never reported to the user's Dictionary sync")
        let seen = try await counts(server)
        XCTAssertEqual(seen["valid_requests"], 1)

        // Routing: the trial uses only its own key.
        let sidecar = SidecarClient(command: ["/no/such/sidecar"])
        let own = try OLIVAPIConfiguration(url: "https://mine.example.com", apiKey: "mine")
        XCTAssertTrue(DictationController.provider(engine: CloudTrial.engineID, sidecar: sidecar,
                                                   apiConfiguration: own, trialConfiguration: configuration)
                      is CloudTrialProvider)
        XCTAssertNil(DictationController.provider(engine: CloudTrial.engineID, sidecar: sidecar,
                                                  apiConfiguration: own, trialConfiguration: nil))
        XCTAssertTrue(DictationController.provider(engine: OLIVAPIClient.engineID, sidecar: sidecar,
                                                   apiConfiguration: own, trialConfiguration: configuration)
                      is OLIVAPIClient)
        XCTAssertFalse(sidecar._isAliveForTests)
        XCTAssertEqual(DictationController.captureSeconds(for: CloudTrial.engineID), 120)

        // Audio only: no Dictionary words or snippets go with a trial request.
        let entries = [DictionaryEntry(word: "Grafana", correction: "กราฟาน่า")]
        let trialOptions = DictationController.dictationOptions(
            engine: CloudTrial.engineID, cleanup: true, removeFillers: true, entries: entries,
            legacySnippets: ["sig": "Regards"], serverAppliesDictionary: false, formatCommands: true, thaiFormat: true)
        XCTAssertTrue(trialOptions.vocabulary.isEmpty)
        XCTAssertTrue(trialOptions.replacements.isEmpty)
        XCTAssertTrue(trialOptions.dictionary.isEmpty)
        XCTAssertFalse(trialOptions.formatCommands)
        XCTAssertTrue(trialOptions.thaiFormat && trialOptions.removeFillers && trialOptions.cleanup)
        // The user's own OLIV API still gets derived hints, and local engines the entries.
        let apiOptions = DictationController.dictationOptions(
            engine: OLIVAPIClient.engineID, cleanup: true, removeFillers: true, entries: entries,
            legacySnippets: ["sig": "Regards"], serverAppliesDictionary: false, formatCommands: true, thaiFormat: true)
        XCTAssertFalse(apiOptions.vocabulary.isEmpty)
        XCTAssertEqual(apiOptions.replacements["sig"], "Regards")
        let localOptions = DictationController.dictationOptions(
            engine: typhoon, cleanup: true, removeFillers: true, entries: entries,
            legacySnippets: [:], serverAppliesDictionary: false, formatCommands: true, thaiFormat: true)
        XCTAssertEqual(localOptions.dictionary, entries)
        XCTAssertTrue(localOptions.formatCommands)
    }

    func testExpiredOrOverQuotaTrialKeySaysSoPlainly() async throws {
        let server = try LoopbackAPIServer()
        defer { server.close() }
        let state = OLIVAPIRequestState(defaults: defaults, deadlineKey: "trial-test")
        do {
            _ = try await CloudTrialProvider(configuration: try OLIVAPIConfiguration(url: server.url + "/expired",
                                                                                      apiKey: "dummy"), state: state)
                .dictate(samples: [0.25], options: DictationOptions(cleanup: false))
            XCTFail("an expired key dictated")
        } catch {
            XCTAssertTrue(CloudTrial.rejectsKey(error))
            XCTAssertEqual(CloudTrial.notice(for: error), "Free trial ended — wait for the download to finish")
        }
        do {
            _ = try await CloudTrialProvider(configuration: try OLIVAPIConfiguration(url: server.url + "/quota",
                                                                                      apiKey: "dummy"), state: state)
                .dictate(samples: [0.25], options: DictationOptions(cleanup: false))
            XCTFail("an over-quota key dictated")
        } catch {
            XCTAssertFalse(CloudTrial.rejectsKey(error), "a quota is a wait, not the end")
            XCTAssertEqual(CloudTrial.notice(for: error), "Free-trial limit reached — wait, or let the download finish")
        }
        // The quota's wait holds the trial only, never the user's own API key.
        XCTAssertNotNil(defaults.object(forKey: "trial-test"))
        XCTAssertNil(defaults.object(forKey: OLIVAPIRequestState.deadlineKey))
        do {
            try state.begin(now: Date())
            XCTFail("no cooldown after Retry-After")
        } catch {
            XCTAssertTrue(CloudTrial.notice(for: error)?.hasPrefix("Free-trial limit — wait ") == true)
        }
    }

    func testTrialThatEndsDuringAHoldNeverUploads() {
        let trialID = CloudTrial.engineID
        let api = OLIVSettings.Engine.olivAPI.id
        // Still on: the utterance stays on the trial it was recorded for.
        XCTAssertEqual(DictationController.releaseEngine(recorded: trialID, current: trialID, trialAvailable: true), trialID)
        // Ended (models ready, or stopped): the on-device engine takes it.
        XCTAssertEqual(DictationController.releaseEngine(recorded: trialID, current: typhoon, trialAvailable: false), typhoon)
        // Ended while the user picked a cloud engine: no provider, nothing sent.
        XCTAssertEqual(DictationController.releaseEngine(recorded: trialID, current: api, trialAvailable: false), trialID)
        XCTAssertNil(DictationController.provider(engine: trialID, sidecar: nil, apiConfiguration: nil))
        // Other engines are untouched.
        XCTAssertEqual(DictationController.releaseEngine(recorded: typhoon, current: trialID, trialAvailable: true), typhoon)
        XCTAssertEqual(DictationController.releaseEngine(recorded: api, current: typhoon, trialAvailable: false), api)
    }

    func testExpiredTrialKeyIsNeverUsedAtRelease() throws {
        let config = try OLIVAPIConfiguration(url: "https://oliv.example.com", apiKey: "trial-dummy")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usable = { (expiresIn: TimeInterval?) in
            DictationController.usableTrial(config, expiresAt: expiresIn.map { now.addingTimeInterval($0) }, now: now)
        }
        XCTAssertNotNil(usable(3600), "a key with time left is used")
        XCTAssertNil(usable(-1), "an expired key is not")
        XCTAssertNil(usable(DictationController.trialExpiryMargin), "nor one about to expire")
        XCTAssertNil(usable(nil), "nor one without a known expiry")
        XCTAssertNil(DictationController.usableTrial(nil, expiresAt: now.addingTimeInterval(3600), now: now))
        // With no usable trial, the trial utterance gets no provider: nothing is uploaded.
        XCTAssertEqual(DictationController.releaseEngine(recorded: CloudTrial.engineID, current: CloudTrial.engineID,
                                                         trialAvailable: false), CloudTrial.engineID)
        XCTAssertNil(DictationController.provider(engine: CloudTrial.engineID, sidecar: nil, apiConfiguration: nil,
                                                  trialConfiguration: usable(-1)))
    }

    func testTrialIsLabelledCloudEverywhere() {
        let execution = DictationExecution(engineID: CloudTrial.engineID)
        XCTAssertEqual(execution, .olivTrial)
        XCTAssertEqual(execution.label, "Cloud · OLIV free trial")
        XCTAssertEqual(execution.systemImage, "cloud")
        XCTAssertTrue(execution.detail.contains("sent to the OLIV server"))
        XCTAssertEqual(LastDictationStats(chars: 3, sttSeconds: 1, cleanupSeconds: 0, engineID: CloudTrial.engineID)
            .menuLine, "Last: Cloud · OLIV free trial · 1.0s · 3 chars")
    }

    private typealias Record = CloudTrial.Record
}
