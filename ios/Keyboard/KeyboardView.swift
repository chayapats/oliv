import UIKit

/// A local-only keyboard surface. The controller owns document access and language persistence.
/// There is no microphone, network work, document cache, or idle timer in this view.
final class KeyboardView: UIView {
    var onAction: ((KeyboardAction) -> Void)?
    var onShiftChanged: ((KeyboardShiftState) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var onDeleteHoldChanged: ((Bool) -> Void)?
    var onCursorTrackingChanged: ((Bool) -> Void)?
    var canRepeatWords: (() -> Bool)?
    private lazy var haptics = KeyboardHapticFeedback(view: self)
#if DEBUG
    var onHapticRequested: ((KeyboardHapticFeedback.Event, CGFloat) -> Void)? {
        get { haptics.onFeedbackRequested }
        set { haptics.onFeedbackRequested = newValue }
    }
#endif
    /// Forward to UIInputViewController.handleInputModeList(from:with:) for Apple's globe menu.
    var onInputModeList: ((UIView, UIEvent?) -> Void)?

    private(set) var viewState = KeyboardViewState()
    var shiftState: KeyboardShiftState { viewState.shift }
    var language: KeyboardLanguage { viewState.language }
    private(set) var page: KeyboardPage = .letters

    private var rows: [KeyboardRow] = []
    private var keyRows: [[KeyboardKeyButton]] = []
    private var deleteTask: Task<Void, Never>?
    private var deleteRepeat = KeyboardRepeatPolicy(configuration: .responsive)
    private var shiftPress = KeyboardShiftPolicy()
    private var shiftOwner: ObjectIdentifier?
    private var popup: UIView?
    private var popupOwner: ObjectIdentifier?
    private var popupDismissTask: Task<Void, Never>?
    private var popupGeneration: UInt64 = 0
    private weak var lingeringKey: KeyboardKeyButton?
    private var trackingSources: Set<ObjectIdentifier> = []
    private var trackingTargets: [ObjectIdentifier: KeyboardKeyButton] = [:]
    private var suppressedReleases: Set<ObjectIdentifier> = []
    private var deleteOwner: ObjectIdentifier?
    private var performedDeletion: Set<ObjectIdentifier> = []
    private var alternativeLabels: [UILabel] = []
    private var alternativeValues: [String] = []
    private var alternativeSelection = 0
    private var cursorOrigin: CGPoint?
    private var cursorGesture = KeyboardTrackpadGesture()
#if DEBUG
    private var touchDiagnostics = [Int](repeating: 0, count: 7)
    private var deleteDiagnostics = ""
    func setDeleteDiagnostics(_ summary: String) {
        guard summary != deleteDiagnostics else { return }
        deleteDiagnostics = summary
        updateDebugValue()
    }
    private func recordTouchDiagnostic(_ index: Int) {
        touchDiagnostics[index] += 1
        updateDebugValue()
    }
    private func updateDebugValue() {
        let names = ["hit", "beginYes", "beginNo", "down", "up", "outside", "cancel"]
        let touch = zip(names, touchDiagnostics).map { "\($0)=\($1)" }.joined(separator: ",")
        accessibilityValue = touch + "; returnEnabled=\(viewState.returnKeyEnabled)"
            + (deleteDiagnostics.isEmpty ? "" : "; delete: " + deleteDiagnostics)
    }
#endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        clipsToBounds = true
        accessibilityIdentifier = "keyboard.surface"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: KeyboardView, _) in
            view.updateColors()
        }
        rebuildKeys()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ state: KeyboardViewState) {
        var next = state
        // An automatic sentence-capitalization update must not release a user-selected caps lock.
        if viewState.shift == .locked && state.language == viewState.language { next.shift = .locked }
        if state.language == viewState.language, state.keyboardType == viewState.keyboardType,
           let held = shiftPress.heldState { next.shift = held }
        guard next != viewState else { return }
        if next.language != viewState.language || next.keyboardType != viewState.keyboardType {
            page = .letters
            cancelActiveTouches(restoringShift: false)
        }
        viewState = next
#if DEBUG
        updateDebugValue()
#endif
        rebuildKeys()
    }

    /// An explicit reset, unlike apply(_:), can release caps lock.
    func setShiftState(_ shift: KeyboardShiftState) {
        guard viewState.shift != shift else { return }
        viewState.shift = shift
        onShiftChanged?(shift)
        rebuildKeys()
    }

    /// The host clips everything outside our primary view. Reserve enough
    /// space for a full first-row preview, while moving the key plane by the
    /// same amount so its bottom-anchored screen position stays unchanged.
    private func previewHeadroom(for width: CGFloat) -> CGFloat {
        guard !KeyboardLayout.isNumberPad(viewState.keyboardType) else { return 0 }
        return width > 540 ? 0 : 10
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        keyPlaneHeight(for: width) + previewHeadroom(for: width)
    }

    private func keyPlaneHeight(for width: CGFloat) -> CGFloat {
        if width <= 540 {
            if KeyboardLayout.isNumberPad(viewState.keyboardType) {
                let count = CGFloat(KeyboardLayout.rows(for: viewState, page: page).count)
                return 31 + count * 43 + (count - 1) * 11
            }
            // Measured custom-extension wrapper adds its own upper/lower glass
            // padding. Reserve the native header without counting that twice.
            return viewState.language == .thai && page == .letters && !KeyboardLayout.isNumberPad(viewState.keyboardType) ? 241 : 236
        }
        if !KeyboardLayout.isNumberPad(viewState.keyboardType) {
            return viewState.language == .thai && page == .letters ? 207 : 204
        }
        let count = CGFloat(KeyboardLayout.rows(for: viewState, page: page).count)
        return 12 + count * 33 + (count - 1) * 5
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight(for: bounds.width > 0 ? bounds.width : 390))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0, !rows.isEmpty else { return }
        let frames = KeyboardMeasuredGeometry.frames(rows: rows, state: viewState, page: page,
                                                     bounds: bounds, safeArea: safeAreaInsets,
                                                     scale: traitCollection.displayScale)
            .map { $0.map { $0.offsetBy(dx: 0, dy: previewHeadroom(for: bounds.width)) } }
        for (rowIndex, row) in frames.enumerated() {
            for (keyIndex, visible) in row.enumerated() {
                let left = keyIndex == 0 ? bounds.minX : (row[keyIndex - 1].maxX + visible.minX) / 2
                let right = keyIndex + 1 == row.count ? bounds.maxX : (visible.maxX + row[keyIndex + 1].minX) / 2
                let top = rowIndex == 0 ? max(bounds.minY, visible.minY - 1)
                    : ((frames[rowIndex - 1].first?.maxY ?? visible.minY) + visible.minY) / 2
                let bottom = rowIndex + 1 == frames.count ? visible.maxY
                    : (visible.maxY + (frames[rowIndex + 1].first?.minY ?? visible.maxY)) / 2
                let hit = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                let button = keyRows[rowIndex][keyIndex]
                button.frame = hit
                button.keycapFrame = visible.offsetBy(dx: -hit.minX, dy: -hit.minY)
                button.markLabel.usesLandscapeMetrics = bounds.width > 540
                let compactThaiControl = viewState.language == .thai && page == .letters
                    && (button.definition.kind == .shift || button.definition.kind == .backspace)
                button.updateSymbolPointSize(compactThaiControl ? 14.25 : (bounds.width > 540 ? 18 : 19))
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelActiveTouches() }
    }

    func cancelActiveTouches(restoringShift: Bool = true) {
        let restoredShift = shiftPress.cancel()
        shiftOwner = nil
        stopDelete()
        haptics.reset()
        suppressedReleases.formUnion(trackingSources)
        trackingSources.removeAll()
        trackingTargets.removeAll()
        performedDeletion.removeAll()
        if cursorOrigin != nil { onCursorTrackingChanged?(false) }
        cursorOrigin = nil
        cursorGesture.reset()
        removePopup()
        keyRows.flatMap { $0 }.forEach { $0.isHighlighted = false; $0.alpha = 1 }
        if restoringShift, let restoredShift { setShiftState(restoredShift) }
    }

    private func rebuildKeys() {
        let nextRows = KeyboardLayout.rows(for: viewState, page: page)
        // Reuse controls when shift changes. Holding Delete must continue across an autocap update.
        if nextRows.map({ $0.keys.count }) != keyRows.map(\.count) {
            cancelActiveTouches(restoringShift: false)
            keyRows.flatMap { $0 }.forEach { $0.removeFromSuperview() }
            keyRows = nextRows.map { row in
                row.keys.map { definition in
                    let button = KeyboardKeyButton(definition: definition)
                    addSubview(button)
                    return button
                }
            }
        }
        rows = nextRows
        for (rowIndex, row) in rows.enumerated() {
            for (keyIndex, definition) in row.keys.enumerated() {
                configure(keyRows[rowIndex][keyIndex], with: definition)
            }
        }
        updateColors()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onLayoutChanged?()
    }

    private func configure(_ button: KeyboardKeyButton, with key: KeyboardKey) {
        let gesturesChanged = !button.isConfigured || button.definition.kind != key.kind
            || button.definition.alternatives != key.alternatives
        if !button.isConfigured { suppressedReleases.remove(ObjectIdentifier(button)) }
        button.definition = key
        button.markLabel.isHidden = true
        button.markLabel.setPageControl(target: nil, source: page, language: viewState.language)
        button.markLabel.usesThaiKeycapMetrics = viewState.language == .thai && page == .letters
        button.markLabel.englishKeycapPage = button.markLabel.usesThaiKeycapMetrics ? nil : page
        button.languageBadge.text = nil
        button.accessibilityIdentifier = key.identifier
        button.accessibilityTraits = [.button, .keyboardKey]
        button.accessibilityValue = nil
        button.accessibilityHint = nil
        button.accessibilityCustomActions = nil
        button.setImage(nil, for: .normal)
        button.setImage(nil, for: .highlighted)
        button.setTitle(nil, for: .normal)
        // Reset the control's whole target table, then install every action explicitly.
        // Removing only the globe selector with an all-events mask can also discard the
        // release association on the current UIKit runtime.
        button.removeTarget(self, action: nil, for: .allEvents)
        button.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(keyReleased(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(keyReleasedOutside(_:)), for: .touchUpOutside)
        button.addTarget(self, action: #selector(keyCancelled(_:)), for: .touchCancel)
        button.ownsTrackingPoint = { [weak self, weak button] point in
            guard let self, let button else { return false }
            return self.key(at: point) === button
        }
#if DEBUG
        button.onTrackingBegan = { [weak self] accepted in self?.recordTouchDiagnostic(accepted ? 1 : 2) }
#endif
        button.onTrackingMoved = { [weak self, weak button] point in
            guard let self, let button else { return }
            self.moveTracking(from: button, to: point)
        }
        if gesturesChanged { button.gestureRecognizers?.forEach { button.removeGestureRecognizer($0) } }
        var fontSize: CGFloat = 24
        switch key.kind {
        case .character(let text):
            if viewState.language == .english && page == .letters && viewState.shift != .off { fontSize = 22 }
            if KeyboardMarkLabel.isIsolatedThaiMark(text)
                || (button.markLabel.usesThaiKeycapMetrics && KeyboardMarkLabel.hasThaiKeycapMetrics(text))
                || (!button.markLabel.usesThaiKeycapMetrics && KeyboardMarkLabel.hasEnglishKeycapMetrics(text, page: page)) {
                button.markLabel.text = text
                button.markLabel.isHidden = false
            } else {
                button.setTitle(KeyboardLayout.displayText(text), for: .normal)
            }
            button.accessibilityLabel = KeyboardLayout.accessibilityLabel(for: text)
            if gesturesChanged && !key.alternatives.isEmpty {
                let press = UILongPressGestureRecognizer(target: self, action: #selector(alternativesPressed(_:)))
                press.minimumPressDuration = 0.45
                button.addGestureRecognizer(press)
                button.accessibilityHint = "Hold for more characters"
            }
            if !key.alternatives.isEmpty { button.accessibilityHint = "Hold for more characters" }
        case .shift:
            let symbol = viewState.shift == .locked ? "capslock.fill" : (viewState.shift == .on ? "shift.fill" : "shift")
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = "Shift"
            button.accessibilityValue = viewState.shift == .locked ? "Caps Lock" : (viewState.shift == .on ? "On" : "Off")
            button.accessibilityHint = "Double tap quickly to lock uppercase"
            if viewState.shift != .off { button.accessibilityTraits.insert(.selected) }
            button.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Caps Lock") { [weak self] _ in self?.setShiftState(.locked); return true }
            ]
        case .backspace:
            button.setImage(UIImage(systemName: "delete.left"), for: .normal)
            button.setImage(UIImage(systemName: "delete.left.fill"), for: .highlighted)
            button.accessibilityLabel = "Delete"
            button.accessibilityHint = "Hold to delete repeatedly"
        case .space:
            button.languageBadge.text = viewState.language == .thai ? "ก" : "A"
            button.accessibilityLabel = "Space"
            button.accessibilityHint = "Hold and slide to move the insertion point"
            if gesturesChanged {
                let press = UILongPressGestureRecognizer(target: self, action: #selector(spacePressed(_:)))
                press.minimumPressDuration = 0.35
                button.addGestureRecognizer(press)
            }
            button.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Move cursor left") { [weak self] _ in self?.onAction?(.moveCursor(-1)); return true },
                UIAccessibilityCustomAction(name: "Move cursor right") { [weak self] _ in self?.onAction?(.moveCursor(1)); return true },
                UIAccessibilityCustomAction(name: "Move cursor up") { [weak self] _ in self?.onAction?(.moveCursorVertically(-1)); return true },
                UIAccessibilityCustomAction(name: "Move cursor down") { [weak self] _ in self?.onAction?(.moveCursorVertically(1)); return true }
            ]
            fontSize = 15
        case .returnKey:
            let text = KeyboardLayout.returnTitle(viewState.returnKeyType, language: viewState.language)
            if viewState.returnKeyType == .default {
                button.setImage(UIImage(systemName: "return"), for: .normal)
            } else {
                button.setTitle(text, for: .normal)
            }
            button.accessibilityLabel = text
            fontSize = 15
        case .language:
            button.setTitle(viewState.language.otherLanguageLabel, for: .normal)
            button.accessibilityLabel = viewState.language == .thai ? "Switch to English" : "Switch to Thai"
            fontSize = 14
        case .globe:
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.accessibilityLabel = "Next keyboard"
            button.accessibilityHint = "Hold to choose an input method"
            button.addTarget(self, action: #selector(globeEvent(_:event:)), for: .allTouchEvents)
        case .page(let target):
            let text = target == .letters ? (viewState.language == .thai ? "กขค" : "ABC") : (target == .numbers ? "123" : "#+=")
            button.markLabel.text = text
            button.markLabel.isHidden = false
            button.markLabel.setPageControl(target: target, source: page, language: viewState.language)
            button.accessibilityLabel = target == .letters ? "Letters" : (target == .numbers ? "Numbers" : "Symbols")
            fontSize = 20
        }
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.titleLabel?.transform = .identity
        if case .character(let text) = key.kind {
            button.markLabel.font = KeyboardMarkLabel.keycapFont(for: text, size: fontSize)
        } else {
            button.markLabel.font = .systemFont(ofSize: fontSize)
        }
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.65
        button.titleLabel?.numberOfLines = 1
        let compactThaiControl = viewState.language == .thai && page == .letters
            && (key.kind == .shift || key.kind == .backspace)
        button.updateSymbolPointSize(compactThaiControl ? 14.25 : (bounds.width > 540 ? 18 : 19))
        button.isEnabled = key.kind != .returnKey || viewState.returnKeyEnabled
        // Explicit keyboard traits replace UIButton's automatic traits. Keep
        // VoiceOver and UI automation in sync with the actual control state.
        if !button.isEnabled { button.accessibilityTraits.insert(.notEnabled) }
        button.isConfigured = true
    }

    /// Actual control frames cover the spaces between keycaps. Both UIKit and
    /// the extension host can deliver those touches within a control's bounds;
    /// the inset artwork and accessibility frame retain measured key sizes.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
#if DEBUG
        if event?.type == .touches { recordTouchDiagnostic(0) }
#endif
        guard !isHidden, alpha > 0, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        let hit = super.hitTest(point, with: event)
        if hit !== self { return hit }
        return key(at: point) ?? hit
    }

    private func key(at point: CGPoint) -> KeyboardKeyButton? {
        guard bounds.contains(point), let first = keyRows.first?.first,
              let last = keyRows.last?.first,
              point.y >= first.keycapFrameInKeyboard.minY - 1, point.y <= last.keycapFrameInKeyboard.maxY else { return nil }
        let nearestRow = keyRows.min {
            abs(point.y - ($0.first?.keycapFrameInKeyboard.midY ?? 0)) < abs(point.y - ($1.first?.keycapFrameInKeyboard.midY ?? 0))
        }
        // A wide Space/Return key owns its entire visible rectangle. Center
        // distance would incorrectly route its edges to narrower neighbors.
        func edgeDistance(_ frame: CGRect) -> CGFloat {
            max(frame.minX - point.x, point.x - frame.maxX, 0)
        }
        let closest = nearestRow?.first(where: { $0.keycapFrameInKeyboard.contains(point) })
            ?? nearestRow?.min { edgeDistance($0.keycapFrameInKeyboard) < edgeDistance($1.keycapFrameInKeyboard) }
        return closest?.isEnabled == true ? closest : nil
    }

    private func moveTracking(from source: KeyboardKeyButton, to point: CGPoint) {
        let owner = ObjectIdentifier(source)
        guard trackingSources.contains(owner), !suppressedReleases.contains(owner) else { return }
        let next = key(at: point)
        guard trackingTargets[owner] !== next else { return }
        trackingTargets[owner] = next
        if deleteOwner == owner { stopDelete() }
        if let next, case .character(let text) = next.definition.kind {
            showCharacterPopup(text, over: next, owner: owner)
        } else if popupOwner == owner {
            removePopup()
        }
        updateTrackingHighlights()
    }

    private func updateTrackingHighlights() {
        let highlighted = Set(trackingTargets.values.map(ObjectIdentifier.init))
        for button in keyRows.flatMap({ $0 }) {
            button.retainsPressedAppearance = button === lingeringKey
            button.isHighlighted = highlighted.contains(ObjectIdentifier(button))
        }
    }

    @objc private func keyDown(_ button: KeyboardKeyButton) {
#if DEBUG
        recordTouchDiagnostic(3)
#endif
        guard button.isEnabled else { return }
        let touchedAt = ProcessInfo.processInfo.systemUptime
        if button.definition.kind != .backspace { haptics.keyPressed() }
        let owner = ObjectIdentifier(button)
        suppressedReleases.remove(owner)
        performedDeletion.remove(owner)
        trackingSources.insert(owner)
        trackingTargets[owner] = button
        switch button.definition.kind {
        case .shift:
            shiftOwner = owner
            setShiftState(shiftPress.begin(current: viewState.shift, at: ProcessInfo.processInfo.systemUptime))
        case .backspace:
            shiftPress.otherActionCommitted()
            stopDelete()
            deleteOwner = owner
            onDeleteHoldChanged?(true)
            if deleteRepeat.begin(at: touchedAt) != nil {
                onAction?(.backspace)
                performedDeletion.insert(owner)
            }
            haptics.keyPressed()
            deleteTask = Task { @MainActor [weak self] in
                do {
                    while !Task.isCancelled {
                        guard let self, self.deleteOwner == owner,
                              let delay = self.deleteRepeat.delayUntilNext(at: ProcessInfo.processInfo.systemUptime) else { return }
                        try await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled, self.deleteOwner == owner else { return }
                        if let unit = self.deleteRepeat.next(at: ProcessInfo.processInfo.systemUptime,
                                                              supportsWordDeletion: self.canRepeatWords?() ?? true) {
                            self.onAction?(unit == .word ? .backspaceWord : .backspace)
                            self.haptics.deleteRepeated()
                        }
                    }
                } catch { /* Release, cancellation, and view removal stop repetition. */ }
            }
        case .character(let text): showCharacterPopup(text, over: button, owner: owner)
        default: shiftPress.otherActionCommitted()
        }
    }

    @objc private func keyReleased(_ source: KeyboardKeyButton) {
#if DEBUG
        recordTouchDiagnostic(4)
#endif
        let owner = ObjectIdentifier(source)
        guard suppressedReleases.remove(owner) == nil else { return }
        let wasTracking = trackingSources.remove(owner) != nil
        let target = trackingTargets.removeValue(forKey: owner) ?? (wasTracking ? nil : source)
        let alreadyDeleted = performedDeletion.remove(owner) != nil
        let releasedShift = shiftOwner == owner
        if releasedShift { shiftOwner = nil }
        if deleteOwner == owner { stopDelete() }
        if popupOwner == owner { releaseCharacterPopup(owner: owner, over: target) }
        updateTrackingHighlights()
        guard let button = target, button.isEnabled else {
            if releasedShift, let restored = shiftPress.cancel() { setShiftState(restored) }
            return
        }
        defer {
            if releasedShift, let state = shiftPress.end(at: ProcessInfo.processInfo.systemUptime) { setShiftState(state) }
        }
        switch button.definition.kind {
        case .character(let text): insert(text)
        case .backspace:
            if !alreadyDeleted { onAction?(.backspace) }
        case .shift:
            if !releasedShift {
                // Accessibility activation has no physical touch-down event.
                let now = ProcessInfo.processInfo.systemUptime
                setShiftState(shiftPress.begin(current: viewState.shift, at: now))
                if let state = shiftPress.end(at: now) { setShiftState(state) }
            }
        case .space:
            shiftPress.otherActionCommitted()
            onAction?(.space)
        case .returnKey:
            if viewState.returnKeyEnabled { onAction?(.returnKey) }
        case .language: onAction?(.switchLanguage)
        case .globe: if onInputModeList == nil { onAction?(.nextKeyboard) }
        case .page(let next):
            cancelActiveTouches()
            page = next
            rebuildKeys()
        }
    }

    @objc private func keyReleasedOutside(_ source: KeyboardKeyButton) {
#if DEBUG
        recordTouchDiagnostic(5)
#endif
        // UIKit still delivers release to the original control after a slide.
        // Commit the key under the finger, or cancel if it left the key field.
        if trackingTargets[ObjectIdentifier(source)] != nil { keyReleased(source) }
        else { keyCancelled(source) }
    }

    @objc private func keyCancelled(_ button: KeyboardKeyButton) {
#if DEBUG
        recordTouchDiagnostic(6)
#endif
        let owner = ObjectIdentifier(button)
        suppressedReleases.insert(owner)
        trackingSources.remove(owner)
        trackingTargets.removeValue(forKey: owner)
        performedDeletion.remove(owner)
        if shiftOwner == owner {
            shiftOwner = nil
            if let restored = shiftPress.cancel() { setShiftState(restored) }
        }
        if deleteOwner == owner { stopDelete() }
        if alternativeValues.isEmpty && (popupOwner == owner || popupOwner == nil) { removePopup() }
        updateTrackingHighlights()
    }

    @objc private func globeEvent(_ sender: UIButton, event: UIEvent) {
        onInputModeList?(sender, event)
    }

    private func insert(_ text: String) {
        if page == .letters { setShiftState(shiftPress.characterCommitted(current: viewState.shift)) }
        onAction?(.insert(text))
    }

    private func stopDelete() {
        let wasHeld = deleteOwner != nil
        deleteTask?.cancel()
        deleteTask = nil
        deleteOwner = nil
        deleteRepeat.cancel()
        if wasHeld { onDeleteHoldChanged?(false) }
    }

    @objc private func spacePressed(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            if let button = recognizer.view as? KeyboardKeyButton {
                suppressedReleases.insert(ObjectIdentifier(button))
                keyCancelled(button)
            }
            cursorOrigin = point
            cursorGesture.begin(at: point)
            onCursorTrackingChanged?(true)
            recognizer.view?.alpha = 0.6
        case .changed:
            guard cursorOrigin != nil else { return }
            switch cursorGesture.change(to: point) {
            case .vertical(let steps): onAction?(.moveCursorVertically(steps))
            case .horizontal(let steps): onAction?(.moveCursor(steps))
            case nil: break
            }
        case .ended, .cancelled, .failed:
            cursorOrigin = nil
            cursorGesture.reset()
            onCursorTrackingChanged?(false)
            recognizer.view?.alpha = 1
        default: break
        }
    }

    @objc private func alternativesPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? KeyboardKeyButton,
              case .character(let base) = button.definition.kind else { return }
        switch recognizer.state {
        case .began:
            suppressedReleases.insert(ObjectIdentifier(button))
            keyCancelled(button)
            removePopup()
            alternativeValues = [base] + button.definition.alternatives
            showAlternatives(over: button)
        case .changed:
            guard let popup, !alternativeValues.isEmpty else { return }
            let point = recognizer.location(in: popup)
            alternativeSelection = min(alternativeValues.count - 1, max(0, Int(point.x / (popup.bounds.width / CGFloat(alternativeValues.count)))))
            updateAlternativeSelection()
        case .ended:
            guard !alternativeValues.isEmpty else { return }
            let text = alternativeValues[alternativeSelection]
            removePopup()
            insert(text)
        case .cancelled, .failed: removePopup()
        default: break
        }
    }

    private func showCharacterPopup(_ text: String, over button: KeyboardKeyButton, owner: ObjectIdentifier) {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        removePopup()
        let preview = KeyboardPopupView(text: KeyboardLayout.displayText(text), keyFrame: button.keycapFrameInKeyboard,
                                        containment: bounds,
                                        style: .init(fill: palette.popupTop, bottomFill: palette.popupBottom, foreground: palette.text,
                                                     shadowRadius: palette.popupShadowRadius, borderColor: palette.popupBorder,
                                                     usesThaiMetrics: viewState.language == .thai && page == .letters))
        popup = preview
        popupOwner = owner
        addSubview(preview)
    }

    private func releaseCharacterPopup(owner: ObjectIdentifier, over button: KeyboardKeyButton?) {
        guard popup is KeyboardPopupView, alternativeValues.isEmpty, let button,
              case .character = button.definition.kind else { removePopup(); return }
        // Native 60 ms taps leave BOTH the preview and the depressed cap visible
        // for approximately 60 ms after insertion. A new press replaces this
        // feedback immediately; the old task may never dismiss a newer preview.
        let generation = popupGeneration
        lingeringKey = button
        button.retainsPressedAppearance = true
        popupDismissTask?.cancel()
        popupDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) }
            catch { return }
            guard let self, self.popupGeneration == generation, self.popupOwner == owner else { return }
            self.removePopup()
        }
    }

    private func showAlternatives(over button: KeyboardKeyButton) {
        let width = min(max(1, bounds.width - 8), CGFloat(alternativeValues.count) * 37)
        let container = UIView(frame: CGRect(x: min(max(4, button.keycapFrameInKeyboard.midX - width / 2), bounds.width - width - 4),
                                            y: max(2, button.keycapFrameInKeyboard.minY - 51), width: width, height: 48))
        decoratePopup(container)
        let cellWidth = width / CGFloat(alternativeValues.count)
        alternativeLabels = alternativeValues.enumerated().map { index, text in
            let label = UILabel(frame: CGRect(x: CGFloat(index) * cellWidth + 2, y: 3, width: cellWidth - 4, height: 42))
            label.text = KeyboardLayout.displayText(text)
            label.font = .systemFont(ofSize: 25)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.layer.cornerRadius = 5
            label.clipsToBounds = true
            container.addSubview(label)
            return label
        }
        alternativeSelection = 0
        popup = container
        addSubview(container)
        updateAlternativeSelection()
    }

    private func decoratePopup(_ view: UIView) {
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = palette.popupBottom
        (view as? UILabel)?.textColor = palette.text
        view.layer.cornerRadius = 8
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.25
        view.layer.shadowRadius = 4
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    private func updateAlternativeSelection() {
        for (index, label) in alternativeLabels.enumerated() {
            label.backgroundColor = index == alternativeSelection ? .systemBlue : .clear
            label.textColor = index == alternativeSelection ? .white : palette.text
        }
    }

    private func removePopup() {
        popupGeneration &+= 1
        popupDismissTask?.cancel()
        popupDismissTask = nil
        lingeringKey?.retainsPressedAppearance = false
        lingeringKey = nil
        popup?.removeFromSuperview()
        popup = nil
        popupOwner = nil
        alternativeLabels = []
        alternativeValues = []
        alternativeSelection = 0
    }

    private struct Palette {
        var background: UIColor
        var key: UIColor
        var pressedCharacter: UIColor
        var pressedControl: UIColor
        var popupTop: UIColor
        var popupBottom: UIColor
        var popupShadowRadius: CGFloat
        var popupBorder: UIColor
        var text: UIColor
        var badge: UIColor
    }

    private var palette: Palette {
        let dark = viewState.appearance == .dark || (viewState.appearance == .default && traitCollection.userInterfaceStyle == .dark)
        let increasedContrast = traitCollection.accessibilityContrast == .high
        if dark {
            // Native caps transmit the UIKit keyboard material. These opacities
            // match black/white hosts (normal) and the physical iPhone (high
            // contrast); an opaque #444 cap loses that host adaptation.
            return Palette(background: UIColor(white: 32.0 / 255, alpha: 1),
                           key: UIColor.white.withAlphaComponent(increasedContrast ? 0.30 : 0.16),
                           pressedCharacter: UIColor(white: (increasedContrast ? 136.0 : 106.0) / 255, alpha: 1),
                           pressedControl: UIColor(white: (increasedContrast ? 136.0 : 130.0) / 255, alpha: 1),
                           popupTop: UIColor(white: (increasedContrast ? 81.0 : 77.0) / 255, alpha: 1),
                           popupBottom: UIColor(white: (increasedContrast ? 81.0 : 92.0) / 255, alpha: 1),
                           popupShadowRadius: 5, popupBorder: increasedContrast ? UIColor.white.withAlphaComponent(0.35) : .clear,
                           text: .white, badge: UIColor(white: 124.0 / 255, alpha: 1))
        }
        return Palette(background: UIColor(red: 226.0 / 255, green: 227.0 / 255, blue: 232.0 / 255, alpha: 1),
                       key: .white, pressedCharacter: UIColor(white: 229.0 / 255, alpha: 1),
                       pressedControl: increasedContrast
                           ? UIColor(red: 183.0 / 255, green: 185.0 / 255, blue: 191.0 / 255, alpha: 1)
                           : UIColor(red: 197.0 / 255, green: 197.0 / 255, blue: 201.0 / 255, alpha: 1),
                       popupTop: .white, popupBottom: .white, popupShadowRadius: 17, popupBorder: .clear, text: .black,
                       badge: UIColor(white: 204.0 / 255, alpha: 1))
    }

    private func updateColors() {
        let colors = palette
        // Give the remote surface a nonempty hit region while retaining the
        // system keyboard glass underneath the visible keycaps.
        backgroundColor = colors.background.withAlphaComponent(1.0 / 255)
        for button in keyRows.flatMap({ $0 }) {
            var background: UIColor
            var foreground = colors.text
            switch button.definition.kind {
            case .character, .space: background = colors.key
            case .shift: background = viewState.shift == .off ? colors.key : colors.key
            case .returnKey where !viewState.returnKeyEnabled:
                background = colors.key
                foreground = colors.text.withAlphaComponent(0.35)
            case .returnKey where viewState.returnKeyType != .default:
                background = .systemBlue
                foreground = .white
            default: background = colors.key
            }
            button.baseColor = background
            // A character stays depressed until its preview disappears. Other
            // controls use the darker native control highlight immediately.
            if case .character = button.definition.kind { button.pressedColor = colors.pressedCharacter }
            else { button.pressedColor = colors.pressedControl }
            button.backgroundColor = button.isVisuallyPressed ? button.pressedColor : background
            button.setTitleColor(foreground, for: .normal)
            button.setTitleColor(foreground, for: .disabled)
            button.tintColor = foreground
            button.markLabel.textColor = foreground
            button.languageBadge.textColor = colors.badge
            button.keycap.layer.borderWidth = 0
        }
        (popup as? KeyboardPopupView)?.applyColors(fill: colors.popupTop, bottomFill: colors.popupBottom, foreground: colors.text,
                                                      shadowRadius: colors.popupShadowRadius, borderColor: colors.popupBorder)
        if !alternativeLabels.isEmpty {
            popup?.backgroundColor = colors.popupBottom
            updateAlternativeSelection()
        }
    }
}

