import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let olive = Color(red: 0.73, green: 0.84, blue: 0.45)
private let ink = Color(red: 0.10, green: 0.14, blue: 0.10)

@main
struct OlivWidgetBundle: WidgetBundle {
    var body: some Widget {
        OlivCaptureWidget()
        OlivLiveActivity()
        OlivToggleControl()
        OlivQuickCaptureControl()
    }
}

struct OlivToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.oliv.ios.toggle") {
            ControlWidgetButton(action: ToggleCaptureIntent()) {
                Label("Toggle OLIV", systemImage: "waveform")
            }
        }
        .displayName("Toggle OLIV")
        .description("Start or finish a recording. Complete setup in OLIV first.")
    }
}

struct OlivQuickCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.oliv.ios.capture") {
            ControlWidgetButton(action: QuickCaptureIntent()) {
                Label("Capture", systemImage: "mic.fill")
            }
        }
        .displayName("Capture with OLIV")
        .description("Open OLIV and start recording.")
    }
}

private struct CaptureEntry: TimelineEntry { let date: Date }

private struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry { CaptureEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        // The launch surface has no changing data and consumes no recurring refresh budget.
        completion(Timeline(entries: [CaptureEntry(date: Date())], policy: .never))
    }
}

struct OlivCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.oliv.ios.capture-widget", provider: CaptureProvider()) { _ in
            CaptureWidgetView()
                .containerBackground(ink, for: .widget)
        }
        .configurationDisplayName("OLIV Capture")
        .description("Your voice, ready to use. Open OLIV and start recording.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct CaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Link(destination: URL(string: "oliv://capture")!) {
                Image(systemName: "waveform").font(.title2).widgetAccentable()
            }
        case .accessoryRectangular:
            Link(destination: URL(string: "oliv://capture")!) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("OLIV", systemImage: "waveform").font(.headline)
                    Text("Speak. Make it clear.").font(.caption)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("oliv").font(.system(size: 26, weight: .semibold, design: .serif))
                    Spacer()
                    Image(systemName: "waveform").foregroundStyle(olive)
                }
                Spacer(minLength: 0)
                Text("A thought,\nwell put.").font(.system(.title3, design: .serif)).fixedSize(horizontal: false, vertical: true)
                Button(intent: QuickCaptureIntent()) {
                    Label("Capture", systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ink)
                .background(olive, in: Capsule())
            }
            .foregroundStyle(.white)
        }
    }
}

struct OlivLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OlivActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: symbol(for: context.state.phase))
                    .font(.title2)
                    .foregroundStyle(olive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: context.state.phase)).font(.headline)
                    if context.state.phase == .recording {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Recording duration")
                    } else {
                        Text(subtitle(for: context.state.phase)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if context.state.phase == .recording { recordingActions }
            }
            .padding(16)
            .activityBackgroundTint(ink)
            .activitySystemActionForegroundColor(olive)
            .foregroundStyle(.white)
            .widgetURL(URL(string: "oliv://latest"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("OLIV", systemImage: symbol(for: context.state.phase))
                        .font(.headline).foregroundStyle(olive)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .recording {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.headline.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(title(for: context.state.phase)).font(.subheadline)
                        Spacer()
                        if context.state.phase == .recording { recordingActions }
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: symbol(for: context.state.phase)).foregroundStyle(olive)
            } compactTrailing: {
                if context.state.phase == .recording {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit().frame(width: 42)
                } else {
                    Image(systemName: context.state.phase == .processing ? "ellipsis" : "checkmark")
                }
            } minimal: {
                Image(systemName: symbol(for: context.state.phase)).foregroundStyle(olive)
            }
            .widgetURL(URL(string: "oliv://latest"))
            .keylineTint(olive)
        }
    }

    private var recordingActions: some View {
        HStack(spacing: 10) {
            Button(intent: CancelCaptureIntent()) {
                Image(systemName: "xmark").frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard recording")
            Button(intent: StopCaptureIntent()) {
                Image(systemName: "stop.fill").frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink)
            .background(olive, in: Circle())
            .accessibilityLabel("Finish and transcribe recording")
        }
    }

    private func title(for phase: OlivActivityAttributes.Phase) -> String {
        switch phase {
        case .recording: "Listening"
        case .processing: "Finding your words"
        case .ready: "Ready in OLIV"
        case .cancelled: "Recording discarded"
        }
    }

    private func subtitle(for phase: OlivActivityAttributes.Phase) -> String {
        switch phase {
        case .recording: "Tap stop when you're finished."
        case .processing: "Preparing your transcript…"
        case .ready: "Open to copy or share."
        case .cancelled: "Nothing was sent."
        }
    }

    private func symbol(for phase: OlivActivityAttributes.Phase) -> String {
        switch phase {
        case .recording: "waveform"
        case .processing: "ellipsis"
        case .ready: "checkmark"
        case .cancelled: "xmark"
        }
    }
}
