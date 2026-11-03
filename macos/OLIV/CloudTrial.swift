// Dictate right away while the on-device models download, through the OLIV
// server's free trial (issue #19).
//
// A fresh install fetches about 5 GB of models before OLIV can type a word. A
// release build that names a server (OLIVDefaultAPIURL, baked in by
// scripts/release.sh) can offer that server's free trial for the wait:
// `POST /try/key` (server/docs/PUBLIC-API.md#free-trial) issues a short-lived,
// low-limit key. Source builds name no server and never show the offer.
//
// What keeps "local by default" true:
//   • Opt-in only. Nothing is requested or sent until the user turns it on.
//   • Only while the selected on-device engine's models download. When they
//     are ready, dictation returns to this Mac and the user is told once. A
//     download that stops (failed, or the app quit) ends the trial as well, so
//     nobody is left on the cloud without knowing it.
//   • Never over the user's own choice: with OLIV API or Groq selected, the
//     trial is not used, and the user's settings are never touched.
//   • Audio only. The trial key never syncs the Dictionary and its requests
//     carry no Dictionary words: the server profile behind a trial key is not
//     the user's.
//
// The key lives in Keychain under its own account; its issuer and expiry in
// UserDefaults. A trial that stopped can start again with the same key, so it
// doesn't spend another sign-up (each network gets only a couple a day).

import Foundation

/// A key from `POST /try/key`.
struct TrialGrant: Equatable {
    let token: String
    let expiresAt: Date
    var requestsPerMinute: Int?
    var dailyRequests: Int?
}

/// The trial issuer's refusals (server/vm/trial_keys.py).
enum TrialRefusal: Error, Equatable {
    /// This network already had today's keys.
    case clientLimit
    /// Today's keys for everyone are taken.
    case dailyLimit
    /// Too many trial keys are active.
    case full
    /// The server offers no trial, or the operator closed it.
    case closed
    /// The issuer can't issue right now.
    case unavailable

    init(status: Int, code: String?) {
        switch code {
        case "client_limit": self = .clientLimit
        case "daily_limit": self = .dailyLimit
        case "full": self = .full
        case "closed": self = .closed
        case "unavailable", "expired": self = .unavailable
        default:
            // A 404 is a server without the trial; anything else unexpected
            // reads as "not now", never as success.
            switch status {
            case 404: self = .closed
            case 429: self = .full
            default: self = .unavailable
            }
        }
    }
}

/// What the HUD tells the user, once, when the trial hands dictation back.
struct TrialAnnouncement: Equatable {
    let text: String
    let systemImage: String
}

/// `POST /try/key`, unauthenticated (no key exists yet). Same hygiene as the
/// API transport: ephemeral session, no redirects, bounded reply.
enum TrialKeyClient {
    static let maximumResponseBytes = 4_096
    static let timeout: TimeInterval = 30

    private struct Reply: Decodable {
        let ok: Bool?
        let token: String?
        let expires_at: Double?
        let requests_per_minute: Int?
        let daily_requests: Int?
        let error: String?
    }

    static func requestKey(baseURL: String, now: Date = Date()) async throws -> TrialGrant {
        // The placeholder only lets the shared validation check the address.
        let base = try OLIVAPIConfiguration(url: baseURL, apiKey: "trial-request")
        var request = URLRequest(url: base.baseURL.appendingPathComponent("try/key"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oliv-macos/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                         as? String ?? "dev"), forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, received) = try await session.bytes(for: request, delegate: RejectTrialRedirects.shared)
            response = received
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { throw OLIVAPIError.responseTooLarge }
                data.append(byte)
            }
        } catch let error as OLIVAPIError {
            throw error
        } catch is CancellationError {
            throw OLIVAPIError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw OLIVAPIError.cancelled
            case .timedOut: throw OLIVAPIError.timeout
            default: throw OLIVAPIError.network
            }
        } catch {
            throw OLIVAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw OLIVAPIError.invalidReply }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        switch http.statusCode {
        case 200: break
        case 300...399: throw OLIVAPIError.redirect
        case 404, 429, 503: throw TrialRefusal(status: http.statusCode, code: reply?.error)
        default: throw OLIVAPIError.http(http.statusCode)
        }
        guard let reply, reply.ok == true, let token = reply.token,
              let expiry = reply.expires_at, expiry.isFinite,
              Date(timeIntervalSince1970: expiry) > now,
              let checked = try? OLIVAPIConfiguration(url: baseURL, apiKey: token) else {
            throw OLIVAPIError.invalidReply
        }
        return TrialGrant(token: checked.apiKey, expiresAt: Date(timeIntervalSince1970: expiry),
                          requestsPerMinute: reply.requests_per_minute, dailyRequests: reply.daily_requests)
    }
}

