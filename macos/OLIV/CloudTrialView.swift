// The free-trial offer (CloudTrial) as onboarding and Settings ▸ Dictation
// engine show it: what it does before the user opts in, that it is on (Cloud),
// and why it is off when it ended or was refused.

import SwiftUI

struct CloudTrialOfferView: View {
    @ObservedObject var trial: CloudTrial
    /// The offer applies now (named server, on-device engine, models missing).
    let offered: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        if trial.phase != .off || offered {
            VStack(alignment: .leading, spacing: 8) {
                switch trial.phase {
                case .on: active
                case .starting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting the free trial…").font(.caption)
                    }
                case .off: offer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Dictate now, while the models download").fontWeight(.medium)
            } icon: {
                Image(systemName: "cloud")
            }
            Text("Until the download finishes, OLIV can send your recordings to the OLIV server for transcription. Nothing leaves this Mac unless you turn this on. When the models are ready, OLIV switches back to this Mac and tells you.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = trial.note { noteText(note) }
            Button(action: onStart) {
                Label("Try it now through the OLIV server", systemImage: "cloud")
            }
            Text("A free trial: a short-lived key with a small daily limit, kept in Keychain. Your Dictionary isn’t sent or synced.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var active: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Cloud · Dictating through the OLIV server").fontWeight(.medium)
            } icon: {
                Image(systemName: "cloud.fill")
            }
            Text("Your recordings go to the OLIV server until the download finishes. Then OLIV switches back to this Mac on its own.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let record = trial.record {
                Text("Free trial until \(record.expiresAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption2).foregroundStyle(.secondary)
                if let perMinute = record.requestsPerMinute, let perDay = record.dailyRequests {
                    Text("Up to \(perMinute) dictations a minute and \(perDay) a day.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button("Stop using the OLIV server", action: onStop)
        }
    }

    /// Each reason in plain words, always ending in what still works: the
    /// download.
    @ViewBuilder private func noteText(_ note: CloudTrial.Note) -> some View {
        Group {
            switch note {
            case .refused(.clientLimit):
                Text("Free trials from this network are used up for today. Wait for the download to finish, or try again tomorrow.")
            case .refused(.dailyLimit):
                Text("Today’s free trials are all taken. Wait for the download to finish, or try again tomorrow.")
            case .refused(.full):
                Text("The free trial is full right now. Wait for the download to finish, or try again later.")
            case .refused(.closed):
                Text("The free trial is closed right now. Wait for the download to finish.")
            case .refused(.unavailable):
                Text("The free trial isn’t available right now. Wait for the download to finish, or try again later.")
            case .unreachable:
                Text("Couldn’t reach the OLIV server. Wait for the download to finish, or try again.")
            case .failed:
                Text("The free trial couldn’t start. Wait for the download to finish.")
            case .downloadStopped:
                Text("The download stopped, so OLIV stopped using the server. Start it again to continue the trial.")
            case .ended:
                Text("Your free trial has ended. OLIV dictates on this Mac once the download finishes.")
            }
        }
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
}
