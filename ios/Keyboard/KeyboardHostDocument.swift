import UIKit

/// UIKit imports `UITextDocumentProxy.documentIdentifier` as a non-optional
/// UUID, but the remote proxy returns nil whenever no host text session is
/// attached: before the first document state arrives, after the host drops
/// focus, and inside callbacks UIKit delivers late (viewDidAppear is queued).
/// Bridging that nil traps (`UUID._unconditionallyBridgeFromObjectiveC`), which
/// killed the extension and left the host app with no keyboard until the user
/// refocused the field. Read the identifier through the Objective-C runtime.
enum KeyboardHostDocument {
    private static let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)

    /// UITextDocumentProxy inherits NSObjectProtocol, so every conformer takes
    /// this runtime path; there is deliberately no fallback to the Swift getter.
    static func identifier(of object: any NSObjectProtocol) -> UUID? {
        guard object.responds(to: getter) else { return nil }
        // The getter returns an autoreleased (+0) NSUUID or nil.
        return object.perform(getter)?.takeUnretainedValue() as? UUID
    }
}
