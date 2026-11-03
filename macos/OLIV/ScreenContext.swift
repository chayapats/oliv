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
// itself are skipped. Only the window of the app approved at press is read
// (by its process id), and the text is kept only if that app still has focus
// when the walk ends. No more is copied out of the app than the caps keep: a
// text area gives its visible range, and children come in budgeted batches.

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
    /// Up to `max` children from `index` on, in reading order; fewer than
    /// `max` means there are no more.
    func children(from index: Int, max: Int) -> [ScreenNode]
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
    /// Children are fetched this many at a time, as the walk reaches them.
    var childBatch = 64
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
    /// what was read before a cap is kept. Children are fetched in batches as
    /// the walk reaches them, and only as many as the node budget has room
    /// for (nodes fetched but not yet read count against it), so a list of
    /// thousands costs no more than the nodes actually read.
    static func collect(from root: ScreenNode, limits: ScreenTextLimits = .init(),
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        isCancelled: () -> Bool = { false }) -> ScreenTextResult {
        let deadline = now() + limits.budget
        var result = ScreenTextResult()
        var chars = 0
        var open: [OpenNode] = []   // the nodes being descended, root first
        var unread = 0              // fetched, not yet read
        var cut = false             // the node budget left children unfetched
        var next: (node: ScreenNode, depth: Int)? = (root, 0)
        while true {
            if isCancelled() { result.stopped = .cancelled; break }
            if now() >= deadline { result.stopped = .budget; break }
            guard let (node, depth) = next else {
                // Next in reading order: the deepest open node's next child.
                guard var parent = open.popLast() else { break }   // the tree is read
                if let child = parent.pending.popLast() {
                    unread -= 1
                    next = (child, parent.depth + 1)
                    open.append(parent)
                } else if !parent.exhausted {
                    let room = min(limits.childBatch, limits.maxNodes - result.nodes - unread)
                    if room <= 0 {
                        // No budget for its other children: read what is queued.
                        cut = true
                        if unread == 0 { result.stopped = .nodes; break }
                        continue
                    }
                    let batch = Array(parent.node.children(from: parent.fetched, max: room).prefix(room))
                    parent.fetched += batch.count
                    parent.exhausted = batch.count < room
                    parent.pending = batch.reversed()
                    unread += batch.count
                    open.append(parent)
                }
                continue
            }
            next = nil
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
            // Static text whose text was read is a leaf: asking for its
            // children would cost an Accessibility call per line for nothing.
            let leaf = info.role == "AXStaticText" && !info.texts.isEmpty
            if depth < limits.maxDepth, !leaf { open.append(OpenNode(node: node, depth: depth)) }
        }
        if result.stopped == nil, cut { result.stopped = .nodes }
        return result
    }

    /// A node whose children the walk is reading.
    private struct OpenNode {
        let node: ScreenNode
        let depth: Int
        /// Fetched, not yet read; the last is next.
        var pending: [ScreenNode] = []
        var fetched = 0
        var exhausted = false
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

    /// Start reading on `queue`; returns at once. `approved` and `root` run on
    /// the queue too (both are Accessibility IPC). `approved` (the app
    /// approved at press still has focus, and is still one OLIV may read) is
    /// asked before the walk and again after it: when it fails, nothing read
    /// is kept.
    static func start(limits: ScreenTextLimits = .init(), queue: DispatchQueue = queue,
                      approved: @escaping () -> Bool,
                      root: @escaping () -> ScreenNode?) -> ScreenContextCapture {
        let capture = ScreenContextCapture()
        queue.async {
            guard !capture.isCancelled, approved(), let node = root() else { capture.finish([]); return }
            let result = ScreenTextWalker.collect(from: node, limits: limits,
                                                  isCancelled: { capture.isCancelled })
            if result.stopped == .cancelled { capture.finish(nil); return }
            capture.finish(approved() ? result.snippets : [])
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

/// The app a capture is approved for at press: its window is the only one
/// read, and the text is kept only while it has focus.
struct ScreenCaptureTarget: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String
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
    /// pipeline on this Mac; the OLIV API and the free trial run it on the
    /// server), outside verbatim apps (`cleanup` is already false there),
    /// password managers and OLIV, with Accessibility granted and no secure
    /// input active. Never for a Command mode instruction: what it edits is
    /// the selection, not the words spoken.
    static func shouldCapture(enabled: Bool, engine: String, mode: DictationMode, cleanup: Bool,
                              frontmostBundleID: String?, ownBundleID: String?,
                              accessibilityTrusted: Bool, secureInput: Bool) -> Bool {
        guard enabled, cleanup, !DictationController.isRemote(engine), mode != .command,
              accessibilityTrusted, !secureInput else { return false }
        guard let app = frontmostBundleID?.lowercased(), !app.isEmpty else { return false }
        if app == ownBundleID?.lowercased() { return false }
        return !passwordManagers.contains(app)
    }

    /// Whether text read for `target` may be used: the app with focus now
    /// (`focused`) is that very process, and it is still not one OLIV skips
    /// (a password manager, a verbatim app, OLIV). Asked around the walk, off
    /// the main thread, so a switch to another app after the press is caught.
    static func stillApproved(_ target: ScreenCaptureTarget, focused: ScreenCaptureTarget?,
                              verbatimApps: Set<String>, ownBundleID: String?) -> Bool {
        guard let focused, focused.pid == target.pid,
              focused.bundleID.lowercased() == target.bundleID.lowercased() else { return false }
        let app = target.bundleID.lowercased()
        return !app.isEmpty && !passwordManagers.contains(app) && !verbatimApps.contains(app)
            && app != ownBundleID?.lowercased()
    }

    static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    static func secureInputActive() -> Bool { IsSecureEventInputEnabled() }

    /// Per-call Accessibility timeout: a hung app answers within this or not at all.
    static let messagingTimeout: Float = 0.05

    /// The frontmost app at press (main thread).
    static func frontmostApp() -> ScreenCaptureTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        return ScreenCaptureTarget(pid: app.processIdentifier, bundleID: bundleID)
    }

    /// The app with keyboard focus now, as Accessibility sees it (any thread).
    static func focusedApp() -> ScreenCaptureTarget? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var pid: pid_t = 0
        guard let app = element(system, kAXFocusedApplicationAttribute),
              AXUIElementGetPid(app, &pid) == .success, pid > 0,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return nil }
        return ScreenCaptureTarget(pid: pid, bundleID: bundleID)
    }

    /// The focused window of `target`'s own process, never whichever app has
    /// focus by the time this runs; nil when it has none, or its focused
    /// element is a password field.
    static func focusedWindow(of target: ScreenCaptureTarget) -> ScreenNode? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = element(app, kAXFocusedUIElementAttribute), !isSecure(focused),
              let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == target.pid else { return nil }
        return AXScreenNode(element: window)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, [kAXRoleAttribute, kAXSubroleAttribute] as CFArray, AXCopyMultipleAttributeOptions(),
            &values) == .success, let list = values as? [Any], list.count == 2 else { return true }
        return list.contains { $0 as? String == "AXSecureTextField" }
    }
}

