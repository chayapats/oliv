import XCTest

final class CoreMLEncoderWindowsTests: XCTestCase {
    func testPreviewsRoundUpAndFinalKeepsFullWindow() throws {
        let windows = try XCTUnwrap(CoreMLEncoderWindows(
            shapes: [3000, 1000, 1500, 2000, 2500, 1000].map { [1, 128, 1, $0] }, melBins: 128))
        XCTAssertEqual(windows.covering(1000), 1000)
        XCTAssertEqual(windows.covering(1050), 1500)
        XCTAssertEqual(windows.covering(2950), 3000)
        XCTAssertEqual(windows.covering(3000), 3000)
        XCTAssertNil(windows.covering(3001))
        XCTAssertNil(windows.covering(0))
    }

    func testExistingFixedEncoderCanPreviewWithoutLoadingMLXEncoder() throws {
        let windows = try XCTUnwrap(CoreMLEncoderWindows(shapes: [[1, 128, 1, 3000]], melBins: 128))
        XCTAssertEqual(windows.covering(1000), 3000)
        XCTAssertEqual(windows.covering(3000), 3000)
    }

    func testFlexibleOutputMetadataMayOmitItsStaticShape() {
        XCTAssertTrue(CoreMLEncoderWindows.acceptsOutputDescription([], dimensions: 1280))
        XCTAssertTrue(CoreMLEncoderWindows.acceptsOutputDescription([1, 1280, 1, 1500], dimensions: 1280))
        XCTAssertFalse(CoreMLEncoderWindows.acceptsOutputDescription([1, 1024, 1, 1500], dimensions: 1280))
        XCTAssertFalse(CoreMLEncoderWindows.acceptsOutputDescription([1, 1280, 1500], dimensions: 1280))
    }

    func testRejectsArtifactsWhoseShapeWouldBreakTheTensorBridgeOrFinalDecode() {
        for shapes in [[], [[1, 128, 1, 1000]], [[1, 80, 1, 3000]], [[2, 128, 1, 3000]],
                       [[1, 128, 2, 3000]], [[1, 128, 3000]], [[1, 128, 1, 3000], [1, 128, 1, 999]],
                       [[1, 128, 1, 3000], [1, 128, 1, 0]], [[1, 128, 1, 3100]]] {
            XCTAssertNil(CoreMLEncoderWindows(shapes: shapes, melBins: 128), "\(shapes)")
        }
    }
}
