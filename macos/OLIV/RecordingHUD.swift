// Floating recording HUD (W4-T2 Feature A) — a small, non-activating pill near
// the bottom of the focused screen, in the spirit of modern dictation-app recording
// indicator. It is the one on-screen surface for a menu-bar app whose whole
// point is that the user is mid-typing in ANOTHER app: it must show state
// without ever stealing focus.
//
//   • NSPanel(.nonactivatingPanel, level .statusBar, ignoresMouseEvents) shown
//     with orderFrontRegardless — never makeKey — so the frontmost app keeps
//     first responder. .canJoinAllSpaces + .fullScreenAuxiliary so it rides over
//     full-screen apps and every Space. Positioned on NSScreen.main (the screen
//     with the focused window) so multi-display users see it where they're
//     looking. hasShadow=false; the SwiftUI pill draws its own material chrome.
//
//   • RECORDING → a live waveform: ~27 bars scrolling right-to-left, heights
//     driven by the REAL RMS levels AudioCapture streams (throttled to ~24 Hz),
//     smoothed so it glides instead of jitters. Under Reduce Motion it degrades
//     to a calm horizontal level meter (no scrolling).
//
//   • PROCESSING (key released, STT+cleanup in flight) → the same pill switches
//     to a calm indeterminate state: gentle breathing dots + "Transcribing…"
//     (a static waveform glyph under Reduce Motion).
//
//   • Show/hide are quick alpha fades; hide() orders the panel out when done.
//
// Pure AppKit/SwiftUI, no third-party deps. Driven entirely by
// DictationController's status transitions — the pill mirrors the state machine.

import AppKit
import SwiftUI

/// The pill's visual states. `recording`/`processing` are the subset of
/// DictationStatus (idle simply hides the HUD). `notice` is the A1/A2 reliability
/// state: a brief, auto-hiding message (icon + text from the model) shown when an
/// utterance failed or the paste couldn't be synthesized — so a drop is never
/// silent.
enum HUDPhase: Equatable { case recording, processing, notice }

/// Owns the NSPanel + the SwiftUI host and exposes the three verbs the
/// coordinator drives: show(phase:), update(level:), hide(). @MainActor — all UI.
@MainActor
final class RecordingHUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var isVisible = false
    /// Bumped on each notice() so a stale auto-hide (from an earlier notice)
    /// never dismisses a newer one. See notice().
    private var noticeToken = 0

    private static let size = NSSize(width: 220, height: 56)
    private static let bottomMargin: CGFloat = 96   // above the Dock

    /// Show (or re-purpose) the pill in `phase`. Idempotent: an already-visible
    /// pill just switches phase (no re-fade); recording resets the waveform.
    func show(phase: HUDPhase) {
        let panel = ensurePanel()
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if phase == .recording && (!isVisible || model.phase != .recording) {
            model.resetHistory()
        }
        model.phase = phase
        position(panel)
        guard !isVisible else { return }
        isVisible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()   // never makeKey — must NOT steal focus
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    /// Feed one live 0…1 input level to the waveform (no-op unless recording).
    func update(level: Float) {
        guard isVisible, model.phase == .recording else { return }
        model.push(level: level)
    }

    /// Acknowledge a hotkey press that arrived while still processing: pulse
    /// the visible pill so the ignored press reads as "busy", not "broken".
    /// No-op when the pill isn't on screen (HUD disabled / already idle).
    func flashBusy() {
        guard isVisible, !model.emphasized else { return }
        model.emphasized = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.model.emphasized = false
        }
    }

    /// A1/A2: show a brief, self-dismissing notice (icon + `text`) — the
    /// end-of-utterance feedback for a failure/fallback. Shown REGARDLESS of the
    /// "show recording indicator" preference (that gates the cosmetic waveform;
    /// an error the user can't see defeats the whole reliability pass). If the
    /// processing pill is still up it morphs in place; otherwise it fades in.
    /// Auto-hides after `duration`, unless a newer notice or a new recording has
    /// taken over in the meantime (generation + phase guard).
    func notice(_ text: String, systemImage: String, duration: TimeInterval = 2.4) {
        noticeToken += 1
        let token = noticeToken
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.noticeText = text
        model.noticeSymbol = systemImage
        show(phase: .notice)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self,
                  self.noticeToken == token,       // no newer notice replaced it
                  self.model.phase == .notice      // not superseded by a recording
            else { return }
            self.hide()
        }
    }

    /// Fade the pill out and order it off screen. Idempotent.
    func hide() {
        guard isVisible, let panel = panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    // MARK: Panel

    private func ensurePanel() -> NSPanel {
        if let panel = panel { return panel }
        let rect = NSRect(origin: .zero, size: Self.size)
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingHUDView(model: model))
        self.panel = panel
        return panel
    }

    /// Center horizontally, sit a fixed margin above the Dock, on the screen with
    /// the focused window (NSScreen.main), falling back to the first screen.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - Self.size.width / 2
        let y = visible.minY + Self.bottomMargin
        panel.setFrame(NSRect(x: x, y: y, width: Self.size.width, height: Self.size.height),
                       display: true)
    }
}