/// Visible key rectangles measured from the iOS 27 iPhone 17 references at
/// 402 points / 3x. Horizontal adaptation is pixel-aligned; UIKit owns the
/// surrounding keyboard glass and system footer.
private enum KeyboardMeasuredGeometry {
    private static let english: [[CGRect]] = [
        [CGRect(x: 6.667, y: 31.0, width: 33.333, height: 43.0), CGRect(x: 46.0, y: 31.0, width: 33.667, height: 43.0), CGRect(x: 85.667, y: 31.0, width: 33.333, height: 43.0), CGRect(x: 125.0, y: 31.0, width: 33.667, height: 43.0), CGRect(x: 164.667, y: 31.0, width: 33.333, height: 43.0), CGRect(x: 204.0, y: 31.0, width: 33.667, height: 43.0), CGRect(x: 243.667, y: 31.0, width: 33.333, height: 43.0), CGRect(x: 283.0, y: 31.0, width: 33.667, height: 43.0), CGRect(x: 322.667, y: 31.0, width: 33.333, height: 43.0), CGRect(x: 362.0, y: 31.0, width: 33.667, height: 43.0)],
        [CGRect(x: 26.333, y: 85.0, width: 33.333, height: 43.0), CGRect(x: 65.667, y: 85.0, width: 33.667, height: 43.0), CGRect(x: 105.333, y: 85.0, width: 33.333, height: 43.0), CGRect(x: 144.667, y: 85.0, width: 33.667, height: 43.0), CGRect(x: 184.333, y: 85.0, width: 33.333, height: 43.0), CGRect(x: 223.667, y: 85.0, width: 33.667, height: 43.0), CGRect(x: 263.333, y: 85.0, width: 33.333, height: 43.0), CGRect(x: 302.667, y: 85.0, width: 33.667, height: 43.0), CGRect(x: 342.333, y: 85.0, width: 33.333, height: 43.0)],
        [CGRect(x: 6.667, y: 139.0, width: 45.333, height: 43.0), CGRect(x: 65.667, y: 139.0, width: 33.667, height: 43.0), CGRect(x: 105.333, y: 139.0, width: 33.333, height: 43.0), CGRect(x: 144.667, y: 139.0, width: 33.667, height: 43.0), CGRect(x: 184.333, y: 139.0, width: 33.333, height: 43.0), CGRect(x: 223.667, y: 139.0, width: 33.667, height: 43.0), CGRect(x: 263.333, y: 139.0, width: 33.333, height: 43.0), CGRect(x: 302.667, y: 139.0, width: 33.667, height: 43.0), CGRect(x: 350.0, y: 139.0, width: 45.667, height: 43.0)],
        [CGRect(x: 6.667, y: 193.0, width: 43.333, height: 43.0), CGRect(x: 56.0, y: 193.0, width: 43.333, height: 43.0), CGRect(x: 105.333, y: 193.0, width: 191.333, height: 43.0), CGRect(x: 302.667, y: 193.0, width: 93.0, height: 43.0)],
    ]
    private static let thai: [[CGRect]] = [
        [CGRect(x: 6.667, y: 31.0, width: 26.667, height: 37.333), CGRect(x: 39.333, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 72.333, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 105.333, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 138.333, y: 31.0, width: 26.667, height: 37.333), CGRect(x: 171.0, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 204.0, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 237.0, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 270.0, y: 31.0, width: 26.667, height: 37.333), CGRect(x: 302.667, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 335.667, y: 31.0, width: 27.0, height: 37.333), CGRect(x: 368.667, y: 31.0, width: 27.0, height: 37.333)],
        [CGRect(x: 6.667, y: 74.333, width: 26.667, height: 37.0), CGRect(x: 39.333, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 72.333, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 105.333, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 138.333, y: 74.333, width: 26.667, height: 37.0), CGRect(x: 171.0, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 204.0, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 237.0, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 270.0, y: 74.333, width: 26.667, height: 37.0), CGRect(x: 302.667, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 335.667, y: 74.333, width: 27.0, height: 37.0), CGRect(x: 368.667, y: 74.333, width: 27.0, height: 37.0)],
        [CGRect(x: 6.667, y: 117.333, width: 26.667, height: 37.333), CGRect(x: 39.333, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 72.333, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 105.333, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 138.333, y: 117.333, width: 26.667, height: 37.333), CGRect(x: 171.0, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 204.0, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 237.0, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 270.0, y: 117.333, width: 26.667, height: 37.333), CGRect(x: 302.667, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 335.667, y: 117.333, width: 27.0, height: 37.333), CGRect(x: 368.667, y: 117.333, width: 27.0, height: 37.333)],
        [CGRect(x: 6.667, y: 160.667, width: 26.667, height: 37.0), CGRect(x: 39.333, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 72.333, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 105.333, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 138.333, y: 160.667, width: 26.667, height: 37.0), CGRect(x: 171.0, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 204.0, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 237.0, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 270.0, y: 160.667, width: 26.667, height: 37.0), CGRect(x: 302.667, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 335.667, y: 160.667, width: 27.0, height: 37.0), CGRect(x: 368.667, y: 160.667, width: 27.0, height: 37.0)],
        [CGRect(x: 6.667, y: 203.667, width: 43.333, height: 37.333), CGRect(x: 56.0, y: 203.667, width: 43.333, height: 37.333), CGRect(x: 105.333, y: 203.667, width: 191.333, height: 37.333), CGRect(x: 302.667, y: 203.667, width: 93.0, height: 37.333)],
    ]

