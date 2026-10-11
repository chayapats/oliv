import Foundation
import Darwin

struct OLIVAPIConfiguration: Equatable, CustomDebugStringConvertible {
    static let defaultURL = "https://oliv.redcomp.tech"
    static let defaultTimeout: TimeInterval = 120
    let baseURL: URL
    let apiKey: String
    let timeout: TimeInterval

    var debugDescription: String { "OLIVAPIConfiguration(key: [redacted])" }

    init(url: String, apiKey: String, timeout: TimeInterval = defaultTimeout) throws {
        guard !url.contains("\\"),
              !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: url),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let rawHost = parts.host, !rawHost.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              url.lowercased().hasPrefix(scheme + "://") else { throw OLIVAPIError.invalidURL }
        parts.scheme = scheme
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = path
        guard let normalized = parts.url, let normalizedHost = normalized.host else { throw OLIVAPIError.invalidURL }
        // Foundation accepts malformed DNS labels; validate its IDNA-normalized
        // hostname before offering the provider in Settings.
        let host = normalizedHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard Self.validHost(host) else { throw OLIVAPIError.invalidURL }
        if scheme == "http", !Self.allowsHTTP(host) { throw OLIVAPIError.insecureURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw OLIVAPIError.invalidKey
        }
        guard timeout.isFinite, (10...180).contains(timeout), timeout.rounded() == timeout else {
            throw OLIVAPIError.invalidTimeout
        }
        self.baseURL = normalized
        self.apiKey = key
        self.timeout = timeout
    }

    private static func ipv6Address(_ host: String) -> in6_addr? {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1 ? address : nil
    }

    private static func validHost(_ host: String) -> Bool {
        if host.contains(":") { return ipv6Address(host) != nil }
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }

    private static func allowsHTTP(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if var address = ipv6Address(host) {
            return withUnsafeBytes(of: &address) { bytes in
                bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            }
        }
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let octets = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(field), (0...255).contains(n), String(n) == field else { return nil }
            return n
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 127 || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 100 && (64...127).contains(octets[1]))
    }
}

/// Client-owned messages only: never interpolate keys, URLs, bodies or NSError.
enum OLIVAPIError: Error, LocalizedError {
    case invalidURL, insecureURL, invalidKey, invalidTimeout, emptyAudio, audioTooLong
    case requestTooLarge, responseTooLarge, invalidReply, redirect, timeout, network, cancelled, busy
    case http(Int)
    case cooldown(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid API base URL without credentials, query or fragment."
        case .insecureURL: return "Use HTTPS. HTTP is allowed only for explicit local/private development addresses."
        case .invalidKey: return "Enter an individual API key without spaces."
        case .invalidTimeout: return "Request timeout must be 10–180 whole seconds."
        case .emptyAudio: return "No audio was captured."
        case .audioTooLong: return "OLIV API accepts recordings up to 2 minutes."
        case .requestTooLarge: return "The API request is too large. Shorten the recording or vocabulary/replacements."
        case .responseTooLarge: return "The API response exceeded the size limit."
        case .invalidReply: return "The API did not return a valid dictation result."
        case .redirect: return "API redirect rejected. Enter the final HTTPS base URL."
        case .timeout: return "The API request timed out. Wait before trying again."
        case .network: return "Could not reach the API. Check the connection, URL and TLS certificate."
        case .cancelled: return "The API request was cancelled."
        case .busy: return "An API dictation is already in progress."
        case .cooldown(let seconds): return "API cooldown — wait \(String(format: "%.0f", ceil(seconds))) seconds."
        case .http(401): return "API key invalid, expired or revoked. Update it in Settings."
        case .http(403): return "API access denied. Check key scope dictate or contact the administrator."
        case .http(400), .http(415): return "The API rejected the audio/request format."
        case .http(413): return "The API request is too large. Record a shorter clip."
        case .http(429): return "API key busy or quota exceeded. Wait before trying again."
        case .http(503): return "API temporarily unavailable. Wait before trying again."
        case .http(502), .http(504): return "The API could not finish transcription. Wait before trying again."
        case .http: return "The API request failed. Try again later."
        }
    }
}