// MARK: - Observable model

/// The pill's render state. Level history is a fixed ring (oldest→newest) so the
/// waveform scrolls as new samples push in; `level` is the EMA-smoothed latest
/// value that also drives the Reduce-Motion meter.
@MainActor
final class HUDModel: ObservableObject {
    static let barCount = 27

    @Published var phase: HUDPhase = .recording
    @Published var reduceMotion = false
    @Published var level: Float = 0
    @Published var history: [Float] = Array(repeating: 0, count: HUDModel.barCount)
    /// Momentary "I heard you, still busy" pulse (see RecordingHUDView).
    @Published var emphasized = false
    /// A1/A2 notice content (rendered only in the `.notice` phase).
    @Published var noticeText = ""
    @Published var noticeSymbol = "exclamationmark.circle"

    private let smoothing: Float = 0.35   // how far each sample pulls the value

    func resetHistory() {
        history = Array(repeating: 0, count: HUDModel.barCount)
        level = 0
    }

    /// Push one 0…1 sample: exponential-smooth it, then scroll it into the ring.
    func push(level newLevel: Float) {
        let clamped = min(max(newLevel, 0), 1)
        level += (clamped - level) * smoothing
        var next = history
        next.removeFirst()
        next.append(level)
        history = next
    }
}

// MARK: - SwiftUI

/// OLIV brand olive for the HUD's live elements (waveform / meter / dots) —
/// the same green as the site, badge, and README demo GIF, replacing the
/// default (blue) accent. Dynamic: the print olive #57761F reads well on the
/// light vibrancy pill; dark mode gets the landing page's brighter #9DB24E so
/// bars don't go muddy on the dark material.
private extension Color {
    static let olivAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.616, green: 0.698, blue: 0.306, alpha: 1)  // #9DB24E
            : NSColor(calibratedRed: 0.341, green: 0.463, blue: 0.122, alpha: 1)  // #57761F
    })
}

struct RecordingHUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)   // vibrancy — respects light/dark
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
            content.padding(.horizontal, 16)
        }
        .frame(width: 220, height: 56)
        // Busy-press acknowledgement: a quick scale pulse when the user presses
        // the hotkey while the previous utterance is still processing. The
        // press is (correctly) not acted on — but silence read as "hotkey is
        // broken" in real use, so the pill visibly reacts instead.
        .scaleEffect(model.emphasized ? 1.07 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: model.emphasized)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording:
            if model.reduceMotion {
                LevelMeterView(level: CGFloat(model.level))
            } else {
                WaveformBarsView(history: model.history)
            }
        case .processing:
            ProcessingView(reduceMotion: model.reduceMotion)
        case .notice:
            NoticeView(text: model.noticeText, systemImage: model.noticeSymbol)
        }
    }
}

/// A1/A2 notice: a warning glyph + a short message. Text wraps to two lines and
/// scales down a little so a slightly-longer message still fits the fixed pill.
private struct NoticeView: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Live waveform: symmetric-around-center bars whose heights are the scrolling
/// level history. A short ease-out keeps each frame's height change smooth.
private struct WaveformBarsView: View {
    let history: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = history.count
            let spacing: CGFloat = 3
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.olivAccent)
                        .frame(width: barWidth, height: barHeight(history[i], maxH: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.09), value: history)
        }
    }

    private func barHeight(_ level: Float, maxH: CGFloat) -> CGFloat {
        let minH: CGFloat = 3
        return minH + CGFloat(max(0, min(1, level))) * (maxH - minH)
    }
}

/// Reduce-Motion fallback: a static-scale horizontal meter (data, not motion).
private struct LevelMeterView: View {
    let level: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(Color.olivAccent)
                        .frame(width: max(4, geo.size.width * max(0, min(1, level))))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Processing state: calm breathing dots (or a static glyph under Reduce Motion)
/// plus a short label. Indeterminate — no progress is known.
private struct ProcessingView: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            if reduceMotion {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            } else {
                BreathingDots()
            }
            Text("Transcribing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct BreathingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.olivAccent)
                        .frame(width: 7, height: 7)
                        .opacity(opacity(t: t, index: i))
                }
            }
        }
    }

    private func opacity(t: Double, index: Int) -> Double {
        let phase = t * 2.2 - Double(index) * 0.5
        return 0.35 + 0.45 * (0.5 + 0.5 * sin(phase))
    }
}
