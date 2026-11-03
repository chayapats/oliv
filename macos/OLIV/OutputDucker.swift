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
// and it is what makes the six ways this could rob the user of their volume
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
//      and then reverted to the user's pre-dictation level at release. No
//      listener can close it (see WHAT A LISTENER CAN AND CANNOT TELL, below);
//      the residue is a sub-millisecond window whose worst outcome is the
//      user's own earlier level, never a stranded quiet one, so it is
//      documented rather than chased.
//   3. OLIV dies while ducked. The journal in UserDefaults carries the originals
//      AND the last level we applied, so the next launch restores only the
//      elements still sitting where we left them — a user who deliberately chose
//      a quieter level before relaunching keeps it (`restoreOrphaned`).
//   4. A write silently fails, or the device vanishes mid-restore. Restores are
//      READ BACK and verified; the journal is cleared only once every original
//      is confirmed, so an unverified restore is retried at the next release,
//      the next route change (6) and the next launch instead of being forgotten.
//   5. The device does not land where we wrote, because its volume grid is
//      coarser than the write can explain — a 1/8-step scalar rounds a 0.43
//      request to 0.375. Read as a user edit, that surrenders the element while
//      the device is still quiet and deletes the record that could restore it:
//      stranded, silently and permanently. So the readback is judged by
//      `quantisationCeiling`, sized for the coarsest grid a real device has and
//      not for the common one — the two mistakes it sits between are not equally
//      bad, and only one of them is recoverable. The bound applies only inside
//      the microseconds between a write and its read-back, which is also why no
//      listener can retire it (below).
//   6. The OUTPUT ROUTE moves while ducked — Bluetooth headphones connecting or
//      disconnecting during the fade or the hold. Nothing about a volume level
//      says this has happened, and the earlier revision found out only when it
//      next touched the device — a ramp step, or the next press — so headphones
//      that dropped out while lowered came back still lowered and stayed that
//      way until the next dictation, and the speakers left behind when
//      headphones connected stayed down until the key came up. So the route is
//      no longer discovered by accident. Core Audio property listeners
//      report the default output changing, the device list changing and the
//      ducked device dying (`observeRoute`), and EVERY report re-reads the route
//      as it now is rather than interpreting the report — which is what makes a
//      burst of them inside one 120 ms fade (unplugged, then back under a new
//      id) converge without any ordering rules. The device being lowered is let
//      go of the moment it stops being the default or stops existing, and its
//      level goes back through the same UID-keyed record and sweep that crash
//      recovery uses: at once if it is still attached, or the moment it
//      reappears if it is not. The listener is installed only while there is
//      something to protect — an owned duck, or a record for a device that is
//      away — and removed when there is not. It starts with the first press,
//      not at launch: a record that survives the launch sweep (its device was
//      away) is next swept at that press, and followed from then on.
//      The cost, declared: the rest of THAT hold is not ducked on whichever
//      device the sound moved to. Ducking it there and then would mean taking
//      its "original" at the one moment it is least trustworthy — a device that
//      has just connected can still be having its own volume put back by macOS
//      — and restoring that guess later would overwrite the level macOS chose.
//      One utterance may be recorded over full-level playback; the next press
//      ducks the new device normally.
//
// WHAT A LISTENER CAN AND CANNOT TELL. The listeners in 6 watch the ROUTE.
// There is deliberately no listener on the volume scalar itself, although it
// looks like the obvious next step. Core Audio announces OUR writes exactly as
// it announces anybody else's: asynchronously, after the fact, with no writer
// attached. By the time a notification is
// handled, the level it describes has to be read back like any other — so "the
// device rounded our write" and "the user moved it" are still told apart by the
// level and nothing else, listener or not. And the moments at which telling
// them apart MATTERS are the moments OLIV is about to write: it writes nothing
// during the hold, so reading the level just before each ramp step, and before
// every hand-back (release, quit, route change, launch), already sees
// everything a notification could have shown. Acting on a notification any
// earlier would only add judgement points, each one a fresh chance to read a
// device artefact — a headset reporting a bogus level on its way out — as a
// user edit, and walk away from a level OLIV lowered. What a listener cannot
// see at all are the microseconds between our own read, write and read-back:
// that is where the residue in 2 and the grid bound in 5 live.
//
// Quitting is one more path, and an async fade loses that race with process
// exit — so termination calls `restoreNow()`, which cancels the ramps and writes
// the originals synchronously.
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
//
// THREADS. Every device read and write, every journal write and every route
// report is handled on ONE serial queue, in order — `duck()`, `restore()` and
// `restoreNow()` only record the caller's wish under the lock and hand the work
// to it. That is what lets a route report arriving mid-fade, a press arriving
// mid-release and a quit arriving mid-anything be reasoned about one at a time.
// Core Audio delivers listener reports on a second queue of their own, whose
// blocks do nothing but schedule work on the first; nothing ever waits on them.
// The lock guards the shared fields and is never held across a Core Audio call.

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
    /// Start listening for changes to the OUTPUT ROUTE: the default output
    /// device, the set of attached devices and — when `device` is given — that
    /// device dying. `handler` runs on `queue` once per report and is told
    /// nothing on purpose: the route is re-read, never interpreted from the
    /// report. nil = this backend cannot listen, and the ducker learns of a
    /// route change only when it next touches the device (failure mode 6).
    func observeRoute(device: AudioDeviceID?, on queue: DispatchQueue,
                      _ handler: @escaping () -> Void) -> VolumeObservation?
}