    // Actual native landscape keyplanes: local width724; UIKit supplies the
    // outer75pt side regions. These are not stretched portrait key widths.
    private static let landscapeEnglish: [[CGRect]] = [
        [CGRect(x: 4.000, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 76.333, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 148.333, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 220.667, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 292.667, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 365.000, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 437.333, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 509.333, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 581.667, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 653.667, y: 50.000, width: 66.333, height: 32.000)],
        [CGRect(x: 40.000, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 112.333, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 184.667, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 256.667, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 329.000, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 401.000, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 473.333, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 545.667, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 617.667, y: 90.000, width: 66.333, height: 32.000)],
        [CGRect(x: 4.000, y: 130.000, width: 88.000, height: 32.000), CGRect(x: 112.333, y: 130.000, width: 66.333, height: 32.000), CGRect(x: 184.667, y: 130.000, width: 66.000, height: 32.000), CGRect(x: 256.667, y: 130.000, width: 66.333, height: 32.000), CGRect(x: 329.000, y: 130.000, width: 66.000, height: 32.000), CGRect(x: 401.000, y: 130.000, width: 66.333, height: 32.000), CGRect(x: 473.333, y: 130.000, width: 66.333, height: 32.000), CGRect(x: 545.667, y: 130.000, width: 66.000, height: 32.000), CGRect(x: 632.000, y: 130.000, width: 88.000, height: 32.000)],
        [CGRect(x: 4.000, y: 170.000, width: 66.333, height: 32.000), CGRect(x: 76.333, y: 170.000, width: 66.000, height: 32.000), CGRect(x: 148.333, y: 170.000, width: 427.333, height: 32.000), CGRect(x: 581.667, y: 170.000, width: 138.333, height: 32.000)],
    ]

