import XCTest
import UIKit

/// The remote proxy returns nil for documentIdentifier outside an attached host
/// session even though Swift imports it as non-optional. Reading it directly
/// trapped the extension (build 14 device crashes in viewDidAppear).
final class KeyboardHostDocumentTests: XCTestCase {
    private final class DetachedProxy: NSObject {
        @objc(documentIdentifier) var detachedIdentifier: NSUUID? { nil }
    }
    private final class AttachedProxy: NSObject {
        let value = UUID()
        @objc(documentIdentifier) var attachedIdentifier: NSUUID? { value as NSUUID }
    }

    func testDetachedSessionReadsAsNilInsteadOfTrapping() {
        XCTAssertNil(KeyboardHostDocument.identifier(of: DetachedProxy()))
    }

    func testAttachedSessionReturnsItsIdentifier() {
        let proxy = AttachedProxy()
        XCTAssertEqual(KeyboardHostDocument.identifier(of: proxy), proxy.value)
    }

    /// The controller passes the proxy as a protocol existential, not NSObject.
    func testProtocolExistentialTakesTheRuntimePath() {
        let proxy: any NSObjectProtocol = DetachedProxy()
        XCTAssertNil(KeyboardHostDocument.identifier(of: proxy))
    }

    func testObjectWithoutTheGetterReadsAsNil() {
        XCTAssertNil(KeyboardHostDocument.identifier(of: NSObject()))
    }
}
