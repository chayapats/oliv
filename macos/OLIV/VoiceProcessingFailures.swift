import Foundation

/// Remember a failed AEC route across launches. Device and OS changes get a
/// fresh attempt; toggling echo cancellation explicitly clears the failures.
/// No audio, transcript, or credentials are retained.
final class VoiceProcessingFailures {
    static let defaultsKey = "oliv.audio.failedVoiceRoutes"
    private let defaults: UserDefaults?
    private var routes: [String]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        routes = defaults?.stringArray(forKey: Self.defaultsKey) ?? []
    }

    static func route(inputUID: String, outputUID: String,
                      system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        // Length-prefix fields so even unusual device UIDs cannot collide.
        [system, inputUID, outputUID].map { "\($0.utf8.count):\($0)" }.joined()
    }

    func contains(_ route: String) -> Bool { routes.contains(route) }

    func remember(_ route: String) {
        routes.removeAll { $0 == route }
        routes.append(route)
        routes = Array(routes.suffix(16))
        defaults?.set(routes, forKey: Self.defaultsKey)
    }

    func reset() {
        routes.removeAll()
        defaults?.removeObject(forKey: Self.defaultsKey)
    }
}
