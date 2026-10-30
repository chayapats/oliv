#if DEBUG
import SwiftUI
import UIKit
import WebKit
import Observation

/// The delegate mask overrides the Info.plist orientation mask for the visual
/// fixture only. This type and its app adaptor are absent from Release builds.
@MainActor
final class KeyboardReferenceAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ProcessInfo.processInfo.arguments.contains("--keyboard-visual-reference") ? .allButUpsideDown : .portrait
    }
}

/// A native host for the actual extension, with explicitly synthetic recording/server.
/// This entire harness is excluded from Release builds.
struct KeyboardTestHostView: View {
    @Bindable var model: AppModel
    @State private var firstText = ""
    @State private var secondText = ""

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--real-audio-background-test") {
            RealAudioBackgroundTestView()
        } else if ProcessInfo.processInfo.arguments.contains("--keyboard-visual-reference") {
            KeyboardVisualReferenceHostView()
        } else {
            keyboardContent
        }
    }

    private var keyboardContent: some View {
        VStack(spacing: 12) {
            Text("Keyboard test · simulated audio and server")
                .font(.caption).foregroundStyle(.orange)
            Text(model.phase.rawValue)
                .accessibilityIdentifier("keyboardFixturePhase")
            HStack {
                Button("Start") { Task { try? await model.startFromIntent() } }
                    .accessibilityIdentifier("keyboardFixtureStart")
                Button("Finish") { Task { await model.stopFromIntent() } }
                    .accessibilityIdentifier("keyboardFixtureFinish")
                Button("Cancel") { Task { await model.cancel() } }
                    .accessibilityIdentifier("keyboardFixtureCancel")
            }
            .buttonStyle(.bordered)
            Text("First field").font(.caption)
            KeyboardHostTextView(text: $firstText, identifier: "keyboardHostFirst")
                .frame(height: 90)
            Text("Second field").font(.caption)
            KeyboardHostTextView(text: $secondText, identifier: "keyboardHostSecond")
                .frame(height: 90)
            if let message = model.message { Text(message).font(.caption).lineLimit(2) }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// One native field, shared by Apple and OLIV captures. This has no capture or
/// server actions; appearance/type changes preserve the same UITextView.
private struct KeyboardVisualReferenceHostView: View {
    @Environment(\.colorScheme) private var hostColorScheme
    @Environment(\.colorSchemeContrast) private var hostContrast
    @Environment(\.dynamicTypeSize) private var hostDynamicTypeSize
    @State private var text = ReferenceTextTelemetry.seed
    @State private var dark: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reference-host-light") { return false }
        return arguments.contains("--reference-dark") || arguments.contains("--reference-host-dark")
    }()
    @State private var inputKind = ReferenceInputKind.launchValue
    @State private var telemetry = ReferenceTextTelemetry()
    @State private var exportedTelemetry = ""
    @State private var focusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard visual reference").font(.headline)
            HStack {
                Button("Light") { dark = false }
                    .accessibilityIdentifier("referenceLight")
                Button("Dark") { dark = true }
                    .accessibilityIdentifier("referenceDark")
                Button("Clear") { text = "" }
                    .accessibilityIdentifier("referenceClear")
                Spacer()
                Picker("Type", selection: $inputKind) {
                    ForEach(ReferenceInputKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .accessibilityIdentifier("referenceType")
            }
            .buttonStyle(.bordered)
            Text("\(ReferenceHostKind.launchValue.title) · \(inputKind.rawValue) · \(dark ? "dark" : "light")")
                .font(.caption.monospaced()).accessibilityIdentifier("referenceConfiguration")
                .accessibilityValue(platformMetadata)
            referenceEditor.frame(height: 130)
            if ReferenceHostKind.isMultiHostTest {
                Text("Synthetic host acknowledgement")
                    .font(.caption)
                    .accessibilityIdentifier("referenceHostState")
                    .accessibilityValue(telemetry.snapshot)
            }
            if ReferenceTextTelemetry.isEnabled {
                Button("Prepare synthetic timing") {
                    telemetry.reset()
                    text = ReferenceTextTelemetry.seed
                    exportedTelemetry = ""
                    focusRequest += 1
                }
                .accessibilityIdentifier("referencePrepareTelemetry")
                Button("Export synthetic text timing") {
                    exportedTelemetry = telemetry.export(text: text)
                }
                .accessibilityIdentifier("referenceExportTelemetry")
                .accessibilityValue(exportedTelemetry)
            }
            Text("Choose an already enabled keyboard with the system globe. No audio or network is used.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
        .preferredColorScheme(dark ? .dark : .light)
    }

    @ViewBuilder
    private var referenceEditor: some View {
        switch ReferenceHostKind.launchValue {
        case .textView:
            ReferenceNativeTextView(text: $text, dark: dark, inputKind: inputKind,
                                    telemetry: telemetry, focusRequest: focusRequest)
        case .textField:
            ReferenceNativeTextField(text: $text, dark: dark, inputKind: inputKind,
                                     telemetry: telemetry, focusRequest: focusRequest)
        case .webTextarea, .webContenteditable:
            ReferenceWebTextView(text: $text, dark: dark, hostKind: ReferenceHostKind.launchValue,
                                 telemetry: telemetry, focusRequest: focusRequest)
        }
    }

    /// Public platform values only, attached to an existing label so collecting
    /// the metadata does not add a control or change the reference geometry.
    private var platformMetadata: String {
        let values: [String: Any] = [
            "hostColorScheme": hostColorScheme == .dark ? "dark" : "light",
            "hostColorSchemeContrast": hostContrast == .increased ? "increased" : "standard",
            "hostDynamicTypeSize": String(describing: hostDynamicTypeSize),
            "darkerSystemColorsEnabled": UIAccessibility.isDarkerSystemColorsEnabled,
            "reduceTransparencyEnabled": UIAccessibility.isReduceTransparencyEnabled,
            "reduceMotionEnabled": UIAccessibility.isReduceMotionEnabled,
            "boldTextEnabled": UIAccessibility.isBoldTextEnabled,
            "voiceOverRunning": UIAccessibility.isVoiceOverRunning,
            "hostKind": ReferenceHostKind.launchValue.rawValue
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Explicit fixture data only. No per-event disk I/O or idle work; export is a
/// separate action after the gesture so measurement does not fsync each edit.
@MainActor
@Observable
private final class ReferenceTextTelemetry {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--reference-telemetry") }
    static var seed: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--reference-seed"),
              arguments.indices.contains(index + 1) else { return "" }
        let phrase: String
        switch arguments[index + 1] {
        case "english-short": return "Bright green birds fly together."
        case "cursor-blank": return "qqqqqq\n\nqqqqqq"
        case "cursor-wrap": return String(repeating: "simple words ", count: 20)
        case "cursor-lines": return "qqqqqq\nqqqqqq\nqqqqqq"
        case "cursor-unicode": return "ab👩🏽‍💻กิcd\n123456\nxyzzzz"
        case "english": phrase = "The small green bird sings beside the quiet river. "
        case "thai": phrase = "วันนี้อากาศดี เราจะเดินทางไปสวนสาธารณะด้วยกันครับ "
        default: return ""
        }
        return String(repeating: phrase, count: 12)
    }

    private let createdUptime = ProcessInfo.processInfo.systemUptime
    private let createdEpoch = Date().timeIntervalSince1970
    private var events: [[String: Any]] = []
    private var dropped = 0
    private(set) var readyGeneration = 0
    private(set) var acknowledgedText = ""
    private(set) var acknowledgements = 0
    private(set) var failure = ""

    func reset() {
        events.removeAll(keepingCapacity: true)
        dropped = 0
        readyGeneration = 0
        acknowledgedText = ""
        acknowledgements = 0
        failure = ""
    }

    func ready(generation: Int, text: String) {
        readyGeneration = generation
        acknowledgedText = text
        record("fixture-ready", text: text)
    }

    func fail(_ description: String) { failure = description }

    var snapshot: String {
        let object: [String: Any] = [
            "hostKind": ReferenceHostKind.launchValue.rawValue,
            "readyGeneration": readyGeneration,
            "acknowledgements": acknowledgements,
            "text": acknowledgedText,
            "failure": failure
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func record(_ kind: String, text: String, range: NSRange? = nil, replacement: String? = nil,
                extra: [String: Any] = [:]) {
        guard Self.isEnabled else { return }
        if kind == "changed" {
            acknowledgedText = text
            acknowledgements += 1
        }
        guard events.count < 1_024 else { dropped += 1; return }
        var event: [String: Any] = [
            "kind": kind, "uptime": ProcessInfo.processInfo.systemUptime,
            "epoch": Date().timeIntervalSince1970,
            "characters": text.count, "unicodeScalars": text.unicodeScalars.count,
            "utf16": text.utf16.count, "remainingText": String(text.prefix(2_048))
        ]
        if let range { event["rangeLocation"] = range.location; event["rangeLength"] = range.length }
        if let replacement { event["replacementUTF16"] = replacement.utf16.count }
        for (key, value) in extra { event[key] = value }
        events.append(event)
    }

    func export(text: String) -> String {
        record("export", text: text)
        let object: [String: Any] = [
            "fixtureOnly": true, "clock": "ProcessInfo.systemUptime seconds",
            "createdUptime": createdUptime, "createdEpoch": createdEpoch,
            "events": events, "droppedEvents": dropped,
            "hostKind": ReferenceHostKind.launchValue.rawValue,
            "readyGeneration": readyGeneration,
            "acknowledgements": acknowledgements, "failure": failure
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OLIVKeyboardReferences", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("text-telemetry.json"), options: .atomic)
        return json
    }
}

private enum ReferenceHostKind: String {
    case textView = "textview"
    case textField = "textfield"
    case webTextarea = "web-textarea"
    case webContenteditable = "web-contenteditable"

    static var isMultiHostTest: Bool {
        ProcessInfo.processInfo.arguments.contains("--reference-multi-host-test")
    }
    static var launchValue: Self {
        let arguments = ProcessInfo.processInfo.arguments
        guard isMultiHostTest, let index = arguments.firstIndex(of: "--reference-host-kind"),
              arguments.indices.contains(index + 1) else { return .textView }
        return Self(rawValue: arguments[index + 1]) ?? .textView
    }
    var title: String {
        switch self {
        case .textView: "Native UITextView"
        case .textField: "Native UITextField"
        case .webTextarea: "WKWebView textarea"
        case .webContenteditable: "WKWebView contenteditable"
        }
    }
}

private enum ReferenceInputKind: String, CaseIterable, Identifiable {
    case standard = "default", email, url, search, numbers, decimal, phone
    var id: String { rawValue }
    static var launchValue: Self {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--reference-type"),
              arguments.indices.contains(index + 1) else { return .standard }
        return Self(rawValue: arguments[index + 1]) ?? .standard
    }
    var keyboardType: UIKeyboardType {
        switch self {
        case .standard: .default
        case .email: .emailAddress
        case .url: .URL
        case .search: .webSearch
        case .numbers: .numberPad
        case .decimal: .decimalPad
        case .phone: .phonePad
        }
    }
    var returnKey: UIReturnKeyType { self == .search ? .search : .default }
}

private struct ReferenceNativeTextView: UIViewRepresentable {
    @Binding var text: String
    var dark: Bool
    var inputKind: ReferenceInputKind
    var telemetry: ReferenceTextTelemetry
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 130)
    }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = "keyboardReferenceField"
        view.font = .systemFont(ofSize: 20)
        view.backgroundColor = .secondarySystemBackground
        let arguments = ProcessInfo.processInfo.arguments
        view.autocapitalizationType = arguments.contains("--reference-sentence-caps") ? .sentences : .none
        view.enablesReturnKeyAutomatically = arguments.contains("--reference-auto-return")
        // Leave correction/smart punctuation at native defaults. The harness
        // must not replace or imitate any portion of Apple's input view.
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: text.utf16.count, length: 0)
            telemetry.record("fixture-set", text: text)
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: text.utf16.count, length: 0)
            view.scrollRangeToVisible(view.selectedRange)
            let preparedText = text
            let generation = focusRequest
            DispatchQueue.main.async { telemetry.ready(generation: generation, text: preparedText) }
        }
        let arguments = ProcessInfo.processInfo.arguments
        let appearance: UIKeyboardAppearance = arguments.contains("--reference-keyboard-light") ? .light
            : arguments.contains("--reference-keyboard-dark") ? .dark : (dark ? .dark : .light)
        let changed = view.keyboardType != inputKind.keyboardType
            || view.returnKeyType != inputKind.returnKey || view.keyboardAppearance != appearance
        view.keyboardType = inputKind.keyboardType
        view.returnKeyType = inputKind.returnKey
        view.keyboardAppearance = appearance
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        if changed, view.isFirstResponder { view.reloadInputViews() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReferenceNativeTextView
        var lastFocusRequest = 0
        init(_ parent: ReferenceNativeTextView) { self.parent = parent }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            parent.telemetry.record("request", text: textView.text, range: range, replacement: text)
            return true
        }
        func textViewDidChange(_ textView: UITextView) {
            parent.telemetry.record("changed", text: textView.text)
            parent.text = textView.text
        }
    }
}

/// The single-line UIKit path has different document-context behaviour from
/// UITextView. It shares only the fixture seed and observed-edit recorder.
private struct ReferenceNativeTextField: UIViewRepresentable {
    @Binding var text: String
    var dark: Bool
    var inputKind: ReferenceInputKind
    var telemetry: ReferenceTextTelemetry
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 130)
    }
    func makeUIView(context: Context) -> UITextField {
        let view = UITextField()
        view.accessibilityIdentifier = "keyboardReferenceField"
        view.font = .systemFont(ofSize: 20)
        view.backgroundColor = .secondarySystemBackground
        view.borderStyle = .roundedRect
        view.autocapitalizationType = .none
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return view
    }
    func updateUIView(_ view: UITextField, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            telemetry.record("fixture-set", text: text)
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            view.becomeFirstResponder()
            view.selectedTextRange = view.textRange(from: view.endOfDocument, to: view.endOfDocument)
            let preparedText = text
            let generation = focusRequest
            DispatchQueue.main.async { telemetry.ready(generation: generation, text: preparedText) }
        }
        let arguments = ProcessInfo.processInfo.arguments
        let appearance: UIKeyboardAppearance = arguments.contains("--reference-keyboard-light") ? .light
            : arguments.contains("--reference-keyboard-dark") ? .dark : (dark ? .dark : .light)
        let changed = view.keyboardType != inputKind.keyboardType
            || view.returnKeyType != inputKind.returnKey || view.keyboardAppearance != appearance
        view.keyboardType = inputKind.keyboardType
        view.returnKeyType = inputKind.returnKey
        view.keyboardAppearance = appearance
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        if changed, view.isFirstResponder { view.reloadInputViews() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ReferenceNativeTextField
        var lastFocusRequest = 0
        init(_ parent: ReferenceNativeTextField) { self.parent = parent }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            parent.telemetry.record("request", text: textField.text ?? "", range: range, replacement: string)
            return true
        }
        @objc func changed(_ textField: UITextField) {
            let text = textField.text ?? ""
            parent.telemetry.record("changed", text: text)
            parent.text = text
        }
    }
}

