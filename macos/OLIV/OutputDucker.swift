// Duck the system output while the mic is open (0.1.10 "music bleeds into the
// mic" pass, half B — the echo canceller in AudioCapture is half A).
//
// WHY. Push-to-talk records whatever the room contains, and on a laptop the
// loudest thing in the room is usually the laptop's own speakers. Music playing
// out loud lands in the utterance, where it costs twice: Whisper INVENTS text
// from it (lyrics, and worse — confident Thai sentences nobody said), and the
// speech that IS there is transcribed against a wall of noise. The echo
// canceller removes what it can model; this removes what it can't, by making
// the speaker quieter for the second or two the key is held.
//
// WHAT IT TOUCHES. The DEFAULT OUTPUT device's volume scalar, per element, and
// nothing else. It does not pause anyone's player, does not use private
// MediaRemote calls, and does not change the output device or its profile — a
// Bluetooth headset keeps its A2DP profile (the regression AudioDevices exists
// to prevent). Volume comes back on release.
//
// OWNERSHIP IS THE WHOLE DESIGN. Every level this class writes is remembered
// per element (`applied`). Before each write it re-reads the device: if the
// level is no longer the one WE last wrote, the user moved it themselves, and
// this class SURRENDERS — it stops ramping, forgets the duck, and never writes
// that device again for this capture. Everything below follows from that rule,
// and it is what makes the five ways this could rob the user of their volume
// impossible:
//
//   1. Release lands mid-fade. The restore ramps back from whatever WE last
//      wrote (not from the fade's final target), so a 40 ms tap on the hotkey
//      restores just as exactly as a 4 s hold. An earlier revision compared the
//      live level against the ramp's TARGET, decided a half-finished fade was a
//      user edit, and left the machine permanently quieter — the bug this
//      paragraph exists to keep dead.
//   2. The user grabs the volume keys mid-dictation. Caught between ramp steps
//      by the ownership check, not just once at release. The honest limit: the
//      check reads the level and then writes, so a change landing inside that
//      one read→write window (microseconds, six times per fade) is overwritten
//      and then reverted to the user's pre-dictation level at release. Closing
//      it entirely needs a Core Audio property listener; the residue is a
//      sub-millisecond window whose worst outcome is the user's own earlier
//      level, never a stranded quiet one, so it is documented rather than
//      chased.
//   3. OLIV dies while ducked. The journal in UserDefaults carries the originals
//      AND the last level we applied, so the next launch restores only the
//      elements still sitting where we left them — a user who deliberately chose
//      a quieter level before relaunching keeps it (`restoreOrphaned`).
//   4. A write silently fails, or the device vanishes mid-restore. Restores are
//      READ BACK and verified; the journal is cleared only once every original
//      is confirmed, so an unverified restore is retried at the next release and
//      again at the next launch instead of being forgotten.
//   5. The device does not land where we wrote, because its volume grid is
//      coarser than the write can explain — a 1/8-step scalar rounds a 0.43
//      request to 0.375. Read as a user edit, that surrenders the element while
//      the device is still quiet and deletes the record that could restore it:
//      stranded, silently and permanently. So the readback is judged by
//      `quantisationCeiling`, sized for the coarsest grid a real device has and
//      not for the common one — the two mistakes it sits between are not equally
//      bad, and only one of them is recoverable.
//
// Quitting is a sixth path, and an async fade loses that race with process exit
// — so termination calls `restoreNow()`, which cancels the ramps and writes the
// originals synchronously.
//
// A device with no settable volume (HDMI, many USB DACs) is a NO-OP, logged
// once. It is deliberately not "mute it instead": "OLIV muted my speakers" is a
// worse bug than "OLIV couldn't duck them".
//
// Per-element, not per-device: a device without a master control exposes its
// channels separately and they need not be equal. Averaging left 0.8 / right 0.4
// into one number and writing it back to both would silently re-centre a balance
// the user set. Each element carries its own original, target and applied level.
//
// The Core Audio plumbing sits behind `VolumeIO` so this state machine — the
// part that can actually strand a volume — is testable without a device (see
// OutputDuckerTests).

import CoreAudio
import Foundation

/// The output-volume plumbing this class needs. A protocol so the ducking state
/// machine can be driven, and its failure paths forced, without a real device.
protocol VolumeIO {
    func defaultOutputDevice() -> AudioDeviceID
    func uid(of device: AudioDeviceID) -> String
    func device(forUID uid: String) -> AudioDeviceID?
    func name(of device: AudioDeviceID) -> String
    /// The output elements whose volume can actually be SET: the main element
    /// when the device has a master control, else its individual channels.
    func settableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement]
    func read(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float?
    @discardableResult
    func write(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float) -> Bool
}

/// The real thing: `kAudioDevicePropertyVolumeScalar` on the output scope.
struct CoreAudioVolumeIO: VolumeIO {
    func defaultOutputDevice() -> AudioDeviceID { AudioDevices.systemDefaultOutputID() }
    func uid(of device: AudioDeviceID) -> String { AudioDevices.deviceUID(device) }
    func device(forUID uid: String) -> AudioDeviceID? { AudioDevices.deviceID(forUID: uid) }
    func name(of device: AudioDeviceID) -> String { AudioDevices.deviceName(device) }

    func settableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if isSettable(device, kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        // Every channel the device actually HAS, not the first two. A 6- or
        // 8-channel output (or an aggregate) with no master control would
        // otherwise keep all its other channels at full level, and a duck that
        // only quiets two of eight speakers is not a duck.
        let channels = AudioDevices.outputChannelCount(device)
        guard channels > 0 else { return [] }
        return (1...AudioObjectPropertyElement(channels)).filter { isSettable(device, $0) }
    }

