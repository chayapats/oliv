// The preview step of "Report a Wrong Result…" (#21). The menu action only
// opens this window; the browser opens from its button and nowhere else, so a
// report always passes through a screen that shows what it holds, says it will
// be public, and lets the user edit it.

import AppKit
import SwiftUI

/// The editable report behind the preview. `open` is injected so tests can
/// check that nothing leaves before `submit()`.
@MainActor
final class ResultReportDraft: ObservableObject {
    @Published var source: String
    @Published var instruction: String
    @Published var typed: String
    @Published var raw: String
    @Published var meant: String
    let base: ResultReport
    private let open: (URL) -> Void

    init(report: ResultReport, open: @escaping (URL) -> Void) {
        base = report
        source = report.source
        instruction = report.instruction
        typed = report.typed
        raw = report.raw
        meant = report.meant
        self.open = open
    }

    /// The report as currently edited.
    var report: ResultReport {
        var report = base
        report.source = source
        report.instruction = instruction
        report.typed = typed
        report.raw = raw
        report.meant = meant
        return report
    }

    var truncatedFields: Set<ResultReport.Field> { report.fitted().truncated }

    /// The only path to the browser.
    func submit() { open(report.url) }
}

struct ResultReportView: View {
    @ObservedObject var draft: ResultReportDraft
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This report will be public.")
                        .fontWeight(.semibold)
                    Text("It opens as a GitHub issue in your browser, where anyone can read it. Remove names, numbers and anything else private first. OLIV sends nothing: the issue is posted only if you submit it on GitHub.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "globe")
                    .foregroundStyle(.orange)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            // Each part of an edit under its own label: what was selected (or
            // translated), what was asked, and what came of it.
            switch draft.base.kind {
            case .dictation:
                editor("What OLIV typed", text: $draft.typed)
                editor("Raw transcript, before cleanup", text: $draft.raw)
                editor("What you meant to say (optional)", text: $draft.meant)
            case .command:
                editor("Selected text", text: $draft.source, compact: true)
                editor("Instruction (heard)", text: $draft.instruction, compact: true)
                editor("Result: what OLIV typed", text: $draft.typed, compact: true)
                editor("Raw transcript of the instruction, before cleanup", text: $draft.raw, compact: true)
                editor("What you expected (optional)", text: $draft.meant, compact: true)
            case .translation:
                editor("Thai that was translated", text: $draft.source, compact: true)
                editor("Result: what OLIV typed", text: $draft.typed, compact: true)
                editor("Raw transcript, before cleanup", text: $draft.raw, compact: true)
                editor("What you expected (optional)", text: $draft.meant, compact: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                detail("Mode", draft.base.mode)
                detail("Engine", draft.base.engine)
                detail("Cleanup", draft.base.cleanup)
                detail("App", draft.base.appVersion)
                detail("System", draft.base.osVersion)
                detail("Timing", draft.base.timing)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                Text("No audio is included: OLIV doesn’t keep recordings on this Mac.")
                if !draft.truncatedFields.isEmpty {
                    Text("Long text is cut to fit a web link. The cut is marked “truncated by OLIV”.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Open in Browser") {
                    draft.submit()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    /// `compact`: an edit's report has more boxes; keep the window on screen.
    private func editor(_ title: LocalizedStringKey, text: Binding<String>, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: compact ? 40 : 52, maxHeight: compact ? 76 : 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    @ViewBuilder
    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                // The report's own words, exactly as they will be sent.
                Text(verbatim: value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A plain NSWindow for the preview, like the Setup window: an accessory
/// (menu-bar) app has no other window to present from.
@MainActor
final class ResultReportWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(_ draft: ResultReportDraft) {
        let root = ResultReportView(draft: draft, onClose: { [weak self] in self?.window?.close() })
        if let window {
            // A second report replaces the first; one preview at a time.
            window.contentViewController = NSHostingController(rootView: root)
        } else {
            let win = NSWindow(contentViewController: NSHostingController(rootView: root))
            win.title = "Report a Wrong Result"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            win.delegate = self
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The draft holds dictated text; let it go with the window.
        window = nil
    }
}
