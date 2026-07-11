// First-run onboarding (W3-T4): the two things a fresh install needs before the
// hold-speak-paste loop works — the three macOS permission grants, and the
// on-disk model repos. Shown at launch when something required is missing, and
// reachable any time from the menu's "Setup…". The app stays usable without
// either (the menu works, the pipeline just stays gated); this window only
// explains what's missing and offers the one-click fixes.
//
// It polls permission + model state every second while open, so a grant made in
// System Settings — or a finished download — reflects back live, no relaunch.

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var models: ModelState
    var onDone: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    permissionsStep
                    Divider()
                    modelsStep
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onReceive(poll) { _ in
            permissions.refresh()
            models.recheck()
        }
    }

    // MARK: Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to OLIV")
                .font(.title2).bold()
            Text("Hold your key, speak, release — the transcript pastes at your cursor. "
                 + "Two quick things first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if permissions.allGranted && models.allPresent {
                Label("You're all set", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("You can close this and finish setup later from the menu › Setup…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Step 1 — permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(1, "Permissions", done: permissions.allGranted)
            ForEach(PermissionKind.allCases) { kind in
                permissionRow(kind)
            }
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = permissions.status(for: kind)
        return HStack(alignment: .top, spacing: 12) {
            statusIcon(status.isGranted)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).fontWeight(.medium)
                Text(kind.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !status.isGranted {
                VStack(alignment: .trailing, spacing: 4) {
                    if status == .notDetermined {
                        Button("Grant") { permissions.request(kind) }
                    }
                    Button("Open System Settings") {
                        permissions.request(kind)   // also registers the app in the list
                        permissions.openSettings(for: kind)
                    }
                    .font(.caption)
                }
            } else {
                Text("Granted").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Step 2 — models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(2, "Models", done: models.allPresent)

            ForEach(models.repos) { info in
                HStack(spacing: 12) {
                    statusIcon(info.present)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.displayName).fontWeight(.medium)
                        Text(info.repo).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if models.isDownloading, let pct = models.progressByRepo[info.repo] {
                        Text("\(pct)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(info.sizeText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }

            if models.isDownloading {
                ProgressView(value: overallProgress) {
                    Text("Downloading models… \(Int(overallProgress * 100))%")
                        .font(.caption)
                }
                .progressViewStyle(.linear)
            } else if !models.allPresent {
                Button {
                    models.download()
                } label: {
                    Label("Download models", systemImage: "square.and.arrow.down")
                }
            }

            if let err = models.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Text("Stored at: \(models.storagePath)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// Overall download progress = mean of per-repo percent across the required
    /// repos (a repo with no line yet counts as 0). Coarse, matches the sidecar.
    private var overallProgress: Double {
        let repos = models.repos.map(\.repo)
        guard !repos.isEmpty else { return 0 }
        let sum = repos.reduce(0) { $0 + (models.progressByRepo[$1] ?? 0) }
        return Double(sum) / Double(repos.count * 100)
    }

    // MARK: Bits

    private func stepTitle(_ n: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Step \(n)").font(.caption).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func statusIcon(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}