/// A live listener registration. `cancel()` removes it and is idempotent.
protocol VolumeObservation: AnyObject {
    func cancel()
}

/// One listener block registered on several Core Audio properties, removed as a
/// unit.
///
/// THE BLOCK IS STORED, NOT RE-CREATED. Core Audio removes a listener by block
/// identity, so removing with a freshly bridged closure would quietly leave the
/// original registered — still firing, for an owner that may be gone.
///
/// The HAL dispatches the block onto `queue` instead of calling it on its own
/// notification thread, so nothing here can hold Core Audio up; and that queue
/// is not the ducker's, so a removal made from the ducker's queue never waits on
/// a block that is itself waiting on the ducker.
final class CoreAudioListener: VolumeObservation {
    typealias Target = (object: AudioObjectID, address: AudioObjectPropertyAddress)

    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var registered: [Target] = []   // guarded by lock
    private var refusedRemovals = 0         // guarded by lock

    /// nil when any `required` registration fails (whatever did register is
    /// removed again); `optional` ones are best-effort.
    init?(required: [Target], optional: [Target] = [], queue: DispatchQueue,
          handler: @escaping () -> Void) {
        self.queue = queue
        self.block = { _, _ in handler() }
        for target in required {
            guard add(target) else {
                cancel()
                return nil
            }
        }
        for target in optional { _ = add(target) }
    }

    deinit { cancel() }

    func cancel() {
        lock.lock()
        let targets = registered
        registered = []
        lock.unlock()
        var refused = 0
        for target in targets {
            var address = target.address
            if AudioObjectRemovePropertyListenerBlock(target.object, &address, queue, block) != noErr {
                refused += 1   // e.g. a device that has already gone: nothing left to remove
            }
        }
        lock.lock()
        refusedRemovals += refused
        lock.unlock()
    }

    /// Removals Core Audio rejected. A block that did not match its own
    /// registration would show up here. Test seam.
    var removalsRefused: Int {
        lock.lock(); defer { lock.unlock() }
        return refusedRemovals
    }

    private func add(_ target: Target) -> Bool {
        var address = target.address
        guard AudioObjectAddPropertyListenerBlock(target.object, &address, queue, block) == noErr
        else { return false }
        lock.lock()
        registered.append(target)
        lock.unlock()
        return true
    }
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

