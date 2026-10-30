import UIKit
import CryptoKit
import OlivCore

/// The keyboard is an input surface, never an audio engine. It has no microphone
/// or network API and no idle timer. App Intents own explicitly requested audio.
@MainActor
final class KeyboardViewController: UIInputViewController {
    private let keys = KeyboardView()
    private var keyboardHeight: NSLayoutConstraint?
    private var focus: KeyboardFocusLease?
    private var focusRevision: UInt64 = 0
    private var bridgeTask: Task<Void, Never>?
    private var bridgeGeneration: UInt64 = 0
    private var store: KeyboardDeliveryStore?
    private var observations: [OlivDarwinObservation] = []
    private var isVisible = false
    private var applyingResult = false
    private var isUpdatingKeys = false
    private var configuredPrimaryLanguage: String?
    private var lastSpace: Date?
    private var language: KeyboardLanguage = .english
    private var deleteHold: KeyboardDeletionHold?
    private var initialDeleteContext: KeyboardDeletionContext?
    private var deleteHeld = false
    private var keyRefreshTask: Task<Void, Never>?
    private var cursorNavigation = KeyboardCursorNavigation()
    private var cursorTask: Task<Void, Never>?
    private var cursorGeneration: UInt64 = 0
    private var cursorTracking = false
    private var cursorDocumentID: UUID?
    private var queuedCursorDirections: [KeyboardCursorNavigation.Direction] = []
#if DEBUG
    private var recordedHoldRejections: Set<KeyboardWordDeletionSession.HoldRejection> = []
#endif
    private lazy var wordDeletion: KeyboardWordDeletionSession = {
        let session = KeyboardWordDeletionSession(
            readContext: { [weak self] in
                guard let self, self.deleteHold != nil else { return nil }
                // Validate the hold and pulse against one fresh observation.
                return self.activeDeleteContext()
            },
            deleteBackward: { [weak self] in
                guard let self, self.deleteHeld else { return }
                // readContext just validated hold and pulse against the same
                // observation; no await separates that check from this edit.
                self.textDocumentProxy.deleteBackward()
            })
        session.onCompletion = { [weak self] documentID in
            guard let self, self.isVisible,
                  self.hostDocumentID == documentID else { return }
            self.updateKeys()
        }
#if DEBUG
        session.onDiagnostic = { [weak self] in self?.keys.setDeleteDiagnostics($0) }
#endif
        return session
    }()

