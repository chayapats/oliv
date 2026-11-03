// Voice editing: Command mode (#23) and translation mode (#24).
//
//   • Command mode: select text, hold the Command mode shortcut, say what to
//     change ("ทำให้สุภาพขึ้น", "สรุปเป็น bullet"…). The spoken instruction is
//     transcribed like any dictation, the on-device cleanup model rewrites the
//     selection, and the result replaces it through the normal paste, so the
//     undo-last-paste shortcut restores the original.
//   • Translation: speak Thai with the secondary push-to-talk shortcut (or in
//     an app set to translate) and OLIV pastes English.
//
// Both run the sidecar's `transform` command on this Mac (Gemma E2B), also
// with the OLIV API engine selected: the server has no transform endpoint
// yet, so the instruction or dictation is transcribed by the server and the
// rewrite happens locally. The Rust core refuses suspicious rewrites; a
// refused or failed transform never touches the user's text.
//
// Everything here is pure or injectable, so the release worker's decisions
// are unit-tested without models, Accessibility or real key events.

import AppKit
import Foundation

/// What one push-to-talk press does.
enum DictationMode: String, Equatable {
    case dictate, translate, command

    /// Shown on the HUD pill instead of the engine label, so a mode is never
    /// a surprise. nil for plain dictation.
    var hudLabel: String? {
        switch self {
        case .dictate: return nil
        case .translate: return "Thai → English"
        case .command: return "Command mode"
        }
    }

    var hudSymbol: String {
        switch self {
        case .dictate: return "waveform"
        case .translate: return "globe"
        case .command: return "wand.and.stars"
        }
    }

    var processingLabel: String {
        switch self {
        case .dictate: return "Transcribing…"
        case .translate: return "Translating…"
        case .command: return "Editing…"
        }
    }
}

/// The voice-editing settings the controller needs, resolved by the store.
struct VoiceEditConfiguration: Equatable {
    /// Command mode on, with its own hold-to-talk shortcut.
    var commandChord: HotkeyChord?
    /// The secondary push-to-talk shortcut types English.
    var translateWithSecondary = false
    /// Lowercased bundle ids where every dictation is translated.
    var translationApps: Set<String> = []
}

enum VoiceEditPolicy {
    /// Password managers: never read a selection there, never rewrite.
    static let passwordManagers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.lastpass.lastpass",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.dashlane",
        "org.keepassxc.keepassxc",
        "com.enpass.enpass",
        "com.nordpass.macos.nordpass",
        "com.protonpass.mac",
    ]

    enum Block: Equatable {
        case verbatim, passwordManager
    }

    /// Why voice editing must not run in this app, if it must not. Verbatim
    /// apps keep exactly what was said; password managers are never touched.
    static func block(bundleID: String?, verbatimApps: Set<String>) -> Block? {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return nil }
        if passwordManagers.contains(id) { return .passwordManager }
        if verbatimApps.contains(id) { return .verbatim }
        return nil
    }

    /// Mode for a press of the regular push-to-talk shortcut(s).
    static func dictationMode(bundleID: String?, translationApps: Set<String>) -> DictationMode {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return .dictate }
        return translationApps.contains(id) ? .translate : .dictate
    }

    /// Pressing one chord also completes the other: one's keys are all part
    /// of the other's (Right ⌥ inside Right ⌥ + Right ⌘). Two such shortcuts
    /// can't both be hold-to-talk taps: the shorter fires first, and the
    /// longer one's press is ignored. Sharing a key alone is fine.
    static func overlaps(_ a: HotkeyChord, _ b: HotkeyChord) -> Bool {
        let x = Set(a.keys.map(\.keyCode)), y = Set(b.keys.map(\.keyCode))
        return x.isSubset(of: y) || y.isSubset(of: x)
    }

    /// Which tap each shortcut gets. A voice-editing shortcut that overlaps
    /// another shortcut (push-to-talk, undo, or each other) is paused, and
    /// Settings says so: the secondary shortcut then dictates like the
    /// primary, and Command mode stays off.
    static func bindings(_ config: VoiceEditConfiguration, pushToTalk: [HotkeyChord],
                         undo: HotkeyChord?) -> ShortcutBindings {
        let primary = pushToTalk.first
        let secondary = pushToTalk.dropFirst().first
        var result = ShortcutBindings(dictation: pushToTalk)
        if config.translateWithSecondary, let primary, let secondary, secondary != primary {
            let others = [primary] + [undo].compactMap { $0 }
            if others.contains(where: { overlaps(secondary, $0) }) {
                result.translationPaused = true
            } else {
                result.translation = secondary
                result.dictation = pushToTalk.filter { $0 != secondary }
            }
        }
        if let command = config.commandChord {
            let others = pushToTalk + [undo].compactMap { $0 }
            if others.contains(where: { overlaps(command, $0) }) {
                result.commandPaused = true
            } else {
                result.command = command
            }
        }
        return result
    }
}