/// Shared across provider instances/settings edits and persisted across relaunch.
/// Stores a deadline only; no credentials, audio or transcripts.
final class OLIVAPIRequestState {
    static let shared = OLIVAPIRequestState()
    static let deadlineKey = "oliv.api.retryAfter"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var busy = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func begin(now: Date) throws {
        lock.lock(); defer { lock.unlock() }
        let remaining = (defaults.object(forKey: Self.deadlineKey) as? Date)?.timeIntervalSince(now) ?? 0
        if remaining > 0 { throw OLIVAPIError.cooldown(remaining) }
        guard !busy else { throw OLIVAPIError.busy }
        busy = true
    }

    func end() { lock.lock(); busy = false; lock.unlock() }

    func postpone(until: Date) {
        lock.lock(); defer { lock.unlock() }
        let previous = defaults.object(forKey: Self.deadlineKey) as? Date ?? .distantPast
        defaults.set(max(previous, until), forKey: Self.deadlineKey)
    }
}

struct OLIVAPIHTTPReply {
    let response: HTTPURLResponse
    let data: Data
}

protocol OLIVAPITransport {
    func send(_ request: URLRequest, timeout: TimeInterval, limit: Int) async throws -> OLIVAPIHTTPReply
}

/// Default platform TLS verification, no cookie/credential/cache persistence,
/// no redirects, bounded response bytes and a deadline covering the whole request.
struct OLIVAPIURLSessionTransport: OLIVAPITransport {
    var protocolClasses: [AnyClass]? = nil  // URLProtocol seam for hermetic tests.

    func send(_ request: URLRequest, timeout: TimeInterval, limit: Int) async throws -> OLIVAPIHTTPReply {
        try await OLIVAPIRequestOperation().send(request, timeout: timeout, limit: limit,
                                                protocolClasses: protocolClasses)
    }
}

