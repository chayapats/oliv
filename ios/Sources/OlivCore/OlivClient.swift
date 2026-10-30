import Foundation

/// Authentication is intentionally not Codable. Persist the token in Keychain,
/// independently of ordinary app preferences and pending recordings.
public struct OlivConfiguration: Sendable {
    public let baseURL: URL
    public let token: String
    public let allowsInsecureHTTP: Bool

    public init(baseURL: URL, token: String, allowsInsecureHTTP: Bool = false) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw OlivError.invalidConfiguration("Enter an OLIV server URL without credentials, a query, or a fragment.")
        }
        guard scheme == "https" || (scheme == "http" && allowsInsecureHTTP && Self.isPrivateHost(host)) else {
            throw OlivError.invalidConfiguration("Use HTTPS, or explicitly enable HTTP for a local or private VPN address.")
        }
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw OlivError.invalidConfiguration("The access token must contain printable ASCII characters without spaces.")
        }
        self.baseURL = baseURL
        self.token = token
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        // IPv6 unique-local / link-local. URLComponents has already parsed the host.
        if h.contains(":"), !h.contains("%"),
           (h.hasPrefix("fc") || h.hasPrefix("fd") || ["fe8", "fe9", "fea", "feb"].contains(where: h.hasPrefix)) {
            return true
        }
        let pieces = h.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }) else { return false }
        let bytes = pieces.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31), (100, 64...127): return true // NetBird/Tailscale CGNAT.
        default: return false
        }
    }

    func url(for path: String) -> URL {
        // Preserve reverse-proxy base paths rather than replacing them.
        path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }
}

public struct OlivClient: Sendable {
    public static let requestTimeout: TimeInterval = 120
    public static let userAgent = "oliv-ios/0.1.0"
    public static let maximumRequestBytes = 8 * 1_024 * 1_024
    public static let maximumResponseBytes = 1_024 * 1_024
    public let configuration: OlivConfiguration
    private let session: URLSession

