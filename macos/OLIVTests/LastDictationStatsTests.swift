// LastDictationStats.menuLine — the pure formatter behind the menu's
// "Last: 1.4s · 38 chars" line (0.1.5). Total = stt + cleanup, one decimal.

import XCTest
@testable import OLIV

final class LastDictationStatsTests: XCTestCase {
    func testMenuLineSumsSttAndCleanupToOneDecimal() {
        let stats = LastDictationStats(chars: 38, sttSeconds: 0.9, cleanupSeconds: 0.5)
        XCTAssertEqual(stats.menuLine, "Last: 1.4s · 38 chars")
    }

    func testMenuLineRoundsToNearestDecimal() {
        let stats = LastDictationStats(chars: 120, sttSeconds: 1.0, cleanupSeconds: 0.26)
        XCTAssertEqual(stats.menuLine, "Last: 1.3s · 120 chars")
    }

    func testMenuLineSubSecondKeepsLeadingZero() {
        let stats = LastDictationStats(chars: 5, sttSeconds: 0.3, cleanupSeconds: 0.2)
        XCTAssertEqual(stats.menuLine, "Last: 0.5s · 5 chars")
    }

    func testMenuLineZeroCleanupWhenDisabled() {
        let stats = LastDictationStats(chars: 42, sttSeconds: 2.0, cleanupSeconds: 0.0)
        XCTAssertEqual(stats.menuLine, "Last: 2.0s · 42 chars")
    }
}