    private static let landscapeThai: [[CGRect]] = [
        [CGRect(x: 3.000, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 63.333, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 123.667, y: 50.000, width: 55.000, height: 27.000), CGRect(x: 183.667, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 244.000, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 304.333, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 364.667, y: 50.000, width: 55.000, height: 27.000), CGRect(x: 424.667, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 485.000, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 545.333, y: 50.000, width: 55.333, height: 27.000), CGRect(x: 605.667, y: 50.000, width: 55.000, height: 27.000), CGRect(x: 665.667, y: 50.000, width: 55.333, height: 27.000)],
        [CGRect(x: 3.000, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 63.333, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 123.667, y: 82.000, width: 55.000, height: 27.000), CGRect(x: 183.667, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 244.000, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 304.333, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 364.667, y: 82.000, width: 55.000, height: 27.000), CGRect(x: 424.667, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 485.000, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 545.333, y: 82.000, width: 55.333, height: 27.000), CGRect(x: 605.667, y: 82.000, width: 55.000, height: 27.000), CGRect(x: 665.667, y: 82.000, width: 55.333, height: 27.000)],
        [CGRect(x: 3.000, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 63.333, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 123.667, y: 114.000, width: 55.000, height: 27.000), CGRect(x: 183.667, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 244.000, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 304.333, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 364.667, y: 114.000, width: 55.000, height: 27.000), CGRect(x: 424.667, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 485.000, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 545.333, y: 114.000, width: 55.333, height: 27.000), CGRect(x: 605.667, y: 114.000, width: 55.000, height: 27.000), CGRect(x: 665.667, y: 114.000, width: 55.333, height: 27.000)],
        [CGRect(x: 3.000, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 63.333, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 123.667, y: 146.000, width: 55.000, height: 27.000), CGRect(x: 183.667, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 244.000, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 304.333, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 364.667, y: 146.000, width: 55.000, height: 27.000), CGRect(x: 424.667, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 485.000, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 545.333, y: 146.000, width: 55.333, height: 27.000), CGRect(x: 605.667, y: 146.000, width: 55.000, height: 27.000), CGRect(x: 665.667, y: 146.000, width: 55.333, height: 27.000)],
        [CGRect(x: 3.000, y: 178.000, width: 67.333, height: 27.000), CGRect(x: 75.333, y: 178.000, width: 67.333, height: 27.000), CGRect(x: 147.667, y: 178.000, width: 428.667, height: 27.000), CGRect(x: 581.333, y: 178.000, width: 139.667, height: 27.000)],
    ]