    /// The system's default output and device list are REQUIRED — without them
    /// there is no route to follow. The ducked device's IsAlive is a bonus: the
    /// device list reports a disappearance too, IsAlive can just say so sooner,
    /// and a device that refuses it must not cost us the other two.
    func observeRoute(device: AudioDeviceID?, on queue: DispatchQueue,
                      _ handler: @escaping () -> Void) -> VolumeObservation? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let required: [CoreAudioListener.Target] = [
            (system, CoreAudioVolumeIO.global(kAudioHardwarePropertyDefaultOutputDevice)),
            (system, CoreAudioVolumeIO.global(kAudioHardwarePropertyDevices)),
        ]
        var optional: [CoreAudioListener.Target] = []
        if let device = device, device != 0 {
            optional.append((device, CoreAudioVolumeIO.global(kAudioDevicePropertyDeviceIsAlive)))
        }
        return CoreAudioListener(required: required, optional: optional, queue: queue,
                                 handler: handler)
    }

    private static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
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
    /// THE queue (see THREADS in the header): all device and journal I/O and
    /// all state transitions happen here, one at a time.
    private let queue = DispatchQueue(label: "com.oliv.output-ducker", qos: .userInitiated)
    private let onQueueKey = DispatchSpecificKey<Bool>()
    /// Where Core Audio delivers route reports. Its blocks only schedule a
    /// reconcile on `queue` (see RouteSignal).
    private let listenerQueue = DispatchQueue(
        label: "com.oliv.output-ducker.route-listener", qos: .userInitiated)
    private let lock = NSLock()

    /// The duck we currently OWN. Survives across the down and up ramps and is
    /// cleared only by a verified restore, by surrendering to the user, or —
    /// keeping its journal record — when the route moves away from its device.
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
    /// The caller's LATEST wish, bumped by duck/restore/restoreNow and nothing
    /// else. A press waiting on the queue goes ahead only while it is still the
    /// latest — a release or a quit behind it means the press is already over.
    /// Kept apart from `generation`, which ownership changes bump too: a stale
    /// ramp surrendering its last element must not be able to cancel the press
    /// that arrived while it ran.
    private var intent: UInt64 = 0
    private var warnedUnsupported = false

    // Route listening (failure mode 6). QUEUE-CONFINED: read and written only
    // on `queue`, and in deinit, when nothing else can be running.
    private var routeObservation: VolumeObservation?
    private var observedDevice: AudioDeviceID?
    private var warnedCannotListen = false
    private let routeSignal = RouteSignal()

    init(io: VolumeIO = CoreAudioVolumeIO(), defaults: UserDefaults = .standard) {
        self.io = io
        self.defaults = defaults
        queue.setSpecific(key: onQueueKey, value: true)
        routeSignal.attach(to: self, queue: queue)
    }

    deinit {
        routeObservation?.cancel()
    }

    // MARK: Duck / restore

    /// Fade the default output device down to `level` of the user's volume.
    /// A no-op while a duck is already owned. Returns immediately; the work runs
    /// on the ducker's queue and calls `completion` when it settles (tests wait
    /// on it — the app doesn't care).
    func duck(completion: (() -> Void)? = nil) {
        let wish = recordWish().intent
        queue.async { [weak self] in
            guard let self = self else { completion?(); return }
            let handedOff = self.beginDuck(wish, completion: completion)
            self.syncRouteObservation()
            // `beginDuck` read the default output before the listener existed,
            // so a route change in between produced no report. Look once more
            // now that it listens; the fade hasn't started (it's queued behind
            // this block), so a device that already stopped being the default
            // is handed back before it is lowered.
            if self.snapshot() != nil { self.reconcileRoute() }
            if !handedOff { completion?() }
        }
    }

    /// The body of `duck()`, on the queue. True when `completion` was handed to a
    /// ramp (which calls it); false when the caller still owes it.
    private func beginDuck(_ wish: UInt64, completion: (() -> Void)?) -> Bool {
        // A release (or a quit) already followed this press: the press is over,
        // and ducking now would lower the volume for a hold nobody is making.
        guard isLatest(wish) else { return false }

        // A press that lands while the PREVIOUS release is still fading back:
        // take the duck over rather than declining it. Declining left the old
        // restore running, which raises the music back to full volume during the
        // new hold — the opposite of what the press asked for. The originals stay
        // the ones from the first duck, so the user's real level is never
        // mistaken for the ducked one it is currently passing through.
        // …but only if it is still the SAME device.
        let currentDefault = io.defaultOutputDevice()
        if let existing = snapshot() {
            // Both halves matter: the same NUMBER is not the same DEVICE (see
            // `stillTheSameDevice`), and the same device is not the current
            // default.
            if currentDefault == existing.device && stillTheSameDevice(existing) {
                guard let generation = claim(wish) else { return false }
                ramp(isRestore: false, generation: generation, completion: completion)
                return true
            }
            // THE ROUTE MOVED inside the 120 ms release fade — a headset that
            // connects between one press and the next is exactly that, and the
            // route listener (failure mode 6) may simply not have been heard yet.
            // Taking the old ownership over here would duck a device nobody is
            // listening to AND leave the real output at full volume, so this
            // utterance gets the speaker bleed the duck exists to prevent while
            // the old device keeps a level it will never be told to give back.
            //
            // So let go of the old device and hand it to the sweep below, which
            // finds it by UID and puts its level back if it is still ours. That
            // is deliberately the ONLY way back, rather than a restore through
            // the numeric id we hold: the commonest reason for being here is a
            // device that disconnected and came back, which holds a NEW
            // AudioDeviceID — the old one is now nobody, and a restore through it
            // can only fail (an earlier revision then declined the press, which
            // made the recovery unreachable).
            NSLog("OLIV OutputDucker: the default output changed since the last press — "
                  + "handing the previous device its volume back")
            abandonOwnershipKeepingJournal()
        }

        // Sweep any record left by a run that died — including one for a device
        // that was unplugged at launch and has since come back, and the one just
        // handed over above. Doing it here as well as at launch is what keeps
        // "reconnect the DAC, then dictate" from leaving that DAC parked at a
        // ducked level until the next relaunch.
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)

        let device = io.defaultOutputDevice()
        guard device != 0 else { return false }
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
            return false
        }
        guard !uid.isEmpty else { return false }
        let elements = io.settableElements(of: device)
        guard !elements.isEmpty else {
            warnUnsupportedOnce(device)
            return false
        }
        var originals: [Element: Float] = [:]
        for element in elements {
            if let value = io.read(device, element) { originals[element] = value }
        }
        guard !originals.isEmpty else { return false }

        // Ownership and the press's claim on it are taken together, under the
        // lock: a release that arrived while we were reading the device wins.
        lock.lock()
        guard intent == wish else { lock.unlock(); return false }
        generation &+= 1
        let generation = self.generation
        ducking = Ducking(device: device, uid: uid, originals: originals, applied: originals)
        lock.unlock()

        // Journal BEFORE the first write: everything after this line can die
        // without taking the user's volume with it.
        writeJournal()
        ramp(isRestore: false, generation: generation, completion: completion)
        return true
    }

    /// Fade back to the levels the user had before `duck()`, from wherever the
    /// fade actually got to. A no-op when nothing is owned. Elements the user has
    /// since moved themselves are left alone.
    func restore(completion: (() -> Void)? = nil) {
        let generation = recordWish().generation
        ramp(isRestore: true, generation: generation, completion: completion)
    }

    /// Put the originals back RIGHT NOW — no fade — and report whether every one
    /// of them was verified. For application termination, where an asynchronous
    /// fade simply loses the race with process exit.
    @discardableResult
    func restoreNow() -> Bool {
        // Retire any ramp in flight AND any press still waiting on the queue —
        // unconditionally, not only when something is owned yet: a press whose
        // work has not reached the queue owns nothing at this instant, and would
        // otherwise go on to duck after the quit-time restore had already run.
        _ = recordWish()

        // ON THE RAMP QUEUE, synchronously. Bumping the generation retires a ramp
        // only at its next check — a step that has already passed that check is
        // still going to write. Running the quit-time restore on the same serial
        // queue means it cannot start until that write is finished, which is the
        // difference between "the volume is back" and "the volume is back, then a
        // stale fade puts it down again and the process exits".
        if DispatchQueue.getSpecific(key: onQueueKey) != nil {
            let verified = restoreImmediately()     // already on it: sync would deadlock
            syncRouteObservation()
            return verified
        }
        return queue.sync {
            let verified = self.restoreImmediately()
            self.syncRouteObservation()
            return verified
        }
    }

    /// The body of `restoreNow()`, on the queue.
    private func restoreImmediately() -> Bool {
        guard let state = snapshot() else { return true }
        // Writing our originals into whoever now holds that id would take a
        // stranger's volume AND report our own device restored. Say the restore
        // did not happen, which keeps the UID-keyed record for the sweep that can
        // still find the real device.
        guard stillTheSameDevice(state) else {
            logUnverifiedRestore()
            return false
        }
        var verified = true
        for (element, original) in state.originals {
            // An unreadable level is NOT permission to overwrite it. We cannot
            // tell whose it is, and quitting is the one moment where guessing
            // wrong is unrecoverable — the process is about to go away. Leave it
            // and let the journal carry it to the next launch.
            guard let live = io.read(state.device, element) else {
                verified = false
                continue
            }
            // Ours if the hardware still reads what we last CONFIRMED, or — when
            // a confirmation was lost and `rollBack` could not hand the level back
            // either — what we last WROTE. `pending` is judged by the
            // quantisation bound, like the crash journal: it is a level we ASKED
            // for, and a coarse device is holding its own rounding of it. Judged
            // tightly, the quit path walks past its OWN ducked level, reports the
            // restore verified and clears the journal, leaving the machine quiet
            // at the one moment where there is no next chance.
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
            if !writeVerified(state.device, element, original) { verified = false }
        }
        if verified { clearOwnership() } else { logUnverifiedRestore() }
        return verified
    }

    // MARK: Following the route (failure mode 6)

    /// Something about the output route changed: the default output, the set of
    /// devices, or the ducked device's liveness. On the queue.
    ///
    /// The report itself is not trusted for WHAT changed — several may have been
    /// coalesced, and they arrive in no promised order — so this reads the route
    /// as it is now and makes the state agree with it. That is the whole reason a
    /// burst of reports (a headset dropping out and coming back under a new id,
    /// both inside one fade) needs no special case.
    fileprivate func reconcileRoute() {
        if let state = snapshot() {
            // Gone (or its id handed to somebody else), or simply no longer where
            // the sound goes. Either way there is no fade left to protect on it,
            // and every moment it stays lowered is a moment in which a disconnect
            // can strand it — so let go now, and let the sweep below put its
            // level back: through the UID-keyed record, which is the one handle
            // that still works when the numeric id has gone stale.
            let gone = !stillTheSameDevice(state)
            if gone || io.defaultOutputDevice() != state.device {
                NSLog("OLIV OutputDucker: \"%@\" %@ while its volume was lowered — giving it back",
                      io.name(of: state.device),
                      gone ? "disappeared" : "stopped being the default output")
                abandonOwnershipKeepingJournal()
            }
        }
        // Every record whose device is attached right now gets its level back
        // NOW — a headset that dropped out while lowered is put right the moment
        // it reconnects, not at the next press or launch. The duck still in
        // progress is not an orphan: its record is excluded, or the sweep would
        // undo the very hold the user is in the middle of.
        OutputDucker.restoreOrphaned(defaults: defaults, io: io, except: snapshot()?.uid)
        syncRouteObservation()
    }

    /// Listen while there is something to protect — a duck we own, or a record
    /// for a device that is away and owed its level when it comes back — and not
    /// otherwise. Re-installed when the owned device changes, so its IsAlive
    /// listener follows it. On the queue.
    private func syncRouteObservation() {
        let owned = snapshot()?.device
        let owed = !(defaults.dictionary(forKey: OutputDucker.orphanKey)?.isEmpty ?? true)
        guard owned != nil || owed else {
            routeObservation?.cancel()
            routeObservation = nil
            observedDevice = nil
            return
        }
        if routeObservation != nil && observedDevice == owned { return }
        routeObservation?.cancel()
        // The handler holds the SIGNAL, never the ducker (see RouteSignal).
        let signal = routeSignal
        routeObservation = io.observeRoute(device: owned, on: listenerQueue) { signal.fire() }
        observedDevice = owned
        if routeObservation == nil && !warnedCannotListen {
            warnedCannotListen = true
            NSLog("OLIV OutputDucker: could not listen for output-device changes — a device that "
                  + "connects or disconnects while ducked is noticed at the next press instead")
        }
    }

    /// Record a new wish from the caller and retire whatever ramp is in flight.
    private func recordWish() -> (intent: UInt64, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        intent &+= 1
        generation &+= 1
        return (intent, generation)
    }

    private func isLatest(_ wish: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intent == wish
    }

    /// A fresh ramp generation for `wish` — unless a newer wish has arrived.
    private func claim(_ wish: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard intent == wish else { return nil }
        generation &+= 1
        return generation
    }

    /// Put back levels left ducked by a run that died mid-dictation (failure mode
    /// 3), or by a duck whose device dropped out or stopped being the default
    /// (failure mode 6). Called at launch, at every press and on every route
    /// change. Restores ONLY the elements still sitting at the level we last
    /// wrote — anything the user has since changed is theirs. The journal
    /// survives a restore that cannot be verified, so the next sweep tries again;
    /// it is KEPT while the device is simply away.
    ///
    /// `except` names the device whose duck is in progress right now: its record
    /// is the live journal of that duck, not an orphan, and sweeping it would put
    /// the user's volume back in the middle of their hold.
    static func restoreOrphaned(defaults: UserDefaults = .standard,
                                io: VolumeIO = CoreAudioVolumeIO(),
                                except inProgress: String? = nil) {
        guard let store = defaults.dictionary(forKey: orphanKey) else { return }
        for (key, value) in store {
            if let inProgress = inProgress, key == inProgress { continue }
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
                    NSLog("OLIV OutputDucker: restored the output volume of \"%@\" — it was left "
                          + "lowered by a run that ended or a route that moved while ducking it",
                          io.name(of: device))
                }
            } else {
                NSLog("OLIV OutputDucker: could not verify the volume restore for \"%@\" — keeping "
                      + "the record for the next attempt", io.name(of: device))
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

    /// Walk every owned element from where we last left it to the duck's
    /// targets (or, restoring, to the originals), checking ownership before each
    /// write. Retires on generation change, surrenders on a user edit, and (when
    /// restoring) verifies the landing before it lets go of the journal.
    /// `completion` runs once the ramp is over, however it ended.
    private func ramp(isRestore: Bool, generation: UInt64, completion: (() -> Void)?) {
        let steps = max(OutputDucker.rampSteps, 1)
        let pause = OutputDucker.rampDuration / Double(steps)
        queue.async { [weak self] in
            guard let self = self else { completion?(); return }
            // Every way out of the ramp goes through here, so the listeners
            // match what is owned before anyone waiting on the ramp looks.
            let finish = {
                self.syncRouteObservation()
                completion?()
            }
            // Superseded before it started (a release behind this press, a press
            // behind this release), or nothing is owned any more: nothing to do.
            guard self.isCurrent(generation), let start = self.snapshot() else {
                finish()
                return
            }
            // Targets come from the ownership as it stands NOW, not from when the
            // ramp was asked for: an element surrendered in between is not ours to
            // move, and a duck taken over from a fading restore keeps the FIRST
            // duck's originals (see `beginDuck`).
            let targets = isRestore
                ? start.originals
                : start.originals.mapValues {
                    OutputDucker.duckedVolume(original: $0, level: self.level)
                }
            for step in 1...steps {
                guard self.isCurrent(generation), let state = self.snapshot() else {
                    finish()
                    return
                }
                // The id can be reassigned MID-FADE — the device is unplugged
                // between two steps and its number handed to another. Keep ramping
                // and every remaining write, and the ownership check behind it,
                // lands on a stranger. Let the state go but KEEP the journal: the
                // record is keyed by UID and the sweep can still act on it — the
                // route listener runs that sweep the moment the device is back —
                // whereas surrendering here would delete it.
                guard self.stillTheSameDevice(state) else {
                    self.abandonOwnershipKeepingJournal()
                    finish()
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
                guard wrote || self.snapshot() != nil else { finish(); return }
                if step < steps { Thread.sleep(forTimeInterval: pause) }
            }
            // The generation check guards the FINALISATION too, not just the
            // steps: a restore that has been superseded by a new press must not
            // clear the ownership the new duck is now relying on — that would
            // leave the fresh hold with no state and the music at full volume.
            guard self.isCurrent(generation) else { finish(); return }
            if isRestore { self.finishRestore(generation: generation) }
            finish()
        }
    }

    /// Read back every restored element; let go of the journal only once they
    /// all confirm. An unverified restore keeps its record so the next release —
    /// or, failing that, the next route change or launch — tries again.
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

    /// Let go of the IN-MEMORY duck without letting go of the journal. For the
    /// cases where the state we hold can no longer reach the hardware the user
    /// is listening to — the numeric AudioDeviceID has gone stale (the device
    /// was unplugged, or came back under a new one), or the device is no longer
    /// the default output — while the record, keyed by UID, still can. Every
    /// other way of letting go drops the record too, which here would throw away
    /// the only thing that could put the level back.
    ///
    /// The record is written ONE MORE TIME first: from here on it is all that
    /// is left, so it has to be the newest truth, not the last step's.
    private func abandonOwnershipKeepingJournal() {
        writeJournal()
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

/// What a route listener calls, and the only thing it holds.
///
/// It keeps the ducker WEAKLY and never even loads that reference on the
/// listener queue — only inside the block it puts on the ducker's own queue.
/// Loading it there would make the listener queue a place where the ducker can
/// be released for the last time, and its deinit would then be removing the
/// listener from inside that listener's own callback.
///
/// Reports are coalesced: however many arrive before the reconcile runs, one
/// reconcile reads the route once. A report that arrives while a reconcile is
/// running schedules another, so nothing is missed.
private final class RouteSignal {
    private let lock = NSLock()
    private weak var ducker: OutputDucker?   // guarded by lock
    private var queue: DispatchQueue?        // guarded by lock
    private var scheduled = false            // guarded by lock

    func attach(to ducker: OutputDucker, queue: DispatchQueue) {
        lock.lock()
        self.ducker = ducker
        self.queue = queue
        lock.unlock()
    }

    /// Any thread — in practice Core Audio's listener queue. Never blocks.
    func fire() {
        lock.lock()
        guard !scheduled, let queue = queue else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.async { [self] in
            self.lock.lock()
            self.scheduled = false
            let ducker = self.ducker
            self.lock.unlock()
            ducker?.reconcileRoute()
        }
    }
}