/// A local, ephemeral WebKit editing surface. Browser `input` is the
/// acknowledgement; requested keyboard edits are never counted as completed.
private struct ReferenceWebTextView: UIViewRepresentable {
    @Binding var text: String
    var dark: Bool
    var hostKind: ReferenceHostKind
    var telemetry: ReferenceTextTelemetry
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 130)
    }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "fixture")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.accessibilityIdentifier = "keyboardReferenceWebView"
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        context.coordinator.webView = view
        view.loadHTMLString(Self.html(contenteditable: hostKind == .webContenteditable), baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        view.backgroundColor = .secondarySystemBackground
        context.coordinator.synchronize()
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "fixture")
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.webView = nil
    }

    private static func html(contenteditable: Bool) -> String {
        let field = contenteditable
            ? "<div id='editor' contenteditable='true' role='textbox' aria-multiline='true' aria-label='keyboardReferenceField'></div>"
            : "<textarea id='editor' aria-label='keyboardReferenceField'></textarea>"
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        html,body { margin:0; height:100%; font:20px -apple-system; }
        #editor { display:block; box-sizing:border-box; width:100%; height:126px; margin:0;
          padding:8px; border:1px solid gray; border-radius:6px; background:Canvas;
          color:CanvasText; font:inherit; overflow:auto; white-space:pre-wrap; }
        </style></head><body>\(field)<script>
        const field = document.getElementById('editor');
        const isTextarea = field.tagName === 'TEXTAREA';
        let generation = 0, sequence = 0;
        function value() { return isTextarea ? field.value : field.textContent; }
        function selection() {
          if (isTextarea) return [field.selectionStart, field.selectionEnd];
          const s = window.getSelection();
          if (!s || !s.rangeCount || !field.contains(s.anchorNode)) return [-1, -1];
          const r = s.getRangeAt(0), before = r.cloneRange();
          before.selectNodeContents(field); before.setEnd(r.startContainer, r.startOffset);
          const start = before.toString().length;
          return [start, start + r.toString().length];
        }
        function post(kind, inputType) {
          const bounds = selection();
          window.webkit.messageHandlers.fixture.postMessage({kind, text:value(), generation,
            sequence:++sequence, browserTimeMS:performance.now(), inputType:inputType || '',
            selectionStart:bounds[0], selectionEnd:bounds[1]});
        }
        field.addEventListener('beforeinput', event => post('request', event.inputType));
        field.addEventListener('input', event => post('changed', event.inputType));
        window.prepareFixture = function(seed, requestedGeneration, shouldFocus) {
          generation = requestedGeneration;
          if (isTextarea) field.value = seed; else field.textContent = seed;
          if (shouldFocus) {
            field.focus();
            if (isTextarea) field.setSelectionRange(seed.length, seed.length);
            else {
              const range = document.createRange(); range.selectNodeContents(field); range.collapse(false);
              const s = window.getSelection(); s.removeAllRanges(); s.addRange(range);
            }
            field.scrollTop = field.scrollHeight;
          }
          post('fixture-ready');
          return document.activeElement === field;
        };
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReferenceWebTextView
        weak var webView: WKWebView?
        private var loaded = false
        private var lastFocusRequest = -1
        private var observedText = ""
        init(_ parent: ReferenceWebTextView) { self.parent = parent }

        func synchronize() {
            guard loaded, let webView else { return }
            let generation = parent.focusRequest
            guard lastFocusRequest != generation || observedText != parent.text else { return }
            lastFocusRequest = generation
            observedText = parent.text
            let shouldFocus = generation > 0
            webView.callAsyncJavaScript(
                "return window.prepareFixture(seed, generation, shouldFocus);",
                arguments: ["seed": parent.text, "generation": generation, "shouldFocus": shouldFocus],
                in: nil, in: .page
            ) { [weak self] result in
                guard let self, self.parent.focusRequest == generation else { return }
                switch result {
                case .failure:
                    self.parent.telemetry.fail("Local WebKit fixture preparation failed")
                case .success(let focused):
                    if shouldFocus, (focused as? Bool) != true {
                        self.parent.telemetry.fail("Tap the local WebKit field before preparing the fixture")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            synchronize()
        }
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // This harness has no reason to navigate beyond its static HTML.
            navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.telemetry.fail("Local WebKit process terminated")
        }
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let text = body["text"] as? String,
                  let generation = body["generation"] as? Int,
                  generation == parent.focusRequest,
                  text.utf16.count <= 2_048 else { return }
            observedText = text
            var extra: [String: Any] = [:]
            for key in ["browserTimeMS", "sequence", "inputType", "selectionStart", "selectionEnd"] {
                if let value = body[key] { extra[key] = value }
            }
            if kind == "fixture-ready" {
                parent.telemetry.ready(generation: generation, text: text)
            } else if kind == "request" || kind == "changed" {
                parent.telemetry.record(kind, text: text, extra: extra)
                if kind == "changed" { parent.text = text }
            }
        }
    }
}