    private static let landscapeNumbers: [[CGRect]] = [
        [CGRect(x: 4.000, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 76.333, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 148.333, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 220.667, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 292.667, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 365.000, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 437.333, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 509.333, y: 50.000, width: 66.333, height: 32.000), CGRect(x: 581.667, y: 50.000, width: 66.000, height: 32.000), CGRect(x: 653.667, y: 50.000, width: 66.333, height: 32.000)],
        [CGRect(x: 4.000, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 76.333, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 148.333, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 220.667, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 292.667, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 365.000, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 437.333, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 509.333, y: 90.000, width: 66.333, height: 32.000), CGRect(x: 581.667, y: 90.000, width: 66.000, height: 32.000), CGRect(x: 653.667, y: 90.000, width: 66.333, height: 32.000)],
        [CGRect(x: 4.000, y: 130.000, width: 88.000, height: 32.000), CGRect(x: 112.333, y: 130.000, width: 95.000, height: 32.000), CGRect(x: 213.333, y: 130.000, width: 95.000, height: 32.000), CGRect(x: 314.333, y: 130.000, width: 95.333, height: 32.000), CGRect(x: 415.667, y: 130.000, width: 95.000, height: 32.000), CGRect(x: 516.667, y: 130.000, width: 95.000, height: 32.000), CGRect(x: 632.000, y: 130.000, width: 88.000, height: 32.000)],
        [CGRect(x: 4.000, y: 170.000, width: 66.333, height: 32.000), CGRect(x: 76.333, y: 170.000, width: 66.000, height: 32.000), CGRect(x: 148.333, y: 170.000, width: 427.333, height: 32.000), CGRect(x: 581.667, y: 170.000, width: 138.333, height: 32.000)],
    ]