/// The resolved hold-to-talk shortcuts (see `VoiceEditPolicy.bindings`).
struct ShortcutBindings: Equatable {
    /// Push-to-talk chords that dictate (or translate, in translation apps).
    var dictation: [HotkeyChord]
    /// The secondary shortcut, when it types English.
    var translation: HotkeyChord?
    /// The Command mode shortcut, when on and free of overlaps.
    var command: HotkeyChord?
    /// Translation is on, but the secondary shortcut overlaps another one.
    var translationPaused = false
    /// Command mode is on, but its shortcut overlaps another one.
    var commandPaused = false
}

/// The hold-to-talk shortcut a press or release came from. A recording
/// belongs to the shortcut that started it: only that shortcut's release
/// ends it.
enum HoldShortcut: Equatable {
    case pushToTalk, translation, command
}

/// One `transform` reply. `text` is the original when `applied` is false.
struct TransformResult: Equatable {
    let applied: Bool
    let text: String
    /// "ok", or why nothing changed (see rust/crates/oliv-text/src/transform.rs).
    let flag: String
}

protocol TextTransforming {
    func transform(mode: DictationMode, instruction: String, text: String) throws -> TransformResult
}

extension SidecarClient: TextTransforming {
    /// Above the sidecar's own 120 s ceiling (a cold model load plus up to
    /// ~1,000 generated tokens), so the sidecar reports first.
    static let transformTimeout: TimeInterval = 150.0

    func transform(mode: DictationMode, instruction: String, text: String) throws -> TransformResult {
        let reply = try exchange(["cmd": "transform",
                                  "mode": mode == .command ? "command" : "translate",
                                  "instruction": instruction,
                                  "text": text],
                                 timeout: SidecarClient.transformTimeout)
        return TransformResult(applied: reply["applied"] as? Bool ?? false,
                               text: reply["text"] as? String ?? text,
                               flag: reply["flag"] as? String ?? "invalidReply")
    }
}

/// Everything one voice-edit utterance needs, frozen at release on the main
/// actor and used by the off-main worker.
struct VoiceEditJob {
    let mode: DictationMode
    let block: VoiceEditPolicy.Block?
    let transformer: TextTransforming?
    let reader: SelectionReader
    /// OLIV's last auto-paste, for Command mode with nothing selected.
    let recentPaste: String?
    /// The on-device cleanup model is downloaded.
    let modelReady: Bool
    /// Display name of the undo-last-paste shortcut, for the success notice.
    let undoHint: String?
    /// Command mode: the app, field, window and selection when the key came
    /// up. The selection is read only after the microphone has closed (up to
    /// a few seconds); if it moved meanwhile, nothing is edited.
    var releaseFocus: FocusSnapshot? = nil
    /// Command mode: a password field or secure input was active when the key
    /// came up. Refused outright, whatever is focused by the time the
    /// microphone has closed.
    var releaseSecure = false
}

/// A HUD notice: text + SF Symbol.
struct VoiceEditNotice: Equatable {
    let text: String
    let symbol: String
}

/// What the release worker should do after a voice-edit step.
struct VoiceEditResult: Equatable {
    var outcome: ReleaseOutcome
    /// The text that went to the pasteboard (history, undo bookkeeping).
    var pastedText: String?
    var notice: VoiceEditNotice?
    /// What the pasted text was made from, kept with the Recent entry for
    /// "Report a Wrong Result…". Set whenever `pastedText` is.
    var edit: TranscriptLog.VoiceEdit?
}

enum VoiceEditRunner {
    static let unchanged = "your text is unchanged"