/// A live Accessibility element. Reads role, subrole and labels in one call;
/// a value only after the role says it is visible text, and never more of it
/// than the walker keeps.
struct AXScreenNode: ScreenNode {
    let element: AXUIElement

    /// The first call's attributes. Never the value: a text area's value is
    /// its whole document.
    static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXNumberOfCharactersAttribute,
    ]
    /// The most of one value copied out of the app: no snippet keeps more.
    static let maxValueChars = ScreenTextLimits().maxSnippetChars

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
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray,
                                                     AXCopyMultipleAttributeOptions(), &values) == .success,
              let list = values as? [Any], list.count == Self.attributes.count else { return ScreenNodeInfo() }
        // A failed attribute comes back as an AXValue error, never a String or number.
        let text = { (i: Int) in list[i] as? String }
        var info = ScreenNodeInfo(role: text(0), subrole: text(1))
        guard let role = info.role else { return info }
        if Self.valueRoles.contains(role), info.subrole != "AXSecureTextField",
           let value = Self.shownValue(role: role, length: list[4] as? Int, cap: Self.maxValueChars,
                                       visibleRange: visibleRange, string: string(in:), value: value) {
            info.texts.append(value)
        }
        if Self.labelRoles.contains(role) { info.texts += [text(2), text(3)].compactMap { $0 } }
        return info
    }

    /// The text a value role shows, copying at most `cap` characters out of
    /// the app. A text area gives its visible range (a document scrolled far
    /// gives only what is on screen); without one, its value only when its
    /// length is known to be within `cap`. Other roles give their value, or
    /// its first `cap` characters when it is longer.
    static func shownValue(role: String, length: Int?, cap: Int,
                           visibleRange: () -> CFRange?, string: (CFRange) -> String?,
                           value: () -> String?) -> String? {
        if role == "AXTextArea" {
            if let range = visibleRange(), range.location >= 0, range.length >= 0,
               let shown = string(CFRange(location: range.location, length: min(range.length, cap))) {
                return shown
            }
            guard let length, length <= cap else { return nil }
            return value()
        }
        if let length, length > cap { return string(CFRange(location: 0, length: cap)) }
        return value()
    }

    private func visibleRange() -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString,
                                            &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func string(in range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var string: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &string) == .success
        else { return nil }
        return string as? String
    }

    private func value() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    func children(from index: Int, max: Int) -> [ScreenNode] {
        var value: CFArray?
        guard max > 0, AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString,
                                                      index, max, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.prefix(max).map(AXScreenNode.init(element:))
    }
}