    override func loadView() {
        let surface = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        surface.allowsSelfSizing = true
        inputView = surface
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        language = KeyboardLanguage(rawValue: UserDefaults.standard.string(forKey: "keyboardLanguage") ?? "en") ?? .english
        keys.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keys)
        NSLayoutConstraint.activate([
            keys.topAnchor.constraint(equalTo: view.topAnchor),
            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 260)
        height.priority = .init(999)
        height.isActive = true
        keyboardHeight = height
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _) in
            controller.updateKeys()
        }
        keys.onAction = { [weak self] in self?.handle($0) }
        keys.onDeleteHoldChanged = { [weak self] held in self?.deleteHoldChanged(held) }
        keys.canRepeatWords = { [weak self] in
            self?.wordDeletion.supportsWordDeletion ?? false
        }
        keys.onCursorTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.cursorTracking = tracking
            if tracking { self.cancelCursorNavigation() }
            else if self.cursorTask == nil { self.cursorNavigation.reset() }
        }
        keys.onLayoutChanged = { [weak self] in self?.view.setNeedsLayout() }
        keys.onInputModeList = { [weak self] sender, event in
            guard let self, let event else { return }
            self.handleInputModeList(from: sender, with: event)
        }
        observations = [
            OlivDarwinObservation(name: KeyboardBridgeEnvironment.focusRefreshNotification) { [weak self] in
                Task { @MainActor [weak self] in self?.requestBridgeEvent(.refresh) }
            },
            OlivDarwinObservation(name: KeyboardBridgeEnvironment.deliveryNotification) { [weak self] in
                Task { @MainActor [weak self] in self?.requestBridgeEvent(.delivery) }
            }
        ]
        updateKeys()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        CaptureDiagnostics.record(event: .keyboardVisible)
        requestBridgeEvent(.refresh)
        updateKeys()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isVisible = false
        keyRefreshTask?.cancel()
        keyRefreshTask = nil
        cancelCursorNavigation()
        deleteHeld = false
        initialDeleteContext = nil
        wordDeletion.cancel(resetFallback: true)
        deleteHold = nil
        invalidateFocus()
        keys.cancelActiveTouches()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width.isFinite, width > 0 else { return }
        let height = keys.preferredHeight(for: width)
        if keyboardHeight?.constant != height { keyboardHeight?.constant = height }
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        // Invalidate immediately, before a completion could reach a changed field.
        if !applyingResult { invalidateFocus() }
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshAfterEdit()
        if !applyingResult { invalidateFocus() }
    }

    override func selectionWillChange(_ textInput: (any UITextInput)?) {
        super.selectionWillChange(textInput)
        if !applyingResult { invalidateFocus() }
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        refreshAfterEdit()
        if !applyingResult { invalidateFocus() }
    }

    /// Nil while no host text session is attached. Never read
    /// `textDocumentProxy.documentIdentifier` directly; see KeyboardHostDocument.
    private var hostDocumentID: UUID? { KeyboardHostDocument.identifier(of: textDocumentProxy) }

    private var canDeliver: Bool {
        guard isVisible, hasFullAccess, viewIfLoaded?.window != nil else { return false }
        if let scene = view.window?.windowScene, scene.activationState != .foregroundActive { return false }
        return hostDocumentID != nil
    }

    private func recordUnavailable() {
        let detail: CaptureDiagnostics.Detail
        if !isVisible { detail = .notVisible }
        else if !hasFullAccess { detail = .fullAccessOff }
        else if viewIfLoaded?.window == nil { detail = .noWindow }
        else if let scene = view.window?.windowScene, scene.activationState != .foregroundActive {
            detail = .sceneInactive
        } else { detail = .noDocument }
        CaptureDiagnostics.record(event: .keyboardUnavailable, detail: detail)
    }

    private func deliveryStore() -> KeyboardDeliveryStore? {
        guard hasFullAccess else { return nil }
        if let store { return store }
        guard let directory = KeyboardBridgeEnvironment.directory else {
            CaptureDiagnostics.record(event: .bridgeUnavailable)
            return nil
        }
        do { store = try KeyboardDeliveryStore(directory: directory) }
        catch { CaptureDiagnostics.record(event: .bridgeUnavailable, error: error) }
        return store
    }

    private func contextHash() -> String {
        // Hash only; never persist or transmit text typed into a host app.
        let components = [textDocumentProxy.documentContextBeforeInput,
                          textDocumentProxy.selectedText,
                          textDocumentProxy.documentContextAfterInput]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum BridgeEvent { case refresh, delivery }
    private enum BridgeAttempt { case complete, busy }

    /// Retry only an explicit event, at most twice over 10 ms. Any edit or view
    /// change cancels the retry; there is no recurring focus or typing timer.
    private func requestBridgeEvent(_ event: BridgeEvent) {
        cancelBridgeEvent()
        let generation = bridgeGeneration
        guard performBridgeEvent(event) == .busy else { return }
        bridgeTask = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch { return }
                guard let self, !Task.isCancelled, self.bridgeGeneration == generation else { return }
                if self.performBridgeEvent(event) == .complete {
                    self.bridgeTask = nil
                    return
                }
            }
            if let self, self.bridgeGeneration == generation { self.bridgeTask = nil }
        }
    }

    private func cancelBridgeEvent() {
        bridgeGeneration &+= 1
        bridgeTask?.cancel()
        bridgeTask = nil
    }

    private func performBridgeEvent(_ event: BridgeEvent) -> BridgeAttempt {
        guard canDeliver else { recordUnavailable(); retireFocus(); return .complete }
        // Editing retires the target immediately. A delayed delivery signal may
        // not recreate it; only the app's new refresh handshake can bind a field.
        if event == .delivery, focus == nil { return .complete }
        guard refreshFocus() == .complete else { return .busy }
        return event == .delivery ? receiveDictation() : .complete
    }

    private func refreshFocus() -> BridgeAttempt {
        guard canDeliver else { recordUnavailable(); retireFocus(); return .complete }
        guard let store = deliveryStore(), let documentID = hostDocumentID else { retireFocus(); return .complete }
        let hash = contextHash()
        if focus?.documentID != documentID || focus?.contextHash != hash {
            retireFocus()
        }
        let id = focus?.id ?? UUID()
        do {
            focus = try store.publishFocus(id: id, documentID: documentID,
                revision: focusRevision, contextHash: hash)
            CaptureDiagnostics.record(event: .keyboardFocusPublished)
        } catch KeyboardDeliveryError.storageUnavailable {
            // Preserve the unchanged local identity while a bounded retry waits
            // for the other process. Never reuse it after an edit/invalidation.
            return .busy
        } catch {
            CaptureDiagnostics.record(event: .bridgeUnavailable, error: error)
            focus = nil
            focusRevision &+= 1
        }
        return .complete
    }

    private func invalidateFocus() {
        cancelBridgeEvent()
        retireFocus()
    }

    private func retireFocus() {
        // The first edit after publication invalidates shared state. Subsequent
        // typing only advances the local revision until an explicit handshake.
        if let id = focus?.id {
            do { try store?.invalidateFocus(id: id) }
            catch { CaptureDiagnostics.record(event: .bridgeUnavailable, error: error) }
            CaptureDiagnostics.record(event: .keyboardFocusInvalidated)
        }
        focus = nil
        focusRevision &+= 1
    }

    private func receiveDictation() -> BridgeAttempt {
        guard canDeliver else { recordUnavailable(); retireFocus(); return .complete }
        guard let focus, let store,
              focus.documentID == hostDocumentID,
              focus.contextHash == contextHash() else { retireFocus(); return .complete }
        let delivery: KeyboardDelivery
        do {
            guard let pending = try store.consume(for: focus) else { return .complete }
            delivery = pending
        } catch KeyboardDeliveryError.storageUnavailable {
            return .busy
        } catch {
            CaptureDiagnostics.record(event: .bridgeUnavailable, error: error)
            return .complete
        }
        // No await between context verification, one-shot claim, and insertion.
        // If the process ends between claim and insertion, History remains the fallback.
        applyingResult = true
        retireFocus()
        textDocumentProxy.insertText(delivery.text)
        applyingResult = false
        CaptureDiagnostics.record(event: .keyboardDelivered)
        updateKeys()
        return .complete
    }

    private func handle(_ action: KeyboardAction) {
        if action != .backspaceWord { wordDeletion.cancel() }
        if case .moveCursorVertically = action {} else { cancelCursorNavigation() }
        switch action {
        case .switchLanguage:
            language = language == .english ? .thai : .english
            UserDefaults.standard.set(language.rawValue, forKey: "keyboardLanguage")
            lastSpace = nil
            updateKeys()
        case .nextKeyboard:
            invalidateFocus()
            advanceToNextInputMode()
        case .insert(let text):
            invalidateFocus()
            lastSpace = nil
            textDocumentProxy.insertText(text)
            updateKeys(afterCharacter: true)
        case .backspace:
            if deleteHeld {
                let accepted = initialDeleteContext ?? activeDeleteContext()
                initialDeleteContext = nil
                guard accepted != nil else { return }
            }
            invalidateFocus()
            lastSpace = nil
            textDocumentProxy.deleteBackward()
            refreshAfterEdit()
        case .backspaceWord:
            invalidateFocus()
            lastSpace = nil
            deleteRepeatedWords()
            refreshAfterEdit()
        case .space:
            invalidateFocus()
            let now = Date()
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            let ordinaryText = ![UIKeyboardType.emailAddress, .URL, .webSearch].contains(textDocumentProxy.keyboardType ?? .default)
            if language == .english, ordinaryText, let lastSpace, now.timeIntervalSince(lastSpace) < 0.32,
               before.hasSuffix(" "), let previous = before.dropLast().last,
               previous.isLetter || previous.isNumber {
                textDocumentProxy.deleteBackward()
                textDocumentProxy.insertText(". ")
                self.lastSpace = nil
            } else {
                textDocumentProxy.insertText(" ")
                lastSpace = now
            }
            updateKeys()
        case .returnKey:
            invalidateFocus()
            lastSpace = nil
            textDocumentProxy.insertText("\n")
            updateKeys()
        case .moveCursorVertically(let lines):
            invalidateFocus()
            lastSpace = nil
            moveCursorVertically(lines)
        case .moveCursor(let offset):
            invalidateFocus()
            lastSpace = nil
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            updateKeys()
        }
    }

    private func cursorContext() -> KeyboardCursorNavigation.Context? {
        guard let documentID = hostDocumentID else { return nil }
        let proxy = textDocumentProxy
        return .init(documentID: documentID, before: proxy.documentContextBeforeInput,
                     after: proxy.documentContextAfterInput, selected: proxy.selectedText)
    }

    private func cancelCursorNavigation() {
        cursorGeneration &+= 1
        cursorTask?.cancel()
        cursorTask = nil
        queuedCursorDirections.removeAll()
        cursorDocumentID = nil
        cursorNavigation.reset()
    }

    private func moveCursorVertically(_ lines: Int) {
        guard lines != 0, isVisible, let documentID = hostDocumentID else { return }
        if let cursorDocumentID, cursorDocumentID != documentID { cancelCursorNavigation() }
        cursorDocumentID = documentID
        let direction: KeyboardCursorNavigation.Direction = lines < 0 ? .up : .down
        // Keep gesture work bounded; never replay a long backlog after a busy host.
        for _ in 0..<min(4, abs(lines)) where queuedCursorDirections.count < 4 {
            queuedCursorDirections.append(direction)
        }
        guard cursorTask == nil else { return }
        let generation = cursorGeneration
        cursorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.cursorGeneration == generation {
                    self.cursorTask = nil
                    self.cursorDocumentID = nil
                    if !self.cursorTracking { self.cursorNavigation.reset() }
                    if self.isVisible { self.updateKeys() }
                }
            }
            while !self.queuedCursorDirections.isEmpty {
                guard !Task.isCancelled, self.cursorGeneration == generation, self.isVisible else { return }
                let direction = self.queuedCursorDirections.removeFirst()
                let layout = KeyboardCursorNavigation.Layout(
                    estimatedLineWidth: max(40, self.view.bounds.width - 32), font: .systemFont(ofSize: 17))
                guard let context = self.cursorContext(), context.documentID == documentID else {
                    self.queuedCursorDirections.removeAll(); return
                }
                var step = self.cursorNavigation.beginVertical(direction, context: context, layout: layout)
                var deadline = ProcessInfo.processInfo.systemUptime + 0.06
                var finished = false
                // At most three normal adjustments and one compensating edge
                // move; fresh snapshots must acknowledge each before proceeding.
                for _ in 0..<80 {
                    guard !Task.isCancelled, self.cursorGeneration == generation, self.isVisible else { return }
                    switch step {
                    case .adjust(let offset):
                        self.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
                        deadline = ProcessInfo.processInfo.systemUptime + 0.06
                    case .wait:
                        if ProcessInfo.processInfo.systemUptime >= deadline {
                            guard let context = self.cursorContext() else { step = .unavailable; continue }
                            step = self.cursorNavigation.timeout(context: context)
                            continue
                        }
                    case .completed:
                        finished = true
                    case .unavailable:
                        self.queuedCursorDirections.removeAll()
                        self.cursorNavigation.reset()
                        finished = true
                    }
                    if finished { break }
                    // A real runloop opportunity lets remote UIKit update its
                    // bounded paragraph context and keeps typing/cancel responsive.
                    do { try await Task.sleep(for: .milliseconds(4)) } catch { return }
                    guard let context = self.cursorContext() else { step = .unavailable; continue }
                    step = self.cursorNavigation.advance(context: context)
                }
                if !finished {
                    self.queuedCursorDirections.removeAll()
                    self.cursorNavigation.reset()
                    return
                }
            }
        }
    }

    private func deleteHoldChanged(_ held: Bool) {
#if DEBUG
        if held { recordedHoldRejections.removeAll() }
#endif
        wordDeletion.cancel(resetFallback: true)
        deleteHeld = held
        initialDeleteContext = held ? currentDeleteContext() : nil
        deleteHold = initialDeleteContext.map(KeyboardDeletionHold.init(context:))
        // A cancelled partial pulse cannot run its completion callback. Refresh
        // the current host after cancellation so Shift/Return never stay stale.
        if !held {
            keyRefreshTask?.cancel()
            keyRefreshTask = nil
            if isVisible { updateKeys() }
        }
    }

    private func currentDeleteContext() -> KeyboardDeletionContext? {
        guard isVisible, viewIfLoaded?.window != nil, let documentID = hostDocumentID else { return nil }
        let proxy = textDocumentProxy
        return KeyboardDeletionContext(documentID: documentID,
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            selected: proxy.selectedText)
    }

    private func activeDeleteContext() -> KeyboardDeletionContext? {
        guard var held = deleteHold else { return nil }
        let expected = held.validationContext
        let current = currentDeleteContext()
        let accepted = held.accepts(current)
        deleteHold = held
        guard accepted else {
            wordDeletion.cancel()
#if DEBUG
            recordHoldRejection(held: expected, current: current)
#endif
            return nil
        }
        return current
    }

