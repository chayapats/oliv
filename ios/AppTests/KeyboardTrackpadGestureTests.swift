import XCTest
import CoreGraphics

final class KeyboardTrackpadGestureTests: XCTestCase {
    func testSeventeenPointVerticalStrokeEmitsOneStepInEitherDirection() {
        for sign: CGFloat in [-1, 1] {
            var gesture = KeyboardTrackpadGesture()
            gesture.begin(at: .zero)
            XCTAssertNil(gesture.change(to: CGPoint(x: 0, y: sign * 11)))
            XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: sign * 17)), .vertical(Int(sign)))
            XCTAssertNil(gesture.change(to: CGPoint(x: 0, y: sign * 17)))
        }
    }

    func testVerticalIntentWinsDiagonalTravelAndResistsSmallSideDrift() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 10, y: 12)), .vertical(1))
        XCTAssertNil(gesture.change(to: CGPoint(x: 19, y: 15)))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 20, y: 24)), .vertical(1))
        XCTAssertNil(gesture.change(to: CGPoint(x: 29, y: 26)))
    }

    func testPreviousHorizontalTravelDoesNotStarveVerticalTurn() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 60, y: 0)), .horizontal(7))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 61, y: 17)), .vertical(1))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 62, y: 29)), .vertical(1))
    }

    func testDeliberateHorizontalTurnRequiresSixteenPointsAfterVerticalMotion() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 2, y: 12)), .vertical(1))
        XCTAssertNil(gesture.change(to: CGPoint(x: 17, y: 14)))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 18, y: 14)), .horizontal(2))
    }

    func testTwelvePointReversalEmitsImmediatelyWithoutRetracingOverallTravel() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 29)), .vertical(2))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 17)), .vertical(-1))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 5)), .vertical(-1))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 17)), .vertical(1))
    }

    func testSubPointReversalNoiseDoesNotDiscardFractionalTravel() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 17)), .vertical(1))
        XCTAssertNil(gesture.change(to: CGPoint(x: 0, y: 16.6)))
        XCTAssertNil(gesture.change(to: CGPoint(x: 0, y: 17.1)))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 24)), .vertical(1))
    }

    func testSmallReversalCallbacksAccumulateToEstablishNewTrend() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 17)), .vertical(1))
        for y: CGFloat in [16.6, 16.2, 15.8] {
            XCTAssertNil(gesture.change(to: CGPoint(x: 0, y: y)))
        }
        XCTAssertEqual(gesture.change(to: CGPoint(x: 0, y: 5)), .vertical(-1))
    }

    func testCallbackCapsRetainUnconsumedVerticalAndHorizontalSteps() {
        var gesture = KeyboardTrackpadGesture()
        gesture.begin(at: .zero)
        let verticalEnd = CGPoint(x: 0, y: 121)
        XCTAssertEqual(gesture.change(to: verticalEnd), .vertical(4))
        XCTAssertEqual(gesture.change(to: verticalEnd), .vertical(4))
        XCTAssertEqual(gesture.change(to: verticalEnd), .vertical(2))
        XCTAssertNil(gesture.change(to: verticalEnd))
        gesture.begin(at: .zero)
        let horizontalEnd = CGPoint(x: -401, y: 0)
        XCTAssertEqual(gesture.change(to: horizontalEnd), .horizontal(-24))
        XCTAssertEqual(gesture.change(to: horizontalEnd), .horizontal(-24))
        XCTAssertEqual(gesture.change(to: horizontalEnd), .horizontal(-2))
        XCTAssertNil(gesture.change(to: horizontalEnd))
    }

    func testResetAndNewBeginDiscardPreviousAxisAndFractionalTravel() {
        var gesture = KeyboardTrackpadGesture()
        XCTAssertNil(gesture.change(to: CGPoint(x: 0, y: 100)))
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.change(to: CGPoint(x: 8, y: 0)), .horizontal(1))
        gesture.reset()
        XCTAssertNil(gesture.change(to: CGPoint(x: 8, y: 100)))
        gesture.begin(at: CGPoint(x: 40, y: 40))
        XCTAssertNil(gesture.change(to: CGPoint(x: 40, y: 51)))
        XCTAssertEqual(gesture.change(to: CGPoint(x: 40, y: 52)), .vertical(1))
    }
}