private final class OLIVAPIRequestOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OLIVAPIHTTPReply, Error>?
    private var result: Result<OLIVAPIHTTPReply, Error>?
    private var session: URLSession?
    private var deadline: DispatchWorkItem?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var limit = 0

    func send(_ request: URLRequest, timeout: TimeInterval, limit: Int,
              protocolClasses: [AnyClass]?) async throws -> OLIVAPIHTTPReply {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result = result {
                    lock.unlock(); continuation.resume(with: result); return
                }
                self.continuation = continuation
                self.limit = limit
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.httpShouldSetCookies = false
                if let classes = protocolClasses { configuration.protocolClasses = classes }
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(OLIVAPIError.timeout)) }
                self.deadline = deadline
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                task.resume()
            }
        }, onCancel: { self.finish(.failure(OLIVAPIError.cancelled)) })
    }

    private func finish(_ result: Result<OLIVAPIHTTPReply, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        let deadline = self.deadline
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(OLIVAPIError.redirect))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(OLIVAPIError.invalidReply)); return
        }
        lock.lock()
        self.response = response
        let oversized = response.expectedContentLength > Int64(limit)
        lock.unlock()
        // Status and Retry-After remain available even if an error page is huge
        // or never finishes streaming. No server error body is needed for UI.
        if response.statusCode != 200 {
            completionHandler(.cancel)
            finish(.success(OLIVAPIHTTPReply(response: response, data: Data())))
            return
        }
        completionHandler(oversized ? .cancel : .allow)
        if oversized { finish(.failure(OLIVAPIError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let oversized = data.count > limit - body.count
        if !oversized { body.append(data) }
        lock.unlock()
        if oversized { finish(.failure(OLIVAPIError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let failure: OLIVAPIError = (error as NSError).code == NSURLErrorTimedOut ? .timeout : .network
            finish(.failure(failure)); return
        }
        lock.lock()
        let response = self.response
        let body = self.body
        lock.unlock()
        guard let response = response else { finish(.failure(OLIVAPIError.invalidReply)); return }
        finish(.success(OLIVAPIHTTPReply(response: response, data: body)))
    }
}

final class OLIVAPIClient: DictationProviding {
    static let engineID = "oliv-api"
    static let maxCaptureSeconds: TimeInterval = 120
    static let maxSamples = 1_920_000
    static let maxRequestBytes = 8 * 1024 * 1024
    static let maxResponseBytes = 1024 * 1024
    private let configuration: OLIVAPIConfiguration
    private let transport: OLIVAPITransport?
    private let state: OLIVAPIRequestState
    private let now: () -> Date

    init(configuration: OLIVAPIConfiguration,
         transport: OLIVAPITransport? = nil,
         state: OLIVAPIRequestState = .shared, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.transport = transport
        self.state = state
        self.now = now
    }

    func dictate(samples: [Float], options: DictationOptions) async throws -> DictationResult {
        try Task.checkCancellation()
        if transport == nil {
            guard !samples.isEmpty else { throw OLIVAPIError.emptyAudio }
            guard samples.count <= Self.maxSamples else { throw OLIVAPIError.audioTooLong }
            try state.begin(now: now())
            defer { state.end() }
            var body = nativeRequest("api_dictate")
            body["pcm_b64"] = samples.withUnsafeBytes { Data($0).base64EncodedString() }
            body["cleanup"] = options.cleanup
            body["remove_fillers"] = options.removeFillers
            body["thai_format"] = options.thaiFormat && options.cleanup
            body["vocabulary"] = options.vocabulary
            body["replacements"] = options.replacements
            let reply = try await RustWorkerRequest().send(body, timeout: configuration.timeout)
            try checkNativeError(reply)
            return try Self.parseReply(status: 200, data: JSONSerialization.data(withJSONObject: reply))
        }
        let data = try Self.requestBody(samples: samples, options: options)
        try state.begin(now: now())
        defer { state.end() }
        let reply = try await transport!.send(request(path: "v1/dictate", body: data),
                                             timeout: configuration.timeout, limit: Self.maxResponseBytes)
        let status = reply.response.statusCode
        let header = reply.response.value(forHTTPHeaderField: "Retry-After")
        if status == 429 || (status >= 500 && header != nil) {
            let delay = Self.retryAfter(header, now: now())
            state.postpone(until: now().addingTimeInterval(delay))
        }
        return try Self.parseReply(status: status, data: reply.data)
    }

    /// Liveness only; never sends a key and never gates dictation.
    func health() async throws {
        if transport == nil {
            let reply = try await RustWorkerRequest().send(nativeRequest("api_health"), timeout: configuration.timeout)
            try checkNativeError(reply)
            return
        }
        let reply = try await transport!.send(request(path: "health", body: nil),
                                             timeout: configuration.timeout, limit: 8192)
        try Self.checkStatus(reply.response.statusCode)
        struct Health: Decodable { let ok: Bool }
        guard let value = try? JSONDecoder().decode(Health.self, from: reply.data), value.ok else {
            throw OLIVAPIError.invalidReply
        }
    }

    private func nativeRequest(_ command: String) -> [String: Any] {
        ["id": 1, "cmd": command, "api": [
            "url": configuration.baseURL.absoluteString, "key": configuration.apiKey,
            "timeout": configuration.timeout,
            "user_agent": "oliv-macos/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
        ]]
    }

    private func checkNativeError(_ reply: [String: Any]) throws {
        if let seconds = reply["retry_after"] as? Double, seconds.isFinite, seconds > 0 {
            state.postpone(until: now().addingTimeInterval(seconds))
        }
        guard reply["ok"] as? Bool == true else {
            if let status = reply["status"] as? Int { try Self.checkStatus(status) }
            switch reply["code"] as? String {
            case "timeout": throw OLIVAPIError.timeout
            case "network": throw OLIVAPIError.network
            case "redirect": throw OLIVAPIError.redirect
            case "responseTooLarge": throw OLIVAPIError.responseTooLarge
            case "requestTooLarge": throw OLIVAPIError.requestTooLarge
            case "audioTooLong": throw OLIVAPIError.audioTooLong
            case "emptyAudio": throw OLIVAPIError.emptyAudio
            default: throw OLIVAPIError.invalidReply
            }
        }
    }

    private func request(path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.timeoutInterval = configuration.timeout
        request.setValue("oliv-macos/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                         as? String ?? "dev"), forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.httpMethod = "POST"
            request.setValue("Bearer " + configuration.apiKey, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    static func requestBody(samples: [Float], options: DictationOptions) throws -> Data {
        let wav = try encodeWAV(samples)
        // Sorted keys give equal-length replacement ties a stable order; Mac
        // settings store a dictionary, unlike Linux's ordered TOML table.
        let data = try JSONSerialization.data(withJSONObject: [
            "wav_b64": wav.base64EncodedString(), "cleanup": options.cleanup,
            "remove_fillers": options.removeFillers, "thai_format": options.thaiFormat && options.cleanup,
            "vocabulary": options.vocabulary, "replacements": options.replacements,
        ], options: [.sortedKeys])
        guard data.count <= maxRequestBytes else { throw OLIVAPIError.requestTooLarge }
        return data
    }

    static func encodeWAV(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty else { throw OLIVAPIError.emptyAudio }
        guard samples.count <= maxSamples else { throw OLIVAPIError.audioTooLong }
        let byteCount = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(byteCount))
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); integer(byteCount + 36); ascii("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(16000)); integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16))
        ascii("data"); integer(byteCount)
        for sample in samples {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            integer(Int16(max(-32768, min(32767, (value * 32768).rounded()))))
        }
        return data
    }

    private static func checkStatus(_ status: Int) throws {
        if (300...399).contains(status) { throw OLIVAPIError.redirect }
        guard status == 200 else { throw OLIVAPIError.http(status) }
    }

    static func parseReply(status: Int, data: Data) throws -> DictationResult {
        try checkStatus(status)
        guard data.count <= maxResponseBytes else { throw OLIVAPIError.responseTooLarge }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object.keys.contains("final"), !(object["final"] is String) { throw OLIVAPIError.invalidReply }
        struct Reply: Decodable {
            let ok: Bool
            let raw: String?
            let final: String?
            let no_speech: Bool?
            let stt_redecoded: Bool?
            let t_stt: Double?
            let t_cleanup: Double?
            let llm_ran: Bool?
            let gate_reason: String?
            let guardrail_flag: String?
            let cleanup_error: String?
            let fillers_removed: Int?
            let replacements_fired: Int?
            let thai_format_fired: Int?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.ok,
              reply.final != nil || reply.no_speech == true,
              (reply.t_stt ?? 0) >= 0, (reply.t_cleanup ?? 0) >= 0 else { throw OLIVAPIError.invalidReply }
        return DictationResult(raw: reply.raw ?? "", final: reply.final ?? "",
                               tSTT: reply.t_stt ?? 0, tCleanup: reply.t_cleanup ?? 0,
                               llmRan: reply.llm_ran ?? false, gateReason: reply.gate_reason ?? "",
                               guardrailFlag: reply.guardrail_flag ?? "", cleanupError: reply.cleanup_error,
                               fillersRemoved: reply.fillers_removed ?? 0,
                               replacementsFired: reply.replacements_fired ?? 0,
                               thaiFormatFired: reply.thai_format_fired ?? 0,
                               noSpeech: reply.no_speech ?? false,
                               sttRedecoded: reply.stt_redecoded ?? false,
                               engineID: engineID)
    }

    static func retryAfter(_ header: String?, now: Date) -> TimeInterval {
        guard let header = header else { return 60 }
        if !header.isEmpty, header.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt64(header) {
            return max(1, TimeInterval(n))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        }
        return 60
    }
}
