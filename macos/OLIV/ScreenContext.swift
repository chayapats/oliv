// Names on screen — at push-to-talk start, read the visible text of the window
// the user is dictating into, so the Rust matcher can spell the names in it
// for THIS dictation only (`screen_text` → `oliv-text::screen`).
//
// It never delays recording: the walk runs on its own queue while the user
// speaks, under hard caps (time, nodes, depth, characters), and a walk that
// hasn't finished by release is dropped. Each Accessibility call is bounded by
// a messaging timeout, so a hung app costs at most the budget.
//
// Privacy: the text stays in memory for one dictation and goes only to the
// local Rust worker over its private pipe. It is never stored, logged or sent
// to a server: the OLIV API engine does not capture at all (its cleanup runs
// on the server), and the Rust worker keeps it out of every STT prompt.
// Password fields, secure input, password managers, verbatim apps and OLIV
// itself are skipped.

import AppKit
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled()

/// What one Accessibility node shows.
struct ScreenNodeInfo: Equatable {
    var role: String?
    var subrole: String?
    /// The node's own visible text (value, title or description, by role).
    var texts: [String] = []
}

/// One node of an Accessibility tree, abstracted so the walker's caps and
/// skips are testable with fake trees.
protocol ScreenNode {
    func read() -> ScreenNodeInfo
    func children() -> [ScreenNode]
}

/// Hard caps for one walk. The character and snippet caps match the Rust
/// side's (`screen::MAX_CHARS`, `MAX_SNIPPETS`), which caps again.
struct ScreenTextLimits: Equatable, Sendable {
    var budget: TimeInterval = 0.25
    var maxNodes = 2_000
    var maxDepth = 60
    var maxChars = 20_000
    var maxSnippets = 500
    /// One long text (a whole document) can't crowd out the rest.
    var maxSnippetChars = 4_000
}

struct ScreenTextResult: Equatable {
    enum Stop: Equatable { case budget, nodes, chars, snippets, cancelled }
    var snippets: [String] = []
    var nodes = 0
    /// Why the walk ended early; nil when it covered the whole tree.
    var stopped: Stop?
}

enum ScreenTextWalker {
    /// Roles whose subtree is never read: password fields, menus (not on
    /// screen until opened) and scroll bars.
    static let skippedRoles: Set<String> = [
        "AXSecureTextField", "AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar",
    ]
    /// Controls: their labels (Send, Cancel) name nothing, and they hold no
    /// content worth descending into.
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXColorWell",
    ]

    /// Depth-first, in reading order, until the tree ends or a cap is hit;
    /// what was read before a cap is kept.
    static func collect(from root: ScreenNode, limits: ScreenTextLimits = .init(),
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        isCancelled: () -> Bool = { false }) -> ScreenTextResult {
        let deadline = now() + limits.budget
        var result = ScreenTextResult()
        var chars = 0
        var stack: [(node: ScreenNode, depth: Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            if isCancelled() { result.stopped = .cancelled; break }
            if now() >= deadline { result.stopped = .budget; break }
            if result.nodes >= limits.maxNodes { result.stopped = .nodes; break }
            result.nodes += 1
            let info = node.read()
            if let role = info.role, skippedRoles.contains(role) { continue }
            if let subrole = info.subrole, subrole == "AXSecureTextField" { continue }
            if let role = info.role, controlRoles.contains(role) { continue }
            for raw in info.texts {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if result.snippets.count >= limits.maxSnippets { result.stopped = .snippets; break }
                // Counted in Unicode scalars, as Rust counts chars.
                let room = min(limits.maxSnippetChars, limits.maxChars - chars)
                let snippet = String(String.UnicodeScalarView(text.unicodeScalars.prefix(room)))
                result.snippets.append(snippet)
                chars += snippet.unicodeScalars.count
                if chars >= limits.maxChars { result.stopped = .chars; break }
            }
            if result.stopped != nil { break }
            guard depth < limits.maxDepth else { continue }
            for child in node.children().reversed() { stack.append((child, depth + 1)) }
        }
        return result
    }
}

/// One capture, started at press and taken (or dropped) at release.
final class ScreenContextCapture: @unchecked Sendable {
    /// Serial: a walk stuck behind a slow app delays only the next capture,
    /// which is then dropped at its own release.
    static let queue = DispatchQueue(label: "com.oliv.screen-context", qos: .userInitiated)

    private let lock = NSLock()
    private var snippets: [String]?
    private var cancelled = false
    private var taken = false