private final class RejectTrialRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RejectTrialRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The 3xx itself becomes the reply, and is refused.
        completionHandler(nil)
    }
}

@MainActor
final class CloudTrial: ObservableObject {
    /// Never a user setting: only what dictation uses while the trial is on.
    nonisolated static let engineID = "oliv-trial"
    nonisolated static let recordKey = "oliv.trial"

    enum Phase: Equatable { case off, starting, on }

    /// Why the trial is off, for onboarding and Settings to explain.
    enum Note: Equatable {
        case refused(TrialRefusal)
        /// The server couldn't be reached.
        case unreachable
        /// Anything else: a bad reply, or the key couldn't be saved.
        case failed
        /// The download stopped before the models were ready.
        case downloadStopped
        /// The key expired or the server no longer accepts it.
        case ended
    }

    /// The stored key's issuer and limits. The key itself is in Keychain.
    struct Record: Codable, Equatable {
        let issuer: String
        let expiresAt: Date
        var requestsPerMinute: Int?
        var dailyRequests: Int?
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var note: Note?
    @Published private(set) var record: Record?

    /// The server this build names; "" in source builds, which never offer it.
    let serverURL: String
    /// After the user starts or stops the trial, or the server rejects its key.
    var onChange: (() -> Void)?

    private let keychain: KeychainStoring
    private let defaults: UserDefaults
    private let now: () -> Date
    private let requestKey: (String) async throws -> TrialGrant
    private var token: String?

    init(serverURL: String = OLIVAPIConfiguration.defaultURL,
         keychain: KeychainStoring = KeychainStore.shared,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         requestKey: @escaping (String) async throws -> TrialGrant = { try await TrialKeyClient.requestKey(baseURL: $0) }) {
        self.serverURL = serverURL
        self.keychain = keychain
        self.defaults = defaults
        self.now = now
        self.requestKey = requestKey
        if let data = defaults.data(forKey: Self.recordKey),
           let saved = try? JSONDecoder().decode(Record.self, from: data) {
            record = saved
            token = keychain.string(forAccount: KeychainStore.olivTrialAccount)
        }
        // Expired, from another server, or half-saved: nothing to keep.
        if !hasUsableKey, record != nil || defaults.object(forKey: Self.recordKey) != nil {
            forgetKey()
        }
    }

    nonisolated static func isLocal(_ engineID: String) -> Bool {
        OLIVSettings.Engine.local.contains { $0.id == engineID }
    }

    /// This build names a server the app would accept.
    var isAvailable: Bool {
        (try? OLIVAPIConfiguration(url: serverURL, apiKey: "trial-request")) != nil
    }

    /// Offer the trial: a named server, an on-device engine selected, and its
    /// models not on this Mac yet.
    func isOffered(selectedEngine: String, modelsReady: Bool) -> Bool {
        isAvailable && !modelsReady && Self.isLocal(selectedEngine)
    }

    private var hasUsableKey: Bool {
        guard let record, let token, record.issuer == serverURL, record.expiresAt > now() else { return false }
        return (try? OLIVAPIConfiguration(url: record.issuer, apiKey: token)) != nil
    }

    /// The trial's server and key while it is on and the key still valid.
    var configuration: OLIVAPIConfiguration? {
        guard phase == .on, hasUsableKey, let record, let token else { return nil }
        return try? OLIVAPIConfiguration(url: record.issuer, apiKey: token)
    }

    /// What dictation uses: the trial only in place of an on-device engine
    /// whose models aren't ready; any other selection stands as it is.
    func effectiveEngine(selected: String, modelsReady: Bool) -> String {
        guard !modelsReady, Self.isLocal(selected), configuration != nil else { return selected }
        return Self.engineID
    }

    /// The user opted in. A stored key that is still valid is used again;
    /// otherwise the server is asked for one.
    func start() async {
        guard phase == .off, isAvailable else { return }
        note = nil
        if hasUsableKey {
            phase = .on
            onChange?()
            return
        }
        phase = .starting
        let result: Result<TrialGrant, Error>
        do {
            result = .success(try await requestKey(serverURL))
        } catch {
            result = .failure(error)
        }
        // Stopped while waiting: keep a key that arrived for next time, but
        // don't use it now.
        let wanted = phase == .starting
        switch result {
        case .success(let grant):
            if save(grant) {
                if wanted { phase = .on }
            } else {
                note = .failed
                phase = .off
            }
        case .failure(let error):
            if wanted { note = Self.note(for: error) }
            phase = .off
        }
        onChange?()
    }