    func read(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float? {
        var address = CoreAudioVolumeIO.address(element)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    @discardableResult
    func write(
        _ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float
    ) -> Bool {
        var address = CoreAudioVolumeIO.address(element)
        var value = min(max(volume, 0), 1)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    private func isSettable(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = CoreAudioVolumeIO.address(element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func address(
        _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
    }
}

final class OutputDucker {
    typealias Element = AudioObjectPropertyElement

    /// Fraction of the user's volume kept while the mic is open. 0.15 is quiet
    /// enough that music stops dominating the mic but still audible enough that
    /// the user can tell playback is running (silence reads as "OLIV paused my
    /// music", which it must never appear to do).
    static let defaultLevel: Float = 0.15

    /// Ramp shape: a hard volume step on music is audible as a click, a fade
    /// reads as a duck. Short enough not to eat the front of the utterance.
    static let rampDuration: TimeInterval = 0.12
    static let rampSteps = 6

    /// UserDefaults key holding the crash journal (failure mode 3). Deliberately
    /// NOT in OLIVSettings.Key: it is recovery state, not a user preference.
    static let orphanKey = "oliv.duckRestore"

    /// How much of the user's volume to keep while ducked (0…1). Settable for
    /// tests; the app ships `defaultLevel`.
    var level: Float = OutputDucker.defaultLevel

    private let io: VolumeIO
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.oliv.output-ducker", qos: .userInitiated)
    private let lock = NSLock()

    /// The duck we currently OWN. Survives across the down and up ramps and is
    /// cleared only by a verified restore or by surrendering to the user.
    private struct Ducking {
        let device: AudioDeviceID
        let uid: String
        /// What the user had, per element — where a restore must land. Elements
        /// the user takes back are REMOVED (see `surrender`).
        var originals: [Element: Float]
        /// What WE last wrote (as the hardware reports it), per element — the
        /// ownership fingerprint.
        var applied: [Element: Float]
        /// What we are about to write but have not confirmed yet. A run killed
        /// inside that window is recognised by this instead (write-ahead).
        var pending: [Element: Float] = [:]
    }
    private var ducking: Ducking?
    /// Bumped by every duck/restore/restoreNow so an in-flight ramp retires
    /// instead of fighting the current level.
    private var generation: UInt64 = 0
    private var warnedUnsupported = false

    init(io: VolumeIO = CoreAudioVolumeIO(), defaults: UserDefaults = .standard) {
        self.io = io
        self.defaults = defaults
    }

    // MARK: Duck / restore

    /// Fade the default output device down to `level` of the user's volume.
    /// A no-op while a duck is already owned. Returns immediately; the fade runs
    /// on a private queue and calls `completion` when it settles (tests wait on
    /// it — the app doesn't care).
    func duck(completion: (() -> Void)? = nil) {
        // A press that lands while the PREVIOUS release is still fading back:
        // take the duck over rather than declining it. Declining left the old
        // restore running, which raises the music back to full volume during the
        // new hold — the opposite of what the press asked for. The originals stay
        // the ones from the first duck, so the user's real level is never
        // mistaken for the ducked one it is currently passing through.
        // …but only if it is still the SAME device. Read before the lock: no Core
        // Audio call belongs under it.
        let currentDefault = io.defaultOutputDevice()
        lock.lock()
        if let existing = ducking {
            // Both halves matter: the same NUMBER is not the same DEVICE (see
            // `stillTheSameDevice`), and the same device is not the current
            // default.
            if currentDefault == existing.device && stillTheSameDevice(existing) {
                generation &+= 1
                let generation = self.generation
                let originals = existing.originals
                lock.unlock()
                let targets = originals.mapValues {
                    OutputDucker.duckedVolume(original: $0, level: self.level)
                }
                ramp(to: targets, generation: generation, isRestore: false, completion: completion)
                return
            }
            // THE ROUTE MOVED inside the 120 ms release fade — a headset that
            // connects between one press and the next is exactly that. Taking the
            // old ownership over here would duck a device nobody is listening to
            // AND leave the real output at full volume, so this utterance gets the
            // speaker bleed the duck exists to prevent while the old device keeps
            // a level it will never be told to give back.
            lock.unlock()
            if !restoreNow() {
                // A FAILED restore here does not mean the level is unrecoverable.
                // The commonest cause is the very event that got us here: a device
                // that disconnected and came back holds a NEW AudioDeviceID, and
                // `restoreNow` writes to the numeric ID we stored, which is now
                // nobody. The journal is keyed by UID and CAN still find it — so
                // drop the in-memory ownership (whose ID is the stale part) while
                // KEEPING the record, and fall through to the orphan sweep below,
                // which resolves by UID and restores it properly. Declining the
                // press here instead is what made that recovery unreachable.
                NSLog("OLIV OutputDucker: the default output changed and the previous device would "
                      + "not confirm its restore — handing it to the journal sweep")
                abandonOwnershipKeepingJournal()
            }
        } else {
            lock.unlock()
        }

        // Sweep any record left by a run that died — including one for a device
        // that was unplugged at launch and has since come back. Doing it here as
        // well as at launch is what keeps "reconnect the DAC, then dictate" from
        // leaving that DAC parked at a ducked level until the next relaunch.
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)

        let device = io.defaultOutputDevice()
        guard device != 0 else { completion?(); return }
        // No UID = nothing a future launch could match this device by, so a duck
        // here would be one we could not recover from a crash. Skip it.
        let uid = io.uid(of: device)

        // A record SURVIVING that sweep means the previous run's level could not
        // be put back — and the device is therefore still sitting at OUR ducked
        // scalar, not at anything the user chose. Ducking now would snapshot that
        // ducked level as the new "original" and then overwrite the one record
        // that still remembers the real one: the user's actual volume would be
        // gone for good. So this press goes un-ducked and the true original is
        // kept for the next attempt.
        if !uid.isEmpty, let store = defaults.dictionary(forKey: OutputDucker.orphanKey),
           store[uid] != nil {
            NSLog("OLIV OutputDucker: \"%@\" still has an unrestored volume from an earlier run "
                  + "— not ducking it again until that level is back", io.name(of: device))
            completion?()
            return
        }
        guard !uid.isEmpty else { completion?(); return }
        let elements = io.settableElements(of: device)
        guard !elements.isEmpty else {
            warnUnsupportedOnce(device)
            completion?()
            return
        }
        var originals: [Element: Float] = [:]
        for element in elements {
            if let value = io.read(device, element) { originals[element] = value }
        }
        guard !originals.isEmpty else { completion?(); return }

        lock.lock()
        generation &+= 1
        let generation = self.generation
        ducking = Ducking(device: device, uid: uid, originals: originals, applied: originals)
        lock.unlock()

        // Journal BEFORE the first write: everything after this line can die
        // without taking the user's volume with it.
        writeJournal()
        let targets = originals.mapValues { OutputDucker.duckedVolume(original: $0, level: self.level) }
        ramp(to: targets, generation: generation, isRestore: false, completion: completion)
    }

    /// Fade back to the levels the user had before `duck()`, from wherever the
    /// fade actually got to. A no-op when nothing is owned. Elements the user has
    /// since moved themselves are left alone.
    func restore(completion: (() -> Void)? = nil) {
        lock.lock()
        guard let state = ducking else { lock.unlock(); completion?(); return }
        generation &+= 1
        let generation = self.generation
        lock.unlock()
        ramp(to: state.originals, generation: generation, isRestore: true, completion: completion)
    }

    /// Put the originals back RIGHT NOW — no fade, no queue hop — and report
    /// whether every one of them was verified. For application termination,
    /// where an asynchronous fade simply loses the race with process exit.
    @discardableResult
    func restoreNow() -> Bool {
        lock.lock()
        let owned = ducking != nil
        if owned { generation &+= 1 }   // retire any ramp in flight
        lock.unlock()
        guard owned else { return true }

        // ON THE RAMP QUEUE, synchronously. Bumping the generation retires a ramp
        // only at its next check — a step that has already passed that check is
        // still going to write. Running the quit-time restore on the same serial
        // queue means it cannot start until that write is finished, which is the
        // difference between "the volume is back" and "the volume is back, then a
        // stale fade puts it down again and the process exits".
        return queue.sync {
            guard let state = self.snapshot() else { return true }
            // Writing our originals into whoever now holds that id would take a
            // stranger's volume AND report our own device restored. Say the
            // restore did not happen, which keeps the UID-keyed record for the
            // sweep that can still find the real device.
            guard self.stillTheSameDevice(state) else {
                self.logUnverifiedRestore()
                return false
            }
            var verified = true
            for (element, original) in state.originals {
                // An unreadable level is NOT permission to overwrite it. We
                // cannot tell whose it is, and quitting is the one moment where
                // guessing wrong is unrecoverable — the process is about to go
                // away. Leave it and let the journal carry it to the next launch.
                guard let live = self.io.read(state.device, element) else {
                    verified = false
                    continue
                }
                // Ours if the hardware still reads what we last CONFIRMED, or —
                // when a confirmation was lost and `rollBack` could not hand the
                // level back either — what we last WROTE. `pending` is judged by
                // the quantisation bound, like the crash journal: it is a level we
                // ASKED for, and a coarse device is holding its own rounding of
                // it. Judged tightly, the quit path walks past its OWN ducked
                // level, reports the restore verified and clears the journal,
                // leaving the machine quiet at the one moment where there is no
                // next chance.
                let ours = state.applied[element].map({
                        OutputDucker.stillOurs(current: live, applied: $0)
                    }) == true
                    || state.pending[element].map({
                        OutputDucker.readbackIsOurs(after: live, requested: $0)
                    }) == true
                guard ours else {
                    // A fingerprint that says "not ours" means the user owns this
                    // level and it is theirs to keep. NO fingerprint at all means
                    // something is still owed, and the journal has to survive.
                    if state.applied[element] == nil && state.pending[element] == nil {
                        verified = false
                    }
                    continue
                }
                if !self.writeVerified(state.device, element, original) { verified = false }
            }
            if verified { self.clearOwnership() } else { self.logUnverifiedRestore() }
            return verified
        }
    }

    /// Put back levels left ducked by a run that died mid-dictation (failure mode
    /// 3). Called once at launch. Restores ONLY the elements still sitting at the
    /// level we last wrote — anything the user has since changed is theirs. The
    /// journal survives a restore that cannot be verified, so the next launch
    /// tries again; it is dropped when the device is simply gone.
    static func restoreOrphaned(defaults: UserDefaults = .standard,
                                io: VolumeIO = CoreAudioVolumeIO()) {
        guard let store = defaults.dictionary(forKey: orphanKey) else { return }
        for (key, value) in store {
            guard let record = value as? [String: Any], let journal = Journal(record: record) else {
                dropRecord(key, from: defaults)   // malformed: not worth carrying forward
                continue
            }
            guard let device = io.device(forUID: journal.uid) else {
                // The device is not attached RIGHT NOW — which is not the same as
                // "there is nothing to put back". A DAC unplugged before this
                // launch still has our ducked scalar on it and will come back with
                // it, so its record is KEPT (and kept separately from every other
                // device's, so tonight's dictation through the built-in speakers
                // cannot overwrite it). It can only ever restore a level that
                // still carries our fingerprint, so keeping it is harmless.
                continue
            }
            var verified = true
            var restored = false
            for (element, original) in journal.originals {
                guard let live = io.read(device, element) else { verified = false; continue }
                guard journal.owns(element: element, live: live) else { continue }  // user's now
                io.write(device, element, original)
                let readback = io.read(device, element)
                if let readback = readback, abs(readback - original) <= verifyTolerance {
                    restored = true
                } else {
                    verified = false
                }
            }
            if verified {
                dropRecord(journal.uid, from: defaults)
                if restored {
                    NSLog("OLIV OutputDucker: restored the output volume of \"%@\" — a previous "
                          + "run was killed while ducking it", io.name(of: device))
                }
            } else {
                NSLog("OLIV OutputDucker: could not verify the volume restore for \"%@\" — keeping "
                      + "the record for the next launch", io.name(of: device))
            }
        }
    }

    // MARK: Pure seams (device-free — unit-tested in OutputDuckerTests)

    /// The level to fade to: `level` of the user's volume, clamped into 0…1.
    /// Never returns 0 from a non-zero original — silence reads as "OLIV paused
    /// my music" (see `defaultLevel`); a device already at 0 stays at 0.
    static func duckedVolume(original: Float, level: Float) -> Float {
        let clampedLevel = min(max(level, 0.01), 1)
        return min(max(original * clampedLevel, 0), 1)
    }

    /// Is this level still the one WE last wrote? False = the user moved it and
    /// owns it now. THE predicate the whole class turns on — note it compares
    /// against what was APPLIED, never against where a fade was headed.
    static func stillOurs(current: Float, applied: Float) -> Bool {
        abs(current - applied) <= ownershipTolerance(for: applied)
    }

    /// How far a level may sit from what we wrote and still count as ours —
    /// PROPORTIONAL, with a small floor.
    ///
    /// A flat tolerance is wrong at the quiet end, and wrong in the direction
    /// that takes something from the user: ducking a device that was at 0.10
    /// lands near 0.015, so a flat 0.02 makes a user who then MUTES the machine
    /// (0.0) indistinguishable from our own duck — and the restore would put
    /// their sound back on. Scaling with the level keeps a mute detectable while
    /// staying loose enough at normal levels for a device that quantises the
    /// scalar.
    static func ownershipTolerance(for applied: Float) -> Float {
        max(0.005, abs(applied) * 0.05)
    }

    /// Tolerance for "did this write land?", which is a question about the
    /// hardware rather than about who owns the level — devices quantise, so this
    /// one stays flat and forgiving. Sized for a coarse 1/16-step scalar (a write
    /// can legitimately read back up to ~0.031 away); tighter than that and every
    /// step on such a device would look like an outside write and surrender the
    /// duck half-applied.
    static let verifyTolerance: Float = 0.05

    /// How far a readback may sit from what we just wrote and still be the
    /// DEVICE's doing rather than somebody else's write. The wider of the two
    /// bounds, and the one that decides whether an element is surrendered.
    ///
    /// `verifyTolerance` covers a 1/16 grid. It does NOT cover a 1/8 one, where a
    /// legitimate rounding lands 0.0625 away — and the consequence of getting that
    /// wrong is not a cosmetic one: the element is read as a user edit, surrendered
    /// mid-duck, and the machine is left QUIETER than the user set it with the
    /// journal record that could have restored it deleted. That is the exact
    /// outcome the four failure modes in this file's header exist to make
    /// impossible, so the bound is sized for the coarsest grid a real output
    /// device plausibly has (1/8) with headroom, rather than for the common one.
    ///
    /// The cost of the extra width is bounded and already declared: a user edit
    /// landing INSIDE the microsecond read→write window and smaller than this is
    /// laundered into our fingerprint and undone at the release, leaving them
    /// their pre-dictation level. A hand on the volume keys lands between ramp
    /// steps, not inside one, and that is caught by the ownership check with the
    /// tighter proportional `ownershipTolerance` — which is why widening HERE
    /// does not widen the window where a real user change can be missed.
    static let quantisationCeiling: Float = 0.09

    /// Is a level that differs from the one we WROTE explained by the device
    /// itself (its grid), or by someone else writing? Pure, so the boundary is a
    /// test rather than a claim.
    ///
    /// Used wherever a live level is compared against a REQUEST — the post-write
    /// readback, and the `pending` fingerprint in both the ramp and crash
    /// recovery. Never against `applied`, which is a value the hardware itself
    /// reported and so has to match it closely (`stillOurs`).
    static func readbackIsOurs(after: Float, requested: Float) -> Bool {
        // SILENCE IS CATEGORICAL — but only when we asked for a level the device
        // could plainly have delivered. Without any rule the flat ceiling swallows
        // a mute at the quiet end: duck a device sitting at 0.5 and the last
        // request is 0.075, so a user muting the machine mid-dictation would be
        // recorded as OUR level and have their sound switched back on at the
        // release. With the rule applied to EVERY positive request it does the
        // opposite and worse: a device at 0.25 with a 1/8 grid gets a legitimate
        // 0.0375 request whose nearest hardware value IS zero, so the device's own
        // rounding is called a user mute, the element is surrendered, and the
        // machine is left SILENT with its recovery record deleted.
        //
        // Both cannot be had from one readback, so the split is by what we asked
        // for. Above the ceiling, zero cannot be a rounding of our request on any
        // grid we tolerate, so it is the user's. At or below it the two are
        // genuinely indistinguishable, and the tie goes to "ours" — the mistake
        // that ends with the user's own pre-dictation level restored a second
        // later, not the one that ends with a silent machine and nothing left on
        // disk that could undo it.
        if after <= 0 && requested > quantisationCeiling { return false }
        return abs(after - requested) <= quantisationCeiling
    }

    /// Level for step `step` of `steps` on a fade from → to. Step `steps` lands
    /// EXACTLY on `to` (a fade that stops short leaves the volume wrong forever).
    static func rampLevel(from: Float, to: Float, step: Int, steps: Int) -> Float {
        guard steps > 1 else { return to }
        return from + (to - from) * Float(min(step, steps)) / Float(steps)
    }

    /// The whole fade, for tests and for reading the shape at a glance.
    static func rampLevels(from: Float, to: Float, steps: Int) -> [Float] {
        guard steps > 1 else { return [to] }
        return (1...steps).map { rampLevel(from: from, to: to, step: $0, steps: steps) }
    }

    // MARK: The ramp

    /// Walk every owned element from where we last left it to `targets`,
    /// checking ownership before each write. Retires on generation change,
    /// surrenders on a user edit, and (when restoring) verifies the landing
    /// before it lets go of the journal.
    private func ramp(
        to targets: [Element: Float], generation: UInt64, isRestore: Bool,
        completion: (() -> Void)?
    ) {
        let steps = max(OutputDucker.rampSteps, 1)
        let pause = OutputDucker.rampDuration / Double(steps)
        queue.async { [weak self] in
            guard let self = self, let start = self.snapshot() else { completion?(); return }
            for step in 1...steps {
                guard self.isCurrent(generation), let state = self.snapshot() else {
                    completion?()
                    return
                }
                // The id can be reassigned MID-FADE — the device is unplugged
                // between two steps and its number handed to another. Keep ramping
                // and every remaining write, and the ownership check behind it,
                // lands on a stranger. Let the state go without touching the
                // journal: the record is keyed by UID and the sweep can still act
                // on it, whereas surrendering here would delete it.
                guard self.stillTheSameDevice(state) else {
                    self.abandonOwnershipKeepingJournal()
                    completion?()
                    return
                }
                var wrote = false
                for (element, target) in targets {
                    // No confirmed level means `rollBack` could not hand this
                    // element back, or a superseded restore wrote to it. Every ramp
                    // step needs an `applied` to fade from, so skipping here left
                    // the user's output down until they quit (on a release) or the
                    // hold running at FULL volume (on a press) — from nothing worse
                    // than one transient read failure.
                    var current = state.applied[element]
                    if current == nil {
                        if isRestore {
                            self.reclaim(element, on: state, generation: generation)
                            continue
                        }
                        current = self.adopt(element, on: state, generation: generation)
                    }
                    guard let applied = current,
                          let from = start.applied[element] ?? current else { continue }
                    // OWNERSHIP, checked every step — not once at the end. Per
                    // ELEMENT: a user who reaches for one channel of a
                    // per-channel device has not asked us to abandon the other
                    // one half-ducked, so only theirs is released.
                    //
                    // A read that FAILS is not permission to write. It means we
                    // cannot tell whose level this is, and writing into that
                    // uncertainty is how a user's own change gets overwritten —
                    // so the step is skipped and the question asked again next
                    // step. Skipping a step only makes the fade coarser; writing
                    // blind can take something away.
                    guard let live = self.io.read(state.device, element) else { continue }
                    // Ours if it matches what we last CONFIRMED or what we last
                    // WROTE. The two differ exactly when a readback failed: the
                    // device is then sitting on our pending level, and judging it
                    // by `applied` alone would call our own write a user edit —
                    // surrendering a half-ducked device to nobody.
                    //
                    // Judged against `applied` ALONE — a level the hardware itself
                    // reported, so an untouched device returns it again and the
                    // tight proportional tolerance is right.
                    //
                    // Deliberately NOT also against `pending`. A pending value is
                    // one we requested and never confirmed, and the bound it needs
                    // (wide enough for a coarse grid) is wider than a volume-key
                    // press: with applied 0.8 and an unconfirmed request of 0.6867,
                    // a user pressing volume-up to 0.7492 between steps fails the
                    // applied check but PASSES a pending one, so their press would
                    // be overwritten. Recovery still judges by `pending` — there the
                    // alternative is stranding a level, and nothing is authorised by
                    // it. Here the only thing it could buy is another write, and a
                    // write is exactly what must not be authorised from a level we
                    // never confirmed. The failed-read path below closes the case
                    // this used to cover.
                    guard OutputDucker.stillOurs(current: live, applied: applied) else {
                        self.surrender(element)
                        continue
                    }
                    let value = OutputDucker.rampLevel(
                        from: from, to: target, step: step, steps: steps)
                    // WRITE-AHEAD. The journal learns what we are ABOUT to write
                    // before the device does, so a process killed between the two
                    // still recognises its own level at the next launch. Recovery
                    // accepts either fingerprint (see Journal.applied/pending).
                    self.notePending(element, value)
                    // A write-ahead record that did not reach disk buys nothing.
                    // If the journal cannot be persisted, DON'T touch the
                    // hardware for this step: a kill straight afterwards would
                    // leave a ducked device with no fingerprint to recognise it
                    // by, which is precisely the unrecoverable state this whole
                    // ordering exists to avoid. Skipping only makes the fade
                    // coarser.
                    guard self.writeJournal() else { continue }
                    if self.io.write(state.device, element, value) {
                        // Fingerprint what the HARDWARE has, not what we asked
                        // for: devices quantise the scalar, and comparing against
                        // the request would read that rounding as a user edit.
                        //
                        // But only within the quantisation the write itself can
                        // explain — `readbackIsOurs`, whose bound is sized for the
                        // coarsest grid a real device has rather than the common
                        // one, BECAUSE the two mistakes are not symmetric: reading
                        // a coarse device's own rounding as a user edit surrenders
                        // the element while it is still quiet and deletes the record
                        // that could restore it, while the other way round costs the
                        // user their pre-dictation level (the trade this file's
                        // header already declares for this window).
                        //
                        // Past that bound it is someone else writing between our
                        // write and our read — and swallowing THAT into `applied`
                        // would launder the user's own change into ours, so the
                        // restore would later undo it. That is the same theft the
                        // ownership check exists to prevent, one window over.
                        // WE WROTE AND CANNOT SEE WHAT LANDED. Carrying on would
                        // mean authorising the next write from a level nobody has
                        // confirmed, and the only fingerprint we would have to
                        // authorise it with (`pending`) is wide enough to swallow a
                        // real volume-key press. So stop ducking this element and
                        // hand the original back instead — the fade goes coarse,
                        // which costs nothing anyone can hear.
                        guard let after = self.io.read(state.device, element) else {
                            self.rollBack(element, on: state)
                            continue
                        }
                        guard OutputDucker.readbackIsOurs(after: after, requested: value) else {
                            self.surrender(element)
                            continue
                        }
                        self.noteApplied(element, after)
                        wrote = true
                    }
                }
                self.writeJournal()
                guard wrote || self.snapshot() != nil else { completion?(); return }
                if step < steps { Thread.sleep(forTimeInterval: pause) }
            }
            // The generation check guards the FINALISATION too, not just the
            // steps: a restore that has been superseded by a new press must not
            // clear the ownership the new duck is now relying on — that would
            // leave the fresh hold with no state and the music at full volume.
            guard self.isCurrent(generation) else { completion?(); return }
            if isRestore { self.finishRestore(generation: generation) }
            completion?()
        }
    }

    /// Read back every restored element; let go of the journal only once they
    /// all confirm. An unverified restore keeps its record so the next release —
    /// or, failing that, the next launch — tries again.
    /// Judged against what we STILL owe (`state.originals`), not against the set
    /// the ramp started with: an element reclaimed or surrendered along the way is
    /// settled, and holding the journal open for it would mean retrying a level
    /// that is already where it belongs.
    private func finishRestore(generation: UInt64) {
        guard let state = snapshot(), isCurrent(generation) else { return }
        // Same identity question as the ramp: an id that changed hands would have
        // us read a stranger's levels and, finding them wrong, keep the journal —
        // or worse, finding them right by chance, clear it. Neither is ours to
        // decide any more.
        guard stillTheSameDevice(state) else { logUnverifiedRestore(); return }
        var verified = true
        for (element, original) in state.originals {
            // An element with no `applied` is one `rollBack` could not confirm and
            // `reclaim` could not hand back either: we still owe it, so the journal
            // must NOT be cleared on its behalf.
            guard state.applied[element] != nil else { verified = false; continue }
            guard let live = io.read(state.device, element),
                  abs(live - original) <= OutputDucker.verifyTolerance
            else { verified = false; continue }
        }
        if verified {
            // Atomic against a new press: the generation is re-checked INSIDE the
            // same lock that clears the state, so a duck that started after the
            // check above cannot have its fresh ownership deleted by this stale
            // restore (which would leave the new hold un-ducked with nobody
            // holding the volume).
            clearOwnership(ifGeneration: generation)
        } else {
            logUnverifiedRestore()
        }
    }

    // MARK: Ownership bookkeeping

    /// Write a level and CONFIRM it landed. Used wherever a silent Core Audio
    /// failure would otherwise be mistaken for a successful restore.
    private func writeVerified(_ device: AudioDeviceID, _ element: Element, _ value: Float) -> Bool {
        guard io.write(device, element, value), let live = io.read(device, element)
        else { return false }
        return abs(live - value) <= OutputDucker.verifyTolerance
    }

    private func snapshot() -> Ducking? {
        lock.lock(); defer { lock.unlock() }
        return ducking
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == self.generation
    }

    private func noteApplied(_ element: Element, _ value: Float) {
        lock.lock()
        ducking?.applied[element] = value
        ducking?.pending[element] = nil
        lock.unlock()
    }

    /// The level we are about to write, journalled first (see the write-ahead
    /// note in `ramp`).
    private func notePending(_ element: Element, _ value: Float) {
        lock.lock()
        ducking?.pending[element] = value
        lock.unlock()
    }

    /// The user took this element over. Drop it — and only it — from what we own;
    /// when nothing is left, the duck is over.
    ///
    /// Forgetting without putting anything back is safe HERE and only here: the
    /// level is one the user chose, so the device is already sitting exactly
    /// where they want it. That is why `readbackIsOurs` has to be right — an
    /// element that reaches this function because of the DEVICE's own rounding
    /// gets walked away from while it is still quiet, with the record that could
    /// restore it deleted.
    /// Stop ducking an element whose level we can no longer confirm, and PUT THE
    /// ORIGINAL BACK rather than walking away from it.
    ///
    /// The difference from `surrender` is who moved the level: there the user
    /// chose it, here we wrote it and then lost sight of it. If the original
    /// lands we owe nothing and the element is dropped. If it does not, the
    /// element stays OWED — `applied` goes away so nothing writes to it again,
    /// while `originals` and the journal stay, so the release, and failing that
    /// the next launch, try again.
    private func rollBack(_ element: Element, on state: Ducking) {
        guard let original = state.originals[element] else { forget(element); return }
        if writeVerified(state.device, element, original) {
            forget(element)
            return
        }
        lock.lock()
        ducking?.applied[element] = nil
        lock.unlock()
        writeJournal()
        logUnverifiedRestore()
    }

    /// Try again to hand back an element that `rollBack` could not confirm, using
    /// the only fingerprint such an element has: what we last WROTE. Same question
    /// the quit path and the crash journal ask, asked at the release too, so the
    /// three cannot diverge — a transient failure must not decide that the user
    /// keeps a quiet machine until they next quit.
    /// A DUCK that inherited an element with no confirmed level — from a
    /// roll-back that could not be verified, or from a restore that was
    /// superseded between checking its generation and reaching the hardware.
    /// Take what the device actually holds as this hold's starting point, as long
    /// as it is a level WE caused: either what we last wrote (`pending`) or the
    /// user's own original, which is where a superseded restore will have left it.
    ///
    /// Skipping instead is not the safe option it looks like. It leaves the
    /// element out of the fade entirely, so the utterance being recorded right now
    /// runs against full-volume playback — the bleed this whole class exists to
    /// stop — while the level stays owed to nobody.
    private func adopt(_ element: Element, on state: Ducking, generation: UInt64) -> Float? {
        guard let live = io.read(state.device, element) else { return nil }
        let ours = state.pending[element].map({
                OutputDucker.readbackIsOurs(after: live, requested: $0)
            }) == true
            || state.originals[element].map({
                OutputDucker.stillOurs(current: live, applied: $0)
            }) == true
        guard ours, isCurrent(generation) else { return nil }
        noteApplied(element, live)
        return live
    }

    private func reclaim(_ element: Element, on state: Ducking, generation: UInt64) {
        guard let original = state.originals[element],
              let pending = state.pending[element],
              let live = io.read(state.device, element)
        else { return }                       // nothing to judge it by: still owed
        // A NEW PRESS may have taken the duck over while we were reading. From
        // here on everything this function does — writing the original back,
        // letting the element go — belongs to a restore that has been superseded,
        // and doing any of it would hand the fresh hold's state away and leave the
        // music at full volume for the utterance being recorded right now.
        guard isCurrent(generation) else { return }
        guard OutputDucker.readbackIsOurs(after: live, requested: pending) else {
            surrender(element, ifGeneration: generation)   // the user has it now
            return
        }
        if writeVerified(state.device, element, original) {
            forget(element, ifGeneration: generation)
        } else {
            writeJournal()                    // still owed; quit and launch retry
        }
    }

    private func surrender(_ element: Element, ifGeneration expected: UInt64? = nil) {
        forget(element, ifGeneration: expected)
        NSLog("OLIV OutputDucker: output volume changed while dictating — leaving it alone")
    }

    /// The bookkeeping half of `surrender` and `rollBack`: drop one element from
    /// what we own, and end the duck when it was the last one. Says nothing about
    /// WHY — the callers log their own reason.
    private func forget(_ element: Element, ifGeneration expected: UInt64? = nil) {
        lock.lock()
        // Checked INSIDE the lock that clears the state, so a duck that started
        // after the caller's own check cannot have its fresh ownership deleted.
        if let expected = expected, expected != generation {
            lock.unlock()
            return
        }
        let uid = ducking?.uid
        ducking?.applied[element] = nil
        ducking?.pending[element] = nil
        ducking?.originals[element] = nil
        let empty = ducking?.originals.isEmpty ?? true
        if empty { ducking = nil; generation &+= 1 }
        lock.unlock()
        if empty {
            // THIS device's record only. Wiping the whole store here would take
            // an unplugged device's record with it — the one record nothing else
            // can reconstruct, since that device isn't here to be read.
            if let uid = uid { OutputDucker.dropRecord(uid, from: defaults) }
        } else {
            writeJournal()
        }
        NSLog("OLIV OutputDucker: output volume changed while dictating — leaving it alone")
    }

    /// Is the numeric id we stored still the device we stored it FOR?
    ///
    /// An AudioDeviceID is not an identity. Core Audio reassigns them (see
    /// AudioDevices' header), so after a disconnect the same number can belong to
    /// somebody else entirely — and every path that trusts the number alone then
    /// reads a STRANGER's volume through our fingerprint: it does not match, so we
    /// conclude "the user moved it", surrender, and delete the journal record that
    /// was the only way back for the device actually holding our level. The UID is
    /// the identity; this is the one-line question that keeps the two apart.
    private func stillTheSameDevice(_ state: Ducking) -> Bool {
        io.uid(of: state.device) == state.uid
    }

    /// Let go of the IN-MEMORY duck without touching the journal. The one case
    /// that needs it: the state we hold is keyed by a numeric AudioDeviceID that
    /// has gone stale (the device was unplugged and came back under a new one), so
    /// nothing we do with it can reach the hardware — while the record, keyed by
    /// UID, still can. Every other way of letting go drops the record too, which
    /// here would throw away the only thing that could put the level back.
    private func abandonOwnershipKeepingJournal() {
        lock.lock()
        ducking = nil
        generation &+= 1
        lock.unlock()
    }

    private func clearOwnership(ifGeneration expected: UInt64? = nil) {
        lock.lock()
        if let expected = expected, expected != generation {
            lock.unlock()
            return   // superseded — the state now belongs to a newer duck
        }
        let uid = ducking?.uid
        ducking = nil
        generation &+= 1
        lock.unlock()
        guard let uid = uid else { return }
        OutputDucker.dropRecord(uid, from: defaults)
    }

    /// Forget one device's recovery record, leaving any other device's alone.
    static func dropRecord(_ uid: String, from defaults: UserDefaults) {
        var store = defaults.dictionary(forKey: orphanKey) ?? [:]
        store[uid] = nil
        if store.isEmpty {
            defaults.removeObject(forKey: orphanKey)
        } else {
            defaults.set(store, forKey: orphanKey)
        }
        defaults.synchronize()
    }

    private func logUnverifiedRestore() {
        NSLog("OLIV OutputDucker: could not verify the output volume restore — keeping the "
            + "record so the next release (or the next launch) puts it back")
    }

    /// True while a duck is owned — i.e. the volume is down and this object is
    /// on the hook for putting it back. Test seam.
    var isDucking: Bool { snapshot() != nil }

    private func warnUnsupportedOnce(_ device: AudioDeviceID) {
        lock.lock()
        let warn = !warnedUnsupported
        warnedUnsupported = true
        lock.unlock()
        guard warn else { return }
        NSLog("OLIV OutputDucker: \"%@\" has no settable volume — other audio will not be "
              + "lowered while dictating", io.name(of: device))
    }

    // MARK: The crash journal

    /// The persisted form of an owned duck: which device, what the user had, and
    /// what we last wrote (so recovery can tell our level from the user's).
    struct Journal {
        let uid: String
        let originals: [Element: Float]
        let applied: [Element: Float]
        /// Levels written-ahead but never confirmed. Recovery treats an element
        /// sitting at EITHER its applied or its pending level as still ours — the
        /// window between the write and its confirmation is exactly where a
        /// killed process leaves the device.
        let pending: [Element: Float]

        init(uid: String, originals: [Element: Float], applied: [Element: Float],
             pending: [Element: Float] = [:]) {
            self.uid = uid
            self.originals = originals
            self.applied = applied
            self.pending = pending
        }

        init?(record: [String: Any]) {
            guard let uid = record["uid"] as? String, !uid.isEmpty,
                  let originals = record["originals"] as? [String: NSNumber],
                  let applied = record["applied"] as? [String: NSNumber],
                  !originals.isEmpty
            else { return nil }
            self.uid = uid
            self.originals = Journal.decode(originals)
            self.applied = Journal.decode(applied)
            self.pending = Journal.decode(record["pending"] as? [String: NSNumber] ?? [:])
        }

        /// Is `live` a level THIS journal owns for `element` — either the last
        /// confirmed one or the one that was in flight when the run died?
        ///
        /// `pending` is judged by the quantisation bound for the same reason the
        /// live ramp judges it that way: it is a level we ASKED for, and a device
        /// with a coarse grid is holding its own rounding of it. Recovery that
        /// does not recognise that walks past a device it left quiet and — because
        /// an unrecognised element still counts as verified — deletes the only
        /// record that could have put it back.
        func owns(element: Element, live: Float) -> Bool {
            if let applied = applied[element], stillOurs(current: live, applied: applied) {
                return true
            }
            if let pending = pending[element], readbackIsOurs(after: live, requested: pending) {
                return true
            }
            return false
        }

        var record: [String: Any] {
            ["uid": uid,
             "originals": Journal.encode(originals),
             "applied": Journal.encode(applied),
             "pending": Journal.encode(pending)]
        }

        private static func encode(_ levels: [Element: Float]) -> [String: Float] {
            var out: [String: Float] = [:]
            for (element, value) in levels { out[String(element)] = value }
            return out
        }

        private static func decode(_ levels: [String: NSNumber]) -> [Element: Float] {
            var out: [Element: Float] = [:]
            for (key, value) in levels {
                if let element = Element(key) { out[element] = value.floatValue }
            }
            return out
        }
    }

    /// Persist what we own. `pending` MUST go in: it is the entire point of the
    /// write-ahead ordering — a run killed between the device write and its
    /// confirmation is recognised by that fingerprint and no other. (An earlier
    /// revision of this method quietly dropped it, which turned every
    /// write-ahead into a no-op and made recovery mistake OLIV's own level for
    /// the user's.)
    ///
    /// Keyed BY DEVICE UID, not one record for the machine: a device that is
    /// unplugged while still ducked has to keep its record while the user goes on
    /// dictating through another output, and a single-record store would have the
    /// next duck overwrite the only thing that could ever restore it.
    @discardableResult
    private func writeJournal() -> Bool {
        guard let state = snapshot() else { return false }
        let journal = Journal(uid: state.uid, originals: state.originals,
                              applied: state.applied, pending: state.pending)
        var store = defaults.dictionary(forKey: OutputDucker.orphanKey) ?? [:]
        store[state.uid] = journal.record
        defaults.set(store, forKey: OutputDucker.orphanKey)
        // FLUSH. The journal only earns its name if it reaches disk before the
        // hardware write it describes; UserDefaults persists lazily, so a SIGKILL
        // in that gap would leave the device ducked with no fingerprint to
        // recognise it by. synchronize() is soft-deprecated and cheap, and this
        // is exactly the write-ahead case it still exists for. Its result is
        // the caller's signal: an unpersisted journal must not be followed by a
        // hardware write.
        return defaults.synchronize()
    }
}
