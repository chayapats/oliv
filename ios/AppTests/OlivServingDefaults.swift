import Foundation
import OlivCore
@testable import Oliv

/// Test services that don't exercise the Dictionary behave like a server
/// without dictionary sync. Test-target only: production has no default.
extension OlivServing {
    func dictionary(ops: [DictionaryOp]?) async throws -> DictionarySnapshot {
        throw OlivError.dictionaryUnsupported
    }
}