    static func frames(rows: [KeyboardRow], state: KeyboardViewState, page: KeyboardPage,
                       bounds: CGRect, safeArea: UIEdgeInsets, scale: CGFloat) -> [[CGRect]] {
        let landscape = bounds.width > 540
        let pixelScale = max(1, scale)
        func aligned(_ frame: CGRect) -> CGRect {
            let x = (frame.minX * pixelScale).rounded() / pixelScale
            let y = (frame.minY * pixelScale).rounded() / pixelScale
            let right = (frame.maxX * pixelScale).rounded() / pixelScale
            let bottom = (frame.maxY * pixelScale).rounded() / pixelScale
            return CGRect(x: x, y: y, width: max(1, right - x), height: max(1, bottom - y))
        }
        if !KeyboardLayout.isNumberPad(state.keyboardType) {
            let thaiLetters = state.language == .thai && page == .letters
            var reference = landscape ? (page != .letters ? landscapeNumbers : (thaiLetters ? landscapeThai : landscapeEnglish))
                : (thaiLetters ? thai : english)
            let referenceWidth: CGFloat = landscape ? 724 : 402
            if page != .letters && !landscape {
                reference[1] = english[0].map { CGRect(x: $0.minX, y: 85, width: $0.width, height: 43) }
                reference[2] = [CGRect(x: 6.667, y: 139, width: 45.333, height: 43)]
                    + [65.667, 121, 176.333, 231.667, 287].map { CGRect(x: $0, y: 139, width: 49.333, height: 43) }
                    + [CGRect(x: 350, y: 139, width: 45.667, height: 43)]
            }
            return rows.enumerated().map { index, row in
                if index < reference.count && reference[index].count == row.keys.count {
                    return reference[index].map {
                        aligned(CGRect(x: $0.minX * bounds.width / referenceWidth, y: $0.minY,
                                       width: $0.width * bounds.width / referenceWidth, height: $0.height))
                    }
                }
                let template = reference[min(index, reference.count - 1)][0]
                return distributed(row, width: bounds.width, y: template.minY, height: template.height,
                                   inset: landscape ? (thaiLetters ? 3 : 4) : 6.667,
                                   gap: landscape && thaiLetters ? 5 : 6).map(aligned)
            }
        }
        let inset = landscape ? max(6, safeArea.left, safeArea.right) : 6.667
        let rowHeight: CGFloat = landscape ? 33 : 43
        let rowGap: CGFloat = landscape ? 5 : 11
        return rows.enumerated().map { index, row in
            distributed(row, width: bounds.width, y: (landscape ? 5 : 31) + CGFloat(index) * (rowHeight + rowGap),
                        height: rowHeight, inset: inset, gap: 6).map(aligned)
        }
    }

