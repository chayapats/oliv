import SwiftUI
import OlivCore

struct CaptureView: View {
    @Bindable var model: AppModel
    @State private var showsTextCleanup = false
    @State private var showsQuickAccess = false
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 42
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let latest = model.latest, !model.isBusy {
                    ResultCard(entry: latest, model: model)
                    Button {
                        Task { await model.toggleRecording() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mic.fill")
                            Text("Record another thought")
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(OlivSecondaryButtonStyle())
                    .disabled(!model.isConfigured)
                    .accessibilityIdentifier("recordButton")
                } else {
                    captureCard
                }

                if !model.isConfigured {
                    connectionCard
                }

                if !model.pending.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: model.isBusy ? "Saved recordings" : "Ready for another try", caption: "These recordings are saved on this iPhone.")
                        ForEach(model.pending) { item in
                            PendingRecordingCard(item: item, model: model)
                        }
                    }
                }

                toolsCard

                if model.latest == nil, !model.history.isEmpty {
                    recentCard
                }

                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                    Text("Audio goes to your configured Oliv server.")
                }
                .font(.caption)
                .foregroundStyle(OlivTheme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .olivScreen()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsTextCleanup) {
            CleanTextSheet(model: model)
        }
        .sheet(isPresented: $showsQuickAccess) {
            NavigationStack {
                QuickAccessView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsQuickAccess = false }
                        }
                    }
            }
        }
    }

    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center))
        return layout {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 19, weight: .regular))
                    .rotationEffect(.degrees(-20))
                    .foregroundStyle(OlivTheme.olive)
                    .accessibilityHidden(true)
                Text("OLIV")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .tracking(4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Oliv")
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Button {
                showsQuickAccess = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt")
                    Text("Quick access")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(OlivTheme.olive)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                .background(OlivTheme.inset, in: Capsule())
            }
            .accessibilityIdentifier("quickAccessButton")
        }
        .padding(.bottom, 4)
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRecording ? OlivTheme.olive : OlivTheme.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Eyebrow(text: captureEyebrow)
                Spacer(minLength: 4)
                if model.isRecording {
                    Text(model.formattedElapsed)
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(OlivTheme.olive)
                        .accessibilityLabel("Recording duration, \(model.formattedElapsed)")
                }
            }

            Text(captureTitle)
                .font(.system(size: titleSize, weight: .regular, design: .serif))
                .tracking(-1.5)
                .foregroundStyle(OlivTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)

            Text(captureSubtitle)
                .font(.subheadline)
                .foregroundStyle(OlivTheme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            AudioWaveform(level: model.level, elapsed: model.elapsed, active: model.isRecording)
                .padding(.vertical, 22)

            Button {
                Task { await model.toggleRecording() }
            } label: {
                HStack(spacing: 12) {
                    if isWaiting {
                        ProgressView().tint(OlivTheme.oliveContrast)
                    } else {
                        Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    Text(recordButtonTitle)
                    Spacer(minLength: 5)
                    if !isWaiting && !model.isRecording {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
            }
            .buttonStyle(OlivPrimaryButtonStyle())
            .disabled(isWaiting || !model.isConfigured)
            .accessibilityIdentifier("recordButton")
            .accessibilityHint(model.isRecording ? "Stops recording and sends the audio to your Oliv server." : "Starts recording from your microphone.")

            if model.isRecording || isWaiting {
                Button {
                    Task { await model.cancel() }
                } label: {
                    Text(model.isRecording ? "Discard recording" : "Cancel")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .foregroundStyle(OlivTheme.secondary)
                .accessibilityIdentifier("cancelButton")
                .padding(.top, 5)
            } else {
                Text(model.isConfigured ? "Tap once. Say what you mean." : "Connect to start recording.")
                    .font(.caption)
                    .foregroundStyle(OlivTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 15)
            }
        }
        .padding(25)
        .background(OlivTheme.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(OlivTheme.line, lineWidth: 1)
        }
    }

    private var connectionCard: some View {
        OlivCard(padding: 19) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "network")
                        .font(.title3)
                        .foregroundStyle(OlivTheme.olive)
                        .frame(width: 36, height: 36)
                        .background(OlivTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A small setup. A smoother flow.")
                            .font(.subheadline.weight(.semibold))
                        Text("Start a free trial, or add your own API key.")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    model.isInSetup = true
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(OlivSecondaryButtonStyle())
                .accessibilityIdentifier("configureServerButton")
            }
        }
    }

    private var toolsCard: some View {
        Button {
            showsTextCleanup = true
        } label: {
            HStack(alignment: .center, spacing: 15) {
                Image(systemName: "text.alignleft")
                    .font(.title3)
                    .foregroundStyle(OlivTheme.olive)
                    .frame(width: 48, height: 48)
                    .background(OlivTheme.inset, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Already have the words?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OlivTheme.ink)
                    Text("Paste text. Give it a little clarity.")
                        .font(.caption)
                        .foregroundStyle(OlivTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline)
                    .foregroundStyle(OlivTheme.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityIdentifier("cleanTextButton")
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(text: "Last captured")
                Spacer()
                Button("See all") { model.selectedTab = 1 }
                    .font(.caption.weight(.semibold))
            }
            if let entry = model.history.first {
                Button { model.latest = entry } label: {
                    HistorySummaryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the full result on Capture.")
            }
        }
    }

    private var isWaiting: Bool {
        switch model.phase {
        case .preparing, .processing: true
        default: false
        }
    }

    private var captureEyebrow: LocalizedStringKey {
        switch model.phase {
        case .preparing: "Getting ready"
        case .recording: "Listening to you"
        case .processing: "Finding the words"
        case .result: "Ready for your next thought"
        case .failed: "Let’s try again"
        case .idle: "A little less typing"
        }
    }

    private var captureTitle: LocalizedStringKey {
        switch model.phase {
        case .preparing: "A moment\nfor your voice."
        case .recording: "Just let\nit flow."
        case .processing: "From thought\nto text."
        default: "Speak\nnaturally."
        }
    }

    private var captureSubtitle: LocalizedStringKey {
        switch model.phase {
        case .preparing: "Preparing your microphone."
        case .recording: "Take your time. Tap below when you’re finished."
        case .processing: "Your Oliv server is transcribing and applying your text preferences."
        default: "Thai, English, or a little of both.\nYour words, with room to breathe."
        }
    }

    private var recordButtonTitle: LocalizedStringKey {
        switch model.phase {
        case .preparing: "Preparing microphone…"
        case .recording: "Finish recording"
        case .processing: "Working on your words…"
        default: "Start recording"
        }
    }
}

struct PendingRecordingCard: View {
    let item: PendingRecording
    @Bindable var model: AppModel
    @State private var confirmsDelete = false

    var body: some View {
        OlivCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title2)
                        .foregroundStyle(OlivTheme.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.semibold))
                        Text("\(Int(item.audioDuration.rounded())) sec recording · \(item.attemptCount) attempt\(item.attemptCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(OlivTheme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let error = item.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(OlivTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.retry(item) }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(OlivPrimaryButtonStyle(compact: true))
                    .disabled(model.isBusy || !model.isConfigured)
                    .accessibilityIdentifier("retryRecordingButton_\(item.id)")
                    Spacer()
                    Button(role: .destructive) { confirmsDelete = true } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Delete saved recording")
                    .disabled(model.isBusy)
                }
            }
        }
        .confirmationDialog("Delete this saved recording?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) { model.deletePending(item) }
        } message: {
            Text("This audio will be removed from this iPhone.")
        }
    }
}