    /// Command mode, run right after the key is released and BEFORE the
    /// instruction is transcribed: capture what to edit while the selection
    /// is certainly still there. A non-nil `refusal` ends the utterance.
    static func prepareCommand(_ job: VoiceEditJob) -> (target: SelectionCapture?, refusal: VoiceEditResult?) {
        if let block = job.block {
            return (nil, refused(block))
        }
        if job.releaseSecure {
            return (nil, refused(.passwordManager))
        }
        if !job.modelReady {
            return (nil, VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                text: "Command mode needs the on-device cleanup model — download it in Settings",
                symbol: "arrow.down.circle")))
        }
        switch job.reader.capture(recentPaste: job.recentPaste) {
        case .selected(let capture):
            if let moved = movedSinceRelease(job.releaseFocus, capture) {
                return (nil, VoiceEditResult(outcome: .nothingToDo, notice: moved == .otherApp
                    ? VoiceEditNotice(text: String(localized: "You switched apps before OLIV read your selection — your text is unchanged"),
                                      symbol: "exclamationmark.triangle")
                    : VoiceEditNotice(text: String(localized: "Your selection changed while OLIV was listening — your text is unchanged"),
                                      symbol: "exclamationmark.triangle")))
            }
            if capture.text.count > maxSelection {
                return (nil, VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                    text: "That selection is too long — select up to \(maxSelection.formatted()) characters",
                    symbol: "text.badge.xmark")))
            }
            return (capture, nil)
        case .secure:
            return (nil, refused(.passwordManager))
        case .none:
            return (nil, VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                text: "Select some text first, then hold the Command mode shortcut",
                symbol: "selection.pin.in.out")))
        }
    }

    /// Whether the selection read now is no longer the one the user had when
    /// the key came up: another app, field, window or range, or (where
    /// Accessibility exposes it) other selected text. nil when it's the same,
    /// or when there's nothing reliable to compare against.
    static func movedSinceRelease(_ frozen: FocusSnapshot?, _ capture: SelectionCapture) -> TargetCheck? {
        guard let frozen, var now = capture.focus else { return nil }
        // With nothing selected, Command mode selects OLIV's last paste
        // itself. That deliberate change is the paste ending at the caret the
        // user left: compare against the caret, not the new range.
        if capture.source == .recentPaste, let caret = frozen.selectedRange, caret.length == 0,
           let paste = now.selectedRange, paste.location + paste.length == caret.location {
            now.selectedRange = caret
        }
        if let moved = SelectionReader.moved(from: frozen, to: now), moved != .unverifiable { return moved }
        if capture.source == .accessibility, let was = frozen.selectedText, was != capture.text { return .changed }
        return nil
    }

    /// Matches `transform::MAX_SOURCE_CHARS` in the Rust core.
    static let maxSelection = 2000

    /// Command mode, after transcription: rewrite `target` and replace it.
    static func finishCommand(instruction: String, target: SelectionCapture,
                                          job: VoiceEditJob, injector: TextInjector) -> VoiceEditResult {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            return VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                text: "Didn’t catch an instruction — \(unchanged)", symbol: "mic.badge.xmark"))
        }
        guard let transformer = job.transformer else {
            return VoiceEditResult(outcome: .nothingToDo, notice: failedNotice("llmError"))
        }
        let result: TransformResult
        do {
            result = try transformer.transform(mode: .command, instruction: instruction, text: target.text)
        } catch {
            return VoiceEditResult(outcome: .nothingToDo, notice: failedNotice("llmError"))
        }
        guard result.applied else {
            return VoiceEditResult(outcome: .nothingToDo, notice: failedNotice(result.flag))
        }
        guard result.text != target.text else {
            return VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                text: "Nothing to change", symbol: "checkmark.circle"))
        }
        // The model took a while: the user may have moved to another app,
        // field or window, or selected something else. Paste only over the
        // exact selection that was edited; otherwise, or when that can't be
        // confirmed, leave the edit on the clipboard (never restored over).
        let edit = TranscriptLog.VoiceEdit(mode: .command, heard: instruction, selection: target.text,
                                           applied: true, flag: result.flag)
        let check = job.reader.verify(target)
        if check != .same {
            injector.inject(result.text, mode: .clipboardOnly)
            return VoiceEditResult(outcome: .pasteNeedsManual, pastedText: result.text,
                                   notice: clipboardNotice(check), edit: edit)
        }
        let outcome = DictationController.paste(result.text, with: injector)
        let undo = job.undoHint.map { " · \($0) undoes it" } ?? ""
        return VoiceEditResult(outcome: outcome, pastedText: result.text,
                               notice: outcome == .pastedOK
                                   ? VoiceEditNotice(text: "Edited\(undo)", symbol: "wand.and.stars") : nil,
                               edit: edit)
    }

    /// Translation: paste English for a Thai `transcript`. Never loses what
    /// was said: anything short of a good translation pastes the transcript.
    static func finishTranslation(transcript: String, job: VoiceEditJob,
                                              injector: TextInjector) -> VoiceEditResult {
        func edit(applied: Bool, flag: String) -> TranscriptLog.VoiceEdit {
            TranscriptLog.VoiceEdit(mode: .translation, heard: transcript, selection: nil,
                                    applied: applied, flag: flag)
        }
        func pasteOriginal(_ notice: VoiceEditNotice?, flag: String) -> VoiceEditResult {
            VoiceEditResult(outcome: DictationController.paste(transcript, with: injector),
                            pastedText: transcript, notice: notice, edit: edit(applied: false, flag: flag))
        }
        if job.block != nil {
            return pasteOriginal(VoiceEditNotice(text: "Translation is off in this app — pasted what you said",
                                                 symbol: "globe"), flag: "blocked")
        }
        guard job.modelReady, let transformer = job.transformer else {
            return pasteOriginal(VoiceEditNotice(
                text: "Translation needs the on-device cleanup model — pasted what you said",
                symbol: "arrow.down.circle"), flag: "noModel")
        }
        let result: TransformResult
        do {
            result = try transformer.transform(mode: .translate, instruction: "", text: transcript)
        } catch {
            return pasteOriginal(VoiceEditNotice(text: "Couldn’t translate — pasted what you said",
                                                 symbol: "exclamationmark.triangle.fill"), flag: "llmError")
        }
        if result.applied {
            return VoiceEditResult(outcome: DictationController.paste(result.text, with: injector),
                                   pastedText: result.text, edit: edit(applied: true, flag: result.flag))
        }
        // Already English: nothing to translate, nothing to report.
        if result.flag == "noThai" { return pasteOriginal(nil, flag: result.flag) }
        return pasteOriginal(VoiceEditNotice(text: "Couldn’t translate that — pasted what you said",
                                             symbol: "exclamationmark.triangle.fill"), flag: result.flag)
    }

    /// Why an edit went to the clipboard instead of replacing the selection.
    static func clipboardNotice(_ check: TargetCheck) -> VoiceEditNotice {
        let text = switch check {
        case .otherApp: "You switched apps — the edit is on the clipboard"
        case .changed: "Your selection changed — the edit is on the clipboard"
        case .same, .unverifiable: "Couldn’t confirm your selection — the edit is on the clipboard"
        }
        return VoiceEditNotice(text: text, symbol: "doc.on.clipboard")
    }

    static func refused(_ block: VoiceEditPolicy.Block) -> VoiceEditResult {
        switch block {
        case .verbatim:
            return VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                text: "Command mode is off in verbatim apps", symbol: "lock"))
        case .passwordManager:
            return VoiceEditResult(outcome: .nothingToDo, notice: VoiceEditNotice(
                text: "Command mode never edits passwords", symbol: "lock.fill"))
        }
    }

    /// The notice for a transform that changed nothing.
    static func failedNotice(_ flag: String) -> VoiceEditNotice {
        switch flag {
        case "tooLong":
            return VoiceEditNotice(text: "That selection is too long — select up to \(maxSelection.formatted()) characters",
                                   symbol: "text.badge.xmark")
        case "llmError", "invalidReply":
            return VoiceEditNotice(text: "Couldn’t reach the on-device model — \(unchanged)",
                                   symbol: "exclamationmark.triangle.fill")
        case "emptySelection":
            return VoiceEditNotice(text: "Select some text first, then hold the Command mode shortcut",
                                   symbol: "selection.pin.in.out")
        default:
            return VoiceEditNotice(text: "OLIV wasn’t sure about that edit — \(unchanged)",
                                   symbol: "exclamationmark.triangle.fill")
        }
    }
}
