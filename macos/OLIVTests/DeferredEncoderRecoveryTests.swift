import XCTest

final class DeferredEncoderRecoveryTests: XCTestCase {
    private enum Failure: Error { case cancelled, unavailable }

    func testCancelledPreviewDoesNotLoadWeightsAndFinalCanRecoverOnce() throws {
        var loads = 0, installs = 0
        let recovery = DeferredEncoderRecovery {
            loads += 1
            return "original encoder"
        }
        XCTAssertThrowsError(try recovery.restore(checkCancellation: { throw Failure.cancelled }, install: { _ in
            installs += 1
        }))
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(installs, 0)

        for _ in 0..<2 {
            try recovery.restore(checkCancellation: {}, install: { encoder in
                XCTAssertEqual(encoder, "original encoder")
                installs += 1
            })
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(installs, 1)
    }

    func testFailedLoadRemainsAvailableForTheNextRequest() throws {
        var loads = 0, installs = 0
        let recovery = DeferredEncoderRecovery {
            loads += 1
            if loads == 1 { throw Failure.unavailable }
            return "original encoder"
        }
        XCTAssertThrowsError(try recovery.restore(checkCancellation: {}, install: { _ in installs += 1 }))
        XCTAssertEqual(installs, 0)
        try recovery.restore(checkCancellation: {}, install: { _ in installs += 1 })
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(installs, 1)
    }
}