/// Separate from the synthetic keyboard host: never submits audio or inserts text.
private struct RealAudioBackgroundTestView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var probe = RealAudioBackgroundProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Physical audio diagnostic").font(.headline)
            Text("Real microphone · no network · 8-second capture limit")
                .font(.caption).foregroundStyle(.orange)
            field("Phase", probe.phase, id: "audioProbePhase")
            field("Permission", probe.permissionGranted ? "granted" : "missing", id: "audioProbePermission")
            field("Failure", probe.failure, id: "audioProbeFailure")
            field("PCM seconds", String(format: "%.3f", probe.duration), id: "audioProbeDuration")
            field("Classifications", String(probe.observationCount), id: "audioProbeObservations")
            field("Background classifications", String(probe.backgroundObservationCount), id: "audioProbeBackgroundObservations")
            field("Entered background", probe.backgroundSeen ? "yes" : "no", id: "audioProbeBackgroundSeen")
            field("Background PCM seconds", String(format: "%.3f", probe.backgroundAudioSeconds), id: "audioProbeBackgroundAudio")
            field("Background wall seconds", String(format: "%.3f", probe.backgroundWallSeconds), id: "audioProbeBackgroundWall")
            field("Residual capture state", probe.hasResidualCaptureState ? "present" : "none", id: "audioProbeResidual")
            HStack {
                Button("Start real capture") { probe.start() }
                    .accessibilityIdentifier("audioProbeStart")
                    .disabled(probe.phase == "recording")
                Button("Stop and discard") { probe.finish() }
                    .accessibilityIdentifier("audioProbeStop")
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .font(.footnote.monospacedDigit())
        .padding()
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { probe.enteredBackground() }
            if phase == .active { probe.becameActive() }
        }
        .onDisappear {
            // Home intentionally leaves this capture running. Navigating away
            // while active stops it; the independent cap covers every other path.
            if scenePhase == .active { probe.finish() }
        }
    }

    private func field(_ title: String, _ value: String, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).accessibilityIdentifier(id)
        }
    }
}

private struct KeyboardHostTextView: UIViewRepresentable {
    @Binding var text: String
    var identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let editor = UITextView()
        editor.accessibilityIdentifier = identifier
        editor.font = .preferredFont(forTextStyle: .body)
        editor.backgroundColor = .secondarySystemBackground
        editor.layer.cornerRadius = 10
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.delegate = context.coordinator
        return editor
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: KeyboardHostTextView
        init(_ parent: KeyboardHostTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
#endif
