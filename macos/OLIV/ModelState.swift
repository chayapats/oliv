// Model-state detection + download driver (W3-T4). Answers two questions for
// onboarding + Settings › Models: are the required model repos present on disk,
// and how big are they — and, if not, drives the sidecar `download` with live
// progress. The models dir is whatever SidecarClient.modelsHome() resolves
// (bundled → the app-owned Application Support store; dev → the default HF
// cache), so we never duplicate that resolution here — we reuse it.

import Foundation

/// The model repos OLIV requires on first run: STT primary + cleanup. These
/// MUST match the sidecar's shipped defaults (app/stt TyphoonTurboMLXBackend's
/// TYPHOON_TURBO_MLX_REPO + benchmark/pipeline's DEFAULT_CLEANUP_MODEL = Gemma-E2B),
/// so once present the first dictate is warm — and the app downloads/uses exactly
/// the config the benchmark measured, not the old Pathumma + E4B pair.
enum RequiredModels {
    static let stt = "chayapats/typhoon-whisper-turbo-mlx"
    static let cleanup = "mlx-community/gemma-4-e2b-it-4bit"
    static let all: [String] = [stt, cleanup]

    static func displayName(_ repo: String) -> String {
        switch repo {
        case stt: return "Thai STT (Typhoon Whisper Turbo MLX)"
        case cleanup: return "Cleanup (Gemma-E2B)"
        default: return repo
        }
    }
}

/// One repo's on-disk state (presence + size), for the Models UI.
struct RepoInfo: Identifiable {
    let repo: String
    let present: Bool
    let bytes: Int64

    var id: String { repo }
    var displayName: String { RequiredModels.displayName(repo) }

    var sizeText: String {
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if present, bytes > 0 { return formatted }
        // Absent but bytes on disk == an interrupted fetch. Say so: a bare
        // "Not downloaded" hides gigabytes of partial blobs from the Models
        // tab and the diagnostics report, misleading exactly the support
        // conversation the readiness check exists to inform.
        if bytes > 0 { return "Incomplete (\(formatted) on disk)" }
        return "Not downloaded"
    }
}

@MainActor
final class ModelState: ObservableObject {
    /// Per-required-repo presence + size, refreshed by `recheck()`.
    @Published private(set) var repos: [RepoInfo] = []
    /// A download is in flight (drives the progress UI + disables the button).
    @Published private(set) var isDownloading = false
    /// Latest whole-percent per repo during a download (0…100).
    @Published private(set) var progressByRepo: [String: Int] = [:]
    /// Last download error (per-repo failure or comms failure), or nil.
    @Published private(set) var lastError: String?

    /// A dedicated sidecar for downloads, so a long fetch never serializes
    /// behind (or blocks) the live dictate sidecar. Same launch config →
    /// downloads land in the SAME HF_HOME the app reads.
    private let downloadClient = SidecarClient()

    init() { recheck() }

    /// True once every required repo has materialized weights.
    var allPresent: Bool { !repos.isEmpty && repos.allSatisfy { $0.present } }

    /// The directory the sidecar reads/writes models under (for the UI's
    /// "storage path" + Reveal-in-Finder).
    var storagePath: String { SidecarClient.modelsHome() }

    /// Re-scan disk for each required repo (presence + size). Cheap; safe to
    /// call on the onboarding poll timer or after a download completes.
    func recheck() {
        repos = RequiredModels.all.map { repo in
            let (present, bytes) = Self.diskInfo(repo)
            return RepoInfo(repo: repo, present: present, bytes: bytes)
        }
    }