    private static func distributed(_ row: KeyboardRow, width: CGFloat, y: CGFloat,
                                    height: CGFloat, inset: CGFloat, gap: CGFloat) -> [CGRect] {
        let available = max(1, width - 2 * inset)
        let rowInset = available * row.horizontalInset
        let unit = max(1, available - 2 * rowInset - gap * CGFloat(row.keys.count - 1))
            / max(1, row.keys.reduce(0) { $0 + $1.width })
        var x = inset + rowInset
        return row.keys.map { key in
            defer { x += unit * key.width + gap }
            return CGRect(x: x, y: y, width: unit * key.width, height: height)
        }
    }
}

private final class KeyboardKeyButton: UIButton {
    var definition: KeyboardKey
    var isConfigured = false
    var baseColor = UIColor.white
    var pressedColor = UIColor.lightGray
    var retainsPressedAppearance = false {
        didSet { backgroundColor = isVisuallyPressed ? pressedColor : baseColor }
    }
    var isVisuallyPressed: Bool { isHighlighted || retainsPressedAppearance }
    var onTrackingMoved: ((CGPoint) -> Void)?
    var ownsTrackingPoint: ((CGPoint) -> Bool)?
#if DEBUG
    var onTrackingBegan: ((Bool) -> Void)?
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = super.beginTracking(touch, with: event)
        onTrackingBegan?(accepted)
        return accepted
    }