    public init(configuration: OlivConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = Self.requestTimeout
            c.timeoutIntervalForResource = Self.requestTimeout
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.urlCache = nil
            c.httpCookieStorage = nil
            c.urlCredentialStorage = nil
            c.httpShouldSetCookies = false
            self.session = URLSession(configuration: c)
        }
    }

    public func dictate(wav: Data, options: OlivOptions = OlivOptions()) async throws -> DictationReply {
        let metadata = try WAVMetadata(data: wav)
        guard metadata.sampleRate == 16_000, metadata.channelCount == 1, metadata.bitsPerSample == 16 else {
            throw OlivError.invalidAudio("OLIV expects 16 kHz mono 16-bit PCM WAV audio.")
        }
        guard metadata.duration > 0, metadata.duration <= RecordingLimits.maximumDuration else {
            throw OlivError.invalidAudio("Record between a moment and two minutes of audio.")
        }
        // AVAudioRecorder adds FLLR chunks rejected by the server. Normalize only
        // the outgoing copy so saved recordings remain available for recovery.
        let canonicalWAV = try WAVEncoder.canonicalize(wav)
        let body = try RequestBody.encode(audio: canonicalWAV, text: nil, options: options)
        return try await reply(path: "v1/dictate", body: body)
    }

    /// Re-run the original OLIV cleanup pipeline on existing text. This is
    /// faithful cleanup, not a separate creative rewrite or translation mode.
    public func clean(text: String, options: OlivOptions = OlivOptions()) async throws -> DictationReply {
        guard text.utf8.count <= OlivOptions.maximumCleanupTextBytes else {
            throw OlivError.invalidOptions("Cleanup accepts up to \(OlivOptions.maximumCleanupTextBytes.formatted()) UTF-8 bytes of text; shorten it and try again.")
        }
        let body = try RequestBody.encode(audio: nil, text: text, options: options)
        return try await reply(path: "v1/clean", body: body)
    }

    /// /health is deliberately unauthenticated on the OLIV server.
    public func health() async throws -> ServerHealth {
        let data = try await perform(path: "health", body: nil)
        do { return try JSONDecoder().decode(ServerHealth.self, from: data) }
        catch { throw OlivError.invalidResponse }
    }

    private func reply(path: String, body: Data) async throws -> DictationReply {
        let data = try await perform(path: path, body: body)
        let reply: DictationReply
        do { reply = try JSONDecoder().decode(DictationReply.self, from: data) }
        catch { throw OlivError.invalidResponse }
        guard reply.ok else { throw OlivError.server(statusCode: 200) }
        return reply
    }

    private func perform(path: String, body: Data?) async throws -> Data {
        try Task.checkCancellation()
        if let body, body.count > Self.maximumRequestBytes { throw OlivError.requestTooLarge }
        var request = URLRequest(url: configuration.url(for: path),
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects.shared)
            guard let http = response as? HTTPURLResponse else { throw OlivError.invalidResponse }
            guard http.statusCode == 200 else {
                let now = Date()
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After")
                if http.statusCode == 401 { throw OlivError.unauthorized }
                if http.statusCode == 429 {
                    throw OlivError.rateLimited(retryAfter: Self.retryDate(header: retryHeader, now: now))
                }
                if (500...599).contains(http.statusCode) {
                    throw OlivError.serviceUnavailable(statusCode: http.statusCode,
                        retryAfter: retryHeader.map { Self.retryDate(header: $0, now: now) })
                }
                if http.statusCode == 403 {
                    // Inspect only a bounded prefix to classify known denial
                    // responses. Never return its contents in a diagnostic.
                    var prefix = Data()
                    do {
                        for try await byte in bytes {
                            guard prefix.count < 16 * 1_024 else { break }
                            prefix.append(byte)
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                    }
                    try Task.checkCancellation()
                    throw OlivError.forbidden(reason: Self.forbiddenReason(body: prefix))
                }
                throw OlivError.server(statusCode: http.statusCode)
            }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw OlivError.responseTooLarge
            }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw OlivError.responseTooLarge }
                data.append(byte)
                if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OlivError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .timedOut: throw OlivError.timedOut
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
                throw OlivError.networkUnavailable
            default: throw OlivError.transport
            }
        } catch {
            throw OlivError.transport
        }
    }

    static func forbiddenReason(body: Data) -> OlivForbiddenReason {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           object["error"] as? String == "API key does not allow this operation" { return .missingScope }
        let text = String(decoding: body, as: UTF8.self).lowercased()
        if text.contains("error code: 1010") || text.contains("cloudflare") { return .edgePolicy }
        return .unknown
    }

    /// Accept delta seconds and all HTTP-date forms. A malformed/missing value
    /// uses a conservative minute, and even an elapsed date waits one second.
    static func retryDate(header: String?, now: Date) -> Date {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return now.addingTimeInterval(60)
        }
        if value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = UInt64(value) {
            return now.addingTimeInterval(max(1, Double(seconds)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(date, now.addingTimeInterval(1)) }
        }
        return now.addingTimeInterval(60)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RejectRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward the bearer credential, WAV, or transcript to a redirect.
        completionHandler(nil)
    }
}

/// JSONEncoder doesn't guarantee insertion order for keyed objects. The source
/// server uses ordered JSON maps, so explicitly serialize only the replacement
/// map while delegating string escaping and other values to JSONEncoder.
enum RequestBody {
    static func encode(audio: Data?, text: String?, options: OlivOptions) throws -> Data {
        try options.validate()
        try options.validateServerLimits()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var pairs: [String] = []
        if let audio { pairs.append("\"wav_b64\":\(try json(audio.base64EncodedString()))") }
        if let text { pairs.append("\"text\":\(try json(text))") }
        pairs.append("\"cleanup\":\(options.cleanup)")
        pairs.append("\"remove_fillers\":\(options.removeFillers)")
        pairs.append("\"thai_format\":\(options.thaiFormat)")
        pairs.append("\"vocabulary\":\(try json(options.vocabulary))")
        let rules = try options.replacements.map { "\(try json($0.spoken)):\(try json($0.written))" }.joined(separator: ",")
        pairs.append("\"replacements\":{\(rules)}")
        // Omit prompt so upgrades preserve the deployment's chosen prompt.
        let result = Data(("{" + pairs.joined(separator: ",") + "}").utf8)
        guard result.count <= OlivClient.maximumRequestBytes else { throw OlivError.requestTooLarge }
        return result
    }
}