    /// Download the given repos via the sidecar, streaming whole-percent
    /// progress into `progressByRepo`. No-op if a download is already running.
    /// The blocking `download` runs off-main; progress + result marshal back.
    func download(_ repos: [String] = RequiredModels.all) {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil
        progressByRepo = [:]
        let client = downloadClient
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<DownloadResult, Error>
            do {
                let r = try client.download(repos: repos) { repo, pct in
                    DispatchQueue.main.async { self.progressByRepo[repo] = pct }
                }
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case let .success(r) where r.ok:
                    break
                case let .success(r):
                    self.lastError = "Download failed for "
                        + "\(r.failedRepo ?? "a model"): \(r.error ?? "unknown error")"
                case let .failure(err):
                    self.lastError = "Download failed: \(err)"
                }
                self.isDownloading = false
                self.recheck()
            }
        }
    }

    /// Reap the download sidecar (no orphan). Called at app quit — use the
    /// non-blocking terminateNow() so quit never freezes the main thread behind
    /// an in-flight request (see SidecarClient.terminateNow).
    func close() { downloadClient.terminateNow() }

    // MARK: Disk scan

    /// (present, bytes) for one repo under `SidecarClient.modelsHome()`. Present
    /// == the HF cache dir exists AND at least ONE materialized snapshot
    /// contains `config.json` plus at least one weights file (*.safetensors /
    /// *.npz), each resolving to a real blob, AND there are real (non-symlink)
    /// bytes on disk. HF materializes each snapshot entry only AFTER that file
    /// fully downloads, so an interrupted fetch leaves a snapshot without those
    /// entries — the old "any snapshot + any bytes" rule read such repos as
    /// present and the app then failed at load time. Every repo OLIV ships has
    /// both entries (verified 2026-07-11 across dev HF cache + app store). HF
    /// stores file bytes in `blobs/` and snapshots are symlinks into them, so
    /// we count only regular files to avoid double-counting the linked
    /// snapshot copies.
    nonisolated static func diskInfo(_ repo: String) -> (present: Bool, bytes: Int64) {
        diskInfo(atDir: SidecarClient.repoCacheDir(repo))
    }

    /// Path-based worker (seam for hermetic tests). The repo dir is symlink-
    /// RESOLVED before enumeration: FileManager.enumerator(at:) silently yields
    /// nothing for a root that is itself a symlink, which made a shared/linked
    /// HF cache (repo dir symlinked into the app's models home) read as
    /// "Not downloaded" forever — present stayed false no matter how many times
    /// the user pressed Download, because the sidecar (Python, follows links)
    /// kept finishing instantly while this check kept counting 0 bytes. The
    /// per-entry symlink skip below is unrelated and stays: HF snapshots/ files
    /// are symlinks into blobs/, skipped to avoid double-counting.
    nonisolated static func diskInfo(atDir path: String) -> (present: Bool, bytes: Int64) {
        let dir = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return (false, 0)
        }
        // Completeness is judged PER SNAPSHOT: one revision dir must hold BOTH
        // markers, and each must resolve through its symlink to a live blob.
        // ORing name matches across the whole tree would false-positive on two
        // differently-incomplete revisions (config in A, weights in B), on
        // .no_exist/ probe markers (empty files hub_hub records for 404'd
        // paths), and on a dangling link whose blob a cache cleaner deleted.
        let snapshotsDir = (dir as NSString).appendingPathComponent("snapshots")
        let revs = ((try? fm.contentsOfDirectory(atPath: snapshotsDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
        let hasCompleteSnapshot = revs.contains { rev in
            let revDir = (snapshotsDir as NSString).appendingPathComponent(rev)
            var hasConfig = false
            var hasWeights = false
            if let en = fm.enumerator(atPath: revDir) {
                for case let entry as String in en {
                    // fileExists(atPath:) FOLLOWS symlinks — false for an
                    // entry whose blob is gone (dangling ≠ downloaded).
                    let full = (revDir as NSString).appendingPathComponent(entry)
                    guard fm.fileExists(atPath: full) else { continue }
                    let name = (entry as NSString).lastPathComponent
                    if name == "config.json" { hasConfig = true }
                    if ["safetensors", "npz"].contains((name as NSString).pathExtension) {
                        hasWeights = true
                    }
                }
            }
            return hasConfig && hasWeights
        }

        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        if let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                  includingPropertiesForKeys: keys, options: []) {
            for case let url as URL in en {
                guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if vals.isSymbolicLink == true { continue }
                if vals.isRegularFile == true { total += Int64(vals.fileSize ?? 0) }
            }
        }
        return (hasCompleteSnapshot && total > 0, total)
    }
}