    /// The user turned it off. The key stays for a later restart.
    func stop() {
        guard phase != .off else { return }
        phase = .off
        note = nil
        onChange?()
    }

    /// A dictation got 401: the key expired or was revoked.
    func keyRejected() {
        forgetKey()
        if phase != .off { phase = .off }
        note = .ended
        onChange?()
    }

    /// Follow the selection and the download. Returns what to tell the user
    /// when the trial just ended on its own, nil otherwise.
    func reconcile(selectedEngine: String, modelsReady: Bool, downloading: Bool) -> TrialAnnouncement? {
        guard phase == .on else { return nil }
        if !Self.isLocal(selectedEngine) {
            // The user chose a cloud engine themselves: theirs wins, quietly.
            phase = .off
            return nil
        }
        if modelsReady {
            forgetKey()
            phase = .off
            note = nil
            return TrialAnnouncement(text: "Models ready — dictating on this Mac again",
                                     systemImage: "desktopcomputer")
        }
        if !hasUsableKey {
            forgetKey()
            phase = .off
            note = .ended
            return TrialAnnouncement(text: "Free trial ended — wait for the download to finish",
                                     systemImage: "exclamationmark.triangle.fill")
        }
        if !downloading {
            phase = .off
            note = .downloadStopped
            return TrialAnnouncement(text: "Download stopped — the OLIV server trial is off",
                                     systemImage: "exclamationmark.triangle.fill")
        }
        return nil
    }

    // MARK: Errors

    static func note(for error: Error) -> Note {
        switch error {
        case let refusal as TrialRefusal: return .refused(refusal)
        case OLIVAPIError.network, OLIVAPIError.timeout: return .unreachable
        default: return .failed
        }
    }

    /// The server no longer accepts the key. A 403 can come from the edge
    /// (Cloudflare), so only 401 ends the trial.
    nonisolated static func rejectsKey(_ error: Error) -> Bool {
        if case OLIVAPIError.http(401) = error { return true }
        return false
    }

    /// The HUD line for a trial dictation that failed.
    nonisolated static func notice(for error: Error) -> String? {
        switch error {
        case OLIVAPIError.http(401):
            return "Free trial ended — wait for the download to finish"
        case OLIVAPIError.http(403):
            return "The OLIV server refused the trial — wait for the download"
        case OLIVAPIError.http(429):
            return "Free-trial limit reached — wait, or let the download finish"
        case OLIVAPIError.cooldown(let seconds):
            return "Free-trial limit — wait \(Int(ceil(seconds))) s, or for the download"
        default:
            return (error as? OLIVAPIError)?.errorDescription
        }
    }

    // MARK: Storage

    /// Issuer first, then the key: a key never sits in Keychain without its
    /// issuer. Read back, so a Keychain that refused the write is noticed.
    private func save(_ grant: TrialGrant) -> Bool {
        let saved = Record(issuer: serverURL, expiresAt: grant.expiresAt,
                           requestsPerMinute: grant.requestsPerMinute, dailyRequests: grant.dailyRequests)
        guard let data = try? JSONEncoder().encode(saved) else { return false }
        defaults.set(data, forKey: Self.recordKey)
        keychain.set(grant.token, forAccount: KeychainStore.olivTrialAccount)
        guard keychain.string(forAccount: KeychainStore.olivTrialAccount) == grant.token else {
            forgetKey()
            return false
        }
        record = saved
        token = grant.token
        return true
    }

    /// Key first, then its issuer (the reverse of `save`).
    private func forgetKey() {
        keychain.set(nil, forAccount: KeychainStore.olivTrialAccount)
        defaults.removeObject(forKey: Self.recordKey)
        token = nil
        if record != nil { record = nil }
    }
}

/// Dictation through the trial key: the OLIV API client, with its own
/// cooldown, labelled as the trial, and never reporting the trial profile's
/// dictionary revision to the user's Dictionary sync.
struct CloudTrialProvider: DictationProviding {
    let client: OLIVAPIClient

    init(configuration: OLIVAPIConfiguration, state: OLIVAPIRequestState = .trial) {
        client = OLIVAPIClient(configuration: configuration, state: state)
    }

    func dictate(samples: [Float], options: DictationOptions) async throws -> DictationResult {
        var result = try await client.dictate(samples: samples, options: options)
        result.engineID = CloudTrial.engineID
        result.dictionaryRevision = nil
        return result
    }
}
