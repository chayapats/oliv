import Foundation

/// Local, bounded breadcrumbs for explicit capture and keyboard handoff events.
/// No free-form messages or user content can be passed to this API.
enum CaptureDiagnostics {
    enum Event: String, Codable, Sendable {
        case intentToggle, intentFinish, intentForeground, startRequested
        case setupRejected, microphonePermissionMissing, focusAvailable, focusUnavailable
        case liveActivityStarting, liveActivityStarted, microphoneStarting, microphoneStarted
        case audioSessionConfiguring, audioSessionConfigured, audioSessionActivating, audioSessionActivated
        case recorderStarting, recorderStarted
        case automaticFinish, noSpeechCancelled, speechAnalysisFailed
        case audioEngineStoppedUnexpectedly, audioPipelineFailed
        case audioConversionFailed, audioWriteFailed
        case speechClassifierFailed, speechClassifierUnderlyingFailure
        case speechClassifierInvalidResult, speechClassifierResultsOverflow
        case startFailed, microphoneStopped, resultReady, deliveryPublished, deliveryRejected
        case keyboardVisible, keyboardUnavailable, keyboardFocusPublished
        case keyboardFocusInvalidated, keyboardDelivered, bridgeUnavailable
    }

    enum Detail: String, Codable, Sendable {
        case notVisible, fullAccessOff, noWindow, sceneInactive, noDocument
        case active, inactive, background
    }

    enum ErrorDomain: String, Codable, Sendable {
        case osStatus = "NSOSStatusErrorDomain"
        case cocoa = "NSCocoaErrorDomain"
        case url = "NSURLErrorDomain"
        case audio = "AVFAudioErrorDomain"
        case avFoundation = "AVFoundationErrorDomain"
        case activityAuthorization = "ActivityAuthorizationErrorDomain"
        case soundAnalysis = "com.apple.SoundAnalysis"
        case coreML = "com.apple.CoreML"
        case metal = "MTLCommandBufferErrorDomain"
        case audioPipeline = "OLIVAudioPipeline"
        case other
    }

    struct Entry: Codable, Equatable, Sendable {
        let timestamp: Date
        let event: Event
        let detail: Detail?
        let errorCode: Int?
        let errorDomain: ErrorDomain?
    }

    /// Each executable uses its own private Application Support container. Never
    /// put these logs in the keyboard's shared delivery container.
    private static let productionStore: Store? = {
        let process = ProcessInfo.processInfo
        let fixtureArguments: Set<String> = [
            "--ui-testing", "--demo", "--keyboard-test-host", "--keyboard-integration-demo"
        ]
        guard !process.arguments.contains(where: fixtureArguments.contains),
              process.environment["XCTestConfigurationFilePath"] == nil,
              process.environment["XCTestBundlePath"] == nil,
              process.environment["XCTestSessionIdentifier"] == nil,
              NSClassFromString("XCTestCase") == nil,
              let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        return Store(directory: support.appendingPathComponent("OLIVDiagnostics", isDirectory: true))
    }()

    /// Diagnostics must never prevent or change a capture. There is no timer,
    /// background task, network call, or automatic retry associated with logging.
    static func record(event: Event, error: (any Error)? = nil, detail: Detail? = nil) {
        try? productionStore?.record(event: event, error: error, detail: detail)
    }

    /// SoundAnalysis often wraps a Core ML failure. Preserve at most three
    /// underlying numeric identities; never serialize descriptions or userInfo.
    static func recordClassifierFailure(_ error: any Error) {
        try? productionStore?.recordClassifierFailure(error)
    }

    /// An explicit directory supports isolated tests without touching real logs.
    final class Store: @unchecked Sendable {
        static let maximumEvents = 40
        private static let maximumFileBytes = 64 * 1_024
        private let directory: URL
        private let lock = NSLock()

        init(directory: URL) { self.directory = directory }

        func recordClassifierFailure(_ error: any Error, now: Date = Date()) throws {
            var current = error as NSError
            try record(event: .speechClassifierFailed, error: current, now: now)
            var visited: Set<ObjectIdentifier> = [ObjectIdentifier(current)]
            for _ in 0..<3 {
                guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError,
                      visited.insert(ObjectIdentifier(underlying)).inserted else { break }
                try record(event: .speechClassifierUnderlyingFailure, error: underlying, now: now)
                current = underlying
            }
        }

        func record(event: Event, error: (any Error)? = nil, detail: Detail? = nil,
                    now: Date = Date()) throws {
            guard now.timeIntervalSince1970.isFinite else { return }
            lock.lock()
            defer { lock.unlock() }

            let fileManager = FileManager.default
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: attributes)
            try fileManager.setAttributes(attributes, ofItemAtPath: directory.path)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)

            let file = directory.appendingPathComponent("events.json")
            var entries: [Entry] = []
            if let size = try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
               size.intValue <= Self.maximumFileBytes,
               let data = try? Data(contentsOf: file), data.count <= Self.maximumFileBytes {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                entries = (try? decoder.decode([Entry].self, from: data)) ?? []
                entries = Array(entries.filter { $0.timestamp.timeIntervalSince1970.isFinite }
                    .suffix(Self.maximumEvents - 1))
            }
            // NSError's domain and userInfo may contain arbitrary supplied text.
            // Keep only an exact allowlisted domain and the numeric code.
            let code: Int?
            let domain: ErrorDomain?
            if let error {
                let nsError = error as NSError
                code = nsError.code
                domain = ErrorDomain(rawValue: nsError.domain) ?? .other
            } else {
                code = nil
                domain = nil
            }
            entries.append(Entry(timestamp: now, event: event, detail: detail,
                                 errorCode: code, errorDomain: domain))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(entries)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