    /// Start reading on `queue`; returns at once. `root` runs on the queue
    /// too (resolving the focused window is itself Accessibility IPC).
    static func start(limits: ScreenTextLimits = .init(), queue: DispatchQueue = queue,
                      root: @escaping () -> ScreenNode?) -> ScreenContextCapture {
        let capture = ScreenContextCapture()
        queue.async {
            guard !capture.isCancelled, let node = root() else { capture.finish([]); return }
            let result = ScreenTextWalker.collect(from: node, limits: limits,
                                                  isCancelled: { capture.isCancelled })
            capture.finish(result.stopped == .cancelled ? nil : result.snippets)
        }
        return capture
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func finish(_ value: [String]?) {
        lock.lock(); defer { lock.unlock() }
        if !cancelled { snippets = value }
    }

    /// The snippets when the walk has finished, else nil: the walk is stopped
    /// and this dictation goes without them. One-shot; the text is released.
    func take() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return nil }
        taken = true
        let value = snippets
        snippets = nil
        if value == nil { cancelled = true }
        return value
    }

    /// Stop and discard (a cancelled press).
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        snippets = nil
    }
}

enum ScreenContext {
    /// Password managers (and macOS's own password apps), never read.
    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.lastpass", "com.dashlane.dashlane",
        "org.keepassxc.keepassxc", "in.sinew.enpass-desktop", "me.proton.pass.electron",
        "com.apple.keychainaccess", "com.apple.passwords",
    ]

    /// Whether to read the screen for a dictation starting now. Only when
    /// opted in, with on-device cleanup (local engines and Groq run the text
    /// pipeline on this Mac; the OLIV API runs it on the server), outside
    /// verbatim apps (`cleanup` is already false there), password managers
    /// and OLIV, with Accessibility granted and no secure input active.
    static func shouldCapture(enabled: Bool, engine: String, cleanup: Bool,
                              frontmostBundleID: String?, ownBundleID: String?,
                              accessibilityTrusted: Bool, secureInput: Bool) -> Bool {
        guard enabled, cleanup, engine != OLIVAPIClient.engineID,
              accessibilityTrusted, !secureInput else { return false }
        guard let app = frontmostBundleID?.lowercased(), !app.isEmpty else { return false }
        if app == ownBundleID?.lowercased() { return false }
        return !passwordManagers.contains(app)
    }

    static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    static func secureInputActive() -> Bool { IsSecureEventInputEnabled() }

    /// Per-call Accessibility timeout: a hung app answers within this or not at all.
    static let messagingTimeout: Float = 0.05

    /// The window holding the focused element, or nil when there is none or
    /// the focused element is a password field.
    static func focusedWindow() -> ScreenNode? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let info = AXScreenNode(element: element).read()
        if info.role == "AXSecureTextField" || info.subrole == "AXSecureTextField" { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return AXScreenNode(element: window as! AXUIElement)
    }
}

/// A live Accessibility element. Reads role, subrole and text in one call.
struct AXScreenNode: ScreenNode {
    let element: AXUIElement

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute,
    ] as CFArray

    /// Roles whose value is text the user sees.
    private static let valueRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXHeading", "AXCell",
    ]
    /// Roles whose title or description is their visible text (a window
    /// title, a link, an avatar's name).
    private static let labelRoles: Set<String> = [
        "AXWindow", "AXHeading", "AXLink", "AXImage", "AXCell", "AXRow",
    ]

    func read() -> ScreenNodeInfo {
        AXUIElementSetMessagingTimeout(element, ScreenContext.messagingTimeout)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(),
                                                     &values) == .success,
              let list = values as? [Any], list.count == 5 else { return ScreenNodeInfo() }
        // A failed attribute comes back as an AXValue error, never a String.
        let text = { (i: Int) in list[i] as? String }
        var info = ScreenNodeInfo(role: text(0), subrole: text(1))
        guard let role = info.role else { return info }
        if Self.valueRoles.contains(role) {
            if role == "AXTextArea", let visible = visibleText() {
                info.texts.append(visible)
            } else if let value = text(2) {
                info.texts.append(value)
            }
        }
        if Self.labelRoles.contains(role) { info.texts += [text(3), text(4)].compactMap { $0 } }
        return info
    }

    /// Only the visible part of a long text area (a document scrolled far).
    private func visibleText() -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString,
                                            &range) == .success, let range else { return nil }
        var string: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, range, &string) == .success
        else { return nil }
        return string as? String
    }

    func children() -> [ScreenNode] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.map(AXScreenNode.init(element:))
    }
}