#endif
    let keycap = UIView()
    let markLabel = KeyboardMarkLabel()
    let languageBadge = UILabel()
    var keycapFrame: CGRect = .zero { didSet { setNeedsLayout() } }
    var keycapFrameInKeyboard: CGRect { keycapFrame.offsetBy(dx: frame.minX, dy: frame.minY) }
    private var symbolPointSize: CGFloat = 0

    func updateSymbolPointSize(_ size: CGFloat) {
        guard size != symbolPointSize else { return }
        symbolPointSize = size
        setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: .regular), forImageIn: .normal)
        setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: .regular), forImageIn: .highlighted)
    }

    override var backgroundColor: UIColor? {
        get { keycap.backgroundColor }
        set { keycap.backgroundColor = newValue; super.backgroundColor = .clear }
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(keycapFrame, in: self) }
        set { super.accessibilityFrame = newValue }
    }

    init(definition: KeyboardKey) {
        self.definition = definition
        super.init(frame: .zero)
        keycap.layer.cornerRadius = 8
        keycap.layer.cornerCurve = .circular
        keycap.isUserInteractionEnabled = false
        keycap.isAccessibilityElement = false
        keycap.accessibilityIdentifier = "keyboard.keycap"
        addSubview(keycap)
        layer.shadowOpacity = 0
        isMultipleTouchEnabled = false
        adjustsImageWhenHighlighted = false
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center
        markLabel.isUserInteractionEnabled = false
        markLabel.isAccessibilityElement = false
        markLabel.textAlignment = .center
        markLabel.isHidden = true
        addSubview(markLabel)
        languageBadge.font = .systemFont(ofSize: 12, weight: .regular, width: .condensed)
        languageBadge.textAlignment = .center
        languageBadge.isUserInteractionEnabled = false
        languageBadge.isAccessibilityElement = false
        addSubview(languageBadge)
    }

    required init?(coder: NSCoder) { nil }

    override func contentRect(forBounds bounds: CGRect) -> CGRect { keycapFrame }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, let superview, let ownsTrackingPoint else {
            return super.point(inside: point, with: event)
        }
        // Actual control bounds cover the hit cell; ownership still prevents
        // overlapping touch regions from stealing a neighbor's release.
        return ownsTrackingPoint(convert(point, to: superview))
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let continued = super.continueTracking(touch, with: event)
        if let superview { onTrackingMoved?(touch.location(in: superview)) }
        return continued
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch, let superview { onTrackingMoved?(touch.location(in: superview)) }
        super.endTracking(touch, with: event)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isVisuallyPressed ? pressedColor : baseColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIButton lazily inserts its image/title views. The opaque keycap must
        // remain behind those UIKit-owned views after every layout pass.
        sendSubviewToBack(keycap)
        layer.shadowPath = nil
        keycap.frame = keycapFrame
        markLabel.frame = keycapFrame
        languageBadge.frame = CGRect(x: keycapFrame.maxX - 14, y: keycapFrame.maxY - 17, width: 11, height: 14)
    }
}