#if DEBUG
    private func recordHoldRejection(held: KeyboardDeletionContext?, current: KeyboardDeletionContext?) {
        guard let held else { return }
        func record(_ reason: KeyboardWordDeletionSession.HoldRejection) {
            if recordedHoldRejections.insert(reason).inserted { wordDeletion.recordHoldRejection(reason) }
        }
        guard let current else { record(.holdUnavailable); return }
        if held.documentID != current.documentID { record(.holdDocument) }
        if !KeyboardDeletionContext.sameScalars(held.after, current.after) { record(.holdAfter) }
        if current.selected?.isEmpty == false,
           !KeyboardDeletionContext.sameScalars(held.selected, current.selected) { record(.holdSelection) }
        if held.before == nil, current.before != nil { record(.holdBeforeNilToValue) }
        if held.before != nil, current.before == nil { record(.holdBeforeValueToNil) }
        if held.after == nil, let after = current.after {
            record(after.isEmpty ? .holdAfterNilToEmpty : .holdAfterNilToValue)
        }
        if let after = held.after, current.after == nil {
            record(after.isEmpty ? .holdAfterEmptyToNil : .holdAfterValueToNil)
        }
    }
#endif

    private func deleteRepeatedWords() {
        // No new pulse starts against an unacknowledged, timed-out context.
        // The view uses character cadence while that context remains stale.
        if !wordDeletion.start(language: language.rawValue) {
            guard activeDeleteContext() != nil else { return }
            textDocumentProxy.deleteBackward()
        }
    }

    private func refreshAfterEdit() {
        guard deleteHeld else { updateKeys(); return }
        guard keyRefreshTask == nil else { return }
        keyRefreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.keyRefreshTask = nil
            self.updateKeys()
        }
    }

    private func updateKeys(afterCharacter: Bool = false) {
        guard isViewLoaded, !isUpdatingKeys else { return }
        isUpdatingKeys = true
        defer { isUpdatingKeys = false }
        // UIKit may request updates while constructing the extension, before a
        // host connection exists. Render usable defaults without querying it.
        guard isVisible, viewIfLoaded?.window != nil else {
            keys.apply(KeyboardViewState(language: language, shift: .off,
                keyboardType: .default, returnKeyType: .default,
                needsInputModeSwitchKey: true, appearance: .default))
            return
        }
        let primaryLanguage = language == .thai ? "th" : "en-US"
        if configuredPrimaryLanguage != primaryLanguage {
            // Set the cache first: UIKit can synchronously call textDidChange
            // while updating the input language. Reassigning it on every text
            // callback can also create an asynchronous update loop.
            configuredPrimaryLanguage = primaryLanguage
            self.primaryLanguage = primaryLanguage
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let capitalized: Bool
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: capitalized = false
        case .allCharacters: capitalized = true
        case .words: capitalized = before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            capitalized = before.isEmpty || before.hasSuffix("\n")
                || (before.last?.isWhitespace == true && trimmed.last.map { ".!?".contains($0) } == true)
        @unknown default: capitalized = false
        }
        let shift: KeyboardShiftState = language == .english && capitalized
            && (!afterCharacter || textDocumentProxy.autocapitalizationType == .allCharacters) ? .on : .off
        let appearance = textDocumentProxy.keyboardAppearance ?? .default
        // The host may request a dark keyboard in a light interface (or the
        // reverse). Keep UIKit's keyboard material and our keycaps in the same
        // appearance, including when a new field returns to the default.
        let materialStyle: UIUserInterfaceStyle
        switch appearance {
        case .dark: materialStyle = .dark
        case .light: materialStyle = .light
        default: materialStyle = .unspecified
        }
        if inputView?.overrideUserInterfaceStyle != materialStyle {
            inputView?.overrideUserInterfaceStyle = materialStyle
        }
        keys.apply(KeyboardViewState(language: language, shift: shift,
            keyboardType: textDocumentProxy.keyboardType ?? .default,
            returnKeyType: textDocumentProxy.returnKeyType ?? .default,
            needsInputModeSwitchKey: needsInputModeSwitchKey,
            appearance: appearance,
            returnKeyEnabled: textDocumentProxy.enablesReturnKeyAutomatically != true || textDocumentProxy.hasText))
    }
}
