// OutputDucker tests — the state machine, not just the arithmetic.
//
// The thing that can actually hurt a user here is a stranded output volume, and
// every way that happens is a SEQUENCE (release lands mid-fade, the user grabs
// the volume keys, a write fails, the app quits, the app is killed and relaunched)
// rather than a formula. So the Core Audio plumbing sits behind `VolumeIO` and
// these tests drive the real duck/restore code against a fake device, including
// the failure paths a real device won't produce on demand.

import CoreAudio
import XCTest
@testable import OLIV

/// A fake output device: settable elements, per-element levels, and switches for
/// the two things hardware does that code usually forgets — writes that fail,
/// and a user turning the knob at the worst possible moment.
final class FakeVolumeIO: VolumeIO {
    let device: AudioDeviceID = 42
    let deviceUID = "fake-output-device"
    var elements: [AudioObjectPropertyElement]
    var levels: [AudioObjectPropertyElement: Float]
    var writesFail = false
    var readsFail = false
    var deviceMissing = false
    /// The device's volume GRID. Real scalars are quantised (a TV or a cheap DAC
    /// can have as few as eight steps), so a write lands on the nearest multiple
    /// of this and reads back as something nobody asked for. nil = the idealised
    /// continuous device the other tests use.
    var quantum: Float?
    /// Called before every write — the seam for "the hotkey is released mid-fade".
    var beforeWrite: ((AudioObjectPropertyElement, Float) -> Void)?
    /// Called after every write — the seam for "the user moves the volume
    /// mid-dictation", i.e. in the gap BETWEEN two ramp steps, which is where a
    /// human hand lands (the read→write window inside one step is microseconds;
    /// see the ownership note in OutputDucker).
    var afterWrite: ((AudioObjectPropertyElement, Float) -> Void)?
    private(set) var writeCount = 0

    init(elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain],
         level: Float = 0.8) {
        self.elements = elements
        self.levels = Dictionary(uniqueKeysWithValues: elements.map { ($0, level) })
    }

    func defaultOutputDevice() -> AudioDeviceID { deviceMissing ? 0 : device }
    func uid(of device: AudioDeviceID) -> String { deviceUID }
    func device(forUID uid: String) -> AudioDeviceID? {
        (!deviceMissing && uid == deviceUID) ? device : nil
    }
    func name(of device: AudioDeviceID) -> String { "Fake Speakers" }
    func settableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] { elements }
    func read(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float? {
        readsFail ? nil : levels[element]
    }
    @discardableResult
    func write(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float) -> Bool {
        beforeWrite?(element, volume)
        writeCount += 1
        guard !writesFail else { return false }
        levels[element] = quantum.map { (volume / $0).rounded() * $0 } ?? volume
        afterWrite?(element, volume)
        return true
    }
}

/// Two output devices with independent levels and a settable default — the one
/// thing the single-device fake cannot express: the route moving between a
/// release and the next press.
final class FakeTwoDeviceVolumeIO: VolumeIO {
    var current: AudioDeviceID = 46
    var levels: [AudioDeviceID: Float] = [46: 0.8, 47: 0.6]
    /// UID per device, kept SEPARATE from the numeric ID so a test can do what
    /// Core Audio does: hand a reconnected device a brand-new AudioDeviceID while
    /// its UID stays the same.
    var uids: [AudioDeviceID: String] = [46: "device-a", 47: "device-b"]

    /// Unplug `device` and bring it back under `newID`, carrying its level — the
    /// event that makes a stored AudioDeviceID point at nobody.
    func reconnect(_ device: AudioDeviceID, as newID: AudioDeviceID) {
        levels[newID] = levels.removeValue(forKey: device)
        uids[newID] = uids.removeValue(forKey: device)
    }

    /// Unplug `device` and hand its freed numeric id to a DIFFERENT one — the
    /// nastier half of the same Core Audio behaviour, where the stored id stays
    /// valid but stops meaning what it meant.
    func reassign(_ device: AudioDeviceID, toUID uid: String, level: Float) {
        levels.removeValue(forKey: device)
        uids.removeValue(forKey: device)
        uids[device] = uid
        levels[device] = level
    }

    func defaultOutputDevice() -> AudioDeviceID { current }
    func uid(of device: AudioDeviceID) -> String { uids[device] ?? "" }
    func device(forUID uid: String) -> AudioDeviceID? {
        uids.first(where: { $0.value == uid })?.key
    }
    func name(of device: AudioDeviceID) -> String { "Fake Output \(device)" }
    func settableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain]
    }
    func read(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float? {
        levels[device]
    }
    @discardableResult
    func write(
        _ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float
    ) -> Bool {
        levels[device] = volume
        return true
    }
}

final class OutputDuckerTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.oliv.tests.ducker.\(UUID().uuidString)")!
    }

    /// Run a duck (or restore) and wait for its fade to settle.
    private func settle(_ operation: (@escaping () -> Void) -> Void) {
        let done = expectation(description: "ramp settled")
        operation { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: The happy path

    func testDuckLowersAndRestorePutsItBackExactly() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8 * 0.15, accuracy: 1e-5)
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5)
        XCTAssertFalse(ducker.isDucking, "a verified restore hands ownership back")
    }

    // THE bug this file exists for. A quick tap releases the hotkey while the
    // FADE is still running: the level is somewhere between the original and the
    // target, and an implementation that compares it against the ramp's TARGET
    // reads that as "the user moved it", walks away, and leaves the machine
    // permanently quieter. The restore must land on the original from wherever
    // the fade actually got to.
    func testReleaseMidFadeStillRestoresTheOriginal() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        // Release as soon as the very first fade step has been written.
        var released = false
        io.beforeWrite = { _, _ in
            guard !released else { return }
            released = true
            DispatchQueue.global().async { ducker.restore() }
        }
        settle { ducker.duck(completion: $0) }
        // Both ramps are done when the level stops moving.
        let settled = expectation(description: "level settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5,
                       "a release during the fade must still restore the user's level")
        XCTAssertFalse(ducker.isDucking)
    }

    // A device whose volume GRID is coarser than one write can explain: with 1/8
    // steps a ramp step asking for 0.43125 reads back 0.375, which is 0.056 away
    // — past verifyTolerance. Judged by that alone it looks like a stranger's
    // write, so the element is surrendered mid-duck and the device is left parked
    // at OLIV's ducked level with its journal record deleted: quieter than the
    // user set it, silently, with nothing left that could put it back. THE
    // failure this class exists to make impossible, so it gets a device that
    // produces it on demand.
    func testACoarselyQuantisedDeviceDucksAndComesBackExactly() {
        let io = FakeVolumeIO(level: 0.75)
        io.quantum = 0.125          // worst-case rounding 0.0625, wider than
                                    // verifyTolerance and narrower than the ceiling
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        XCTAssertLessThan(io.levels[kAudioObjectPropertyElementMain]!, 0.4,
                          "the duck must actually apply on a coarse device, not bail out of it")
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.75, accuracy: 1e-5,
                       "a coarse volume grid must not cost the user their level")
        XCTAssertFalse(ducker.isDucking)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey),
                     "nothing is owed, so nothing should be left in the journal")
    }

    // The boundary itself, without the ramp around it: a 1/8 grid's rounding is
    // the device's, a hand on the volume keys is not.
    func testReadbackOwnershipSeparatesRoundingFromAUserWrite() {
        XCTAssertTrue(OutputDucker.readbackIsOurs(after: 0.375, requested: 0.43125),
                      "a 1/8-step device rounding our own write is still our level")
        XCTAssertTrue(OutputDucker.readbackIsOurs(after: 0.6875, requested: 0.6875))
        XCTAssertFalse(OutputDucker.readbackIsOurs(after: 0.45, requested: 0.6867),
                       "a level 0.24 from the one we wrote is somebody else's")
    }

    // A readback of ZERO, which is the one level whose two possible causes have
    // very different costs. Above the ceiling no tolerated grid rounds our request
    // down to silence, so zero is the user muting the machine and it is theirs.
    // At or below the ceiling the two are indistinguishable — a 1/8-grid device
    // asked for 0.0375 genuinely lands on zero — and the tie goes to "ours",
    // because being wrong that way restores the user's own level a second later
    // while the other way leaves the machine silent with its record deleted.
    func testAMuteIsTheUsersOnlyWhenWeAskedForAnAudibleLevel() {
        XCTAssertFalse(OutputDucker.readbackIsOurs(after: 0.0, requested: 0.12),
                       "we asked for an audible level: silence is the user's doing")
        XCTAssertTrue(OutputDucker.readbackIsOurs(after: 0.0, requested: 0.0375),
                      "a request this quiet can legitimately round to zero on a coarse grid")
        XCTAssertTrue(OutputDucker.readbackIsOurs(after: 0.0, requested: 0.0),
                      "and a device the user already had muted is not a user edit")
    }

    // The same rule with the whole state machine behind it: a QUIET device with a
    // coarse grid (0.25 on 1/8 steps) has a duck target of 0.0375, whose nearest
    // hardware value is zero. Reading that as a user mute surrenders the element
    // and deletes the record — leaving the machine SILENT, permanently, which is
    // strictly worse than every mistake this class is allowed to make.
    func testAQuietCoarseDeviceIsNeverLeftSilent() {
        let io = FakeVolumeIO(level: 0.25)
        io.quantum = 0.125
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.25, accuracy: 1e-5,
                       "a duck that rounds all the way to silence must still come back")
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // QUITTING with a level we never confirmed AND could not hand back: the
    // confirmation read was lost, and the roll-back write failed too, so the
    // device is sitting on a level recorded only as `pending`. The quit path has
    // to recognise that as its own — judged by the confirmed value alone it walks
    // past it, reports the restore verified, and clears the journal, leaving the
    // machine quiet with the process already going away.
    func testQuittingRestoresALevelItOnlyEverRecordedAsPending() {
        let io = FakeVolumeIO(level: 0.75)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        var writes = 0
        io.afterWrite = { _, _ in
            writes += 1
            if writes == 1 { io.readsFail = true; io.writesFail = true }
        }
        settle { ducker.duck(completion: $0) }
        io.afterWrite = nil
        io.readsFail = false
        io.writesFail = false
        let unconfirmed = io.levels[kAudioObjectPropertyElementMain]!
        XCTAssertLessThan(unconfirmed, 0.75, "precondition: the device is sitting on our write")

        XCTAssertTrue(ducker.restoreNow(), "the quit path must recognise its own pending level")
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.75, accuracy: 1e-5)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // A press that lands while the previous release is fading, AFTER the default
    // output changed — a headset connecting between two presses. Taking the old
    // ownership over ducks a device nobody is listening to and leaves the real
    // output at full volume: the utterance gets the speaker bleed this exists to
    // prevent, and the old device keeps a level nothing will hand back.
    func testARouteChangeDuringTheReleaseDucksTheNewDefault() {
        let io = FakeTwoDeviceVolumeIO()
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }          // ducks device 46
        ducker.restore()                                 // release: fade in flight
        io.current = 47                                  // …and the route moves
        settle { ducker.duck(completion: $0) }           // press again
        XCTAssertEqual(io.levels[46]!, 0.8, accuracy: 1e-5,
                       "the device we are leaving must be handed back, not left ducked")
        XCTAssertLessThan(io.levels[47]!, 0.6,
                          "the device the user is actually listening to is the one to duck")
    }

    // The same route change, but the device we were ducking DISCONNECTED and came
    // back under a new AudioDeviceID — which is what Core Audio does, and what
    // makes the numeric ID we stored point at nobody. The in-memory restore can
    // only fail; the journal is keyed by UID and can still find the device, so
    // the press must hand the problem to the orphan sweep rather than declining
    // and leaving the reconnected device parked at OLIV's ducked level.
    func testAReconnectedDeviceIsRestoredByUIDNotByStaleID() {
        let io = FakeTwoDeviceVolumeIO()
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }
        XCTAssertLessThan(io.levels[46]!, 0.8, "precondition: 46 is ducked")

        io.reconnect(46, as: 48)      // unplugged and back under a new ID…
        io.current = 47               // …with something else now the default

        settle { ducker.duck(completion: $0) }
        XCTAssertEqual(io.levels[48]!, 0.8, accuracy: 1e-5,
                       "the reconnected device must get the user's level back, found by UID")
        XCTAssertLessThan(io.levels[47]!, 0.6, "and the new default is what gets ducked")
    }

    // The nastier half: the id we stored is still VALID, it just belongs to
    // somebody else now. Trusting the number means reading a stranger's volume
    // through our fingerprint, deciding "the user moved it", and deleting the
    // journal of the device that is actually still holding our ducked level —
    // after which no launch and no sweep can ever put it back.
    func testAReassignedDeviceIDDoesNotDestroyTheOriginalDevicesRecord() {
        let io = FakeTwoDeviceVolumeIO()
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }        // ducks device-a, id 46
        let ducked = io.levels[46]!
        XCTAssertLessThan(ducked, 0.8, "precondition: device-a is ducked")

        // device-a is unplugged and its id 46 is handed to a different device.
        io.reassign(46, toUID: "device-c", level: 0.6)

        settle { ducker.duck(completion: $0) }
        XCTAssertNotNil(defaults.dictionary(forKey: OutputDucker.orphanKey),
                        "device-a's record is the only way back — it must survive")
        XCTAssertLessThan(io.levels[46]!, 0.6,
                          "the stranger that now holds id 46 is ducked from ITS own level")

        // …and when device-a comes back, under yet another id, the surviving
        // record is what puts it right.
        io.levels[48] = ducked
        io.uids[48] = "device-a"
        settle { ducker.restore(completion: $0) }     // release the stranger
        settle { ducker.duck(completion: $0) }        // the orphan sweep runs here
        XCTAssertEqual(io.levels[48]!, 0.8, accuracy: 1e-5,
                       "device-a is found by UID and given the user's level back")
    }

    // The write-ahead fingerprint on a device that QUANTISES. The run is killed
    // between the write and its confirmation, so the journal carries `pending`
    // (what we asked for, 0.43125) while the hardware holds its own rounding of
    // it (0.375). Recovery has to recognise that as OLIV's level: an element it
    // does not recognise is skipped AND still counts as verified, so the record
    // is deleted and a device we left quiet stays quiet forever.
    func testRecoveryRecognisesAQuantisedPendingLevel() {
        let journal = OutputDucker.Journal(
            uid: "fake-output-device",
            originals: [kAudioObjectPropertyElementMain: 0.75],
            applied: [kAudioObjectPropertyElementMain: 0.5],
            pending: [kAudioObjectPropertyElementMain: 0.43125])
        XCTAssertTrue(journal.owns(element: kAudioObjectPropertyElementMain, live: 0.375),
                      "the device's rounding of our own pending write is ours to restore")
        XCTAssertFalse(journal.owns(element: kAudioObjectPropertyElementMain, live: 0.0),
                       "a user who muted the machine before relaunching keeps it")

        // …and end to end: the record is used, not dropped.
        let io = FakeVolumeIO(level: 0.375)
        io.quantum = 0.125
        let defaults = makeDefaults()
        defaults.set([journal.uid: journal.record], forKey: OutputDucker.orphanKey)
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.75, accuracy: 1e-5,
                       "a killed run's quantised duck must be put back at the next launch")
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // Press-release-press-release: no drift, and the second duck must start from
    // the user's real level rather than from a leftover ducked one.
    func testRepeatedDuckRestoreDoesNotDrift() {
        let io = FakeVolumeIO(level: 0.6)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        for _ in 0..<3 {
            settle { ducker.duck(completion: $0) }
            settle { ducker.restore(completion: $0) }
            XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.6, accuracy: 1e-5)
        }
    }

    // MARK: The user's choice wins

    // Volume keys pressed mid-dictation: the ducker notices between ramp steps,
    // stops writing, and the restore leaves the user's level alone.
    func testUserVolumeChangeDuringTheFadeIsNotClobbered() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        var stolen = false
        io.afterWrite = { [weak io] _, _ in
            guard !stolen else { return }
            stolen = true
            io?.levels[kAudioObjectPropertyElementMain] = 0.45   // the user turns it up
        }
        settle { ducker.duck(completion: $0) }
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.45, accuracy: 1e-5,
                       "the level the user chose must survive the dictation")
        XCTAssertFalse(ducker.isDucking, "ownership was surrendered, not held")
    }

    // A volume-key press between ramp steps, in the run where the confirmation
    // read of our own previous write was LOST. The device is then sitting on a
    // level we never confirmed, and the fingerprint that would cover it is wide
    // enough (it has to be, for a coarse grid) to swallow a real key press —
    // 1/16 of the range. Authorising another write from it overwrites the user;
    // the ducker must hand the level back instead.
    func testAVolumeKeyPressAfterALostConfirmationReadIsNotOverwritten() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        var writes = 0
        io.afterWrite = { _, _ in
            writes += 1
            if writes == 1 { io.readsFail = true }        // lose the confirmation read
        }
        settle { ducker.duck(completion: $0) }
        io.afterWrite = nil
        io.readsFail = false
        // The user presses volume-up once, from where our write actually landed.
        let userChose = io.levels[kAudioObjectPropertyElementMain]! + 0.0625
        io.levels[kAudioObjectPropertyElementMain] = userChose

        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, userChose, accuracy: 1e-5,
                       "the level the user chose with the volume keys must survive")
    }

    // A TRANSIENT I/O failure must not cost the user their volume for the rest of
    // the session. The confirmation read and the roll-back write both fail, which
    // leaves the element owed with no confirmed level; the hardware then recovers.
    // Releasing the key has to hand the original back there and then — leaving it
    // to the quit path or the next launch means the machine simply stays quiet
    // while the user goes on working, from one lost read.
    func testAnOwedElementIsReclaimedByTheOrdinaryRelease() {
        let io = FakeVolumeIO(level: 0.8)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        var writes = 0
        io.afterWrite = { _, _ in
            writes += 1
            if writes == 1 { io.readsFail = true; io.writesFail = true }
        }
        settle { ducker.duck(completion: $0) }
        io.afterWrite = nil
        io.readsFail = false
        io.writesFail = false                       // …and the hardware recovers
        XCTAssertLessThan(io.levels[kAudioObjectPropertyElementMain]!, 0.8,
                          "precondition: the output is sitting on our unconfirmed write")

        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5,
                       "the release must hand the level back, not wait for a quit")
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
        XCTAssertFalse(ducker.isDucking)
    }

    // A new press landing while a RECLAIM is in flight. The reclaim belongs to a
    // restore that has just been superseded, so committing it would write the
    // original back over the fresh hold and hand away the ownership that hold
    // depends on — leaving the new utterance recorded at full playback volume,
    // with nobody holding the level.
    func testAReclaimSupersededByANewPressDoesNotClearTheNewHold() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        var writes = 0
        io.afterWrite = { _, _ in
            writes += 1
            if writes == 1 { io.readsFail = true; io.writesFail = true }
        }
        settle { ducker.duck(completion: $0) }        // leaves an owed, unconfirmed element
        io.afterWrite = nil
        io.readsFail = false
        io.writesFail = false

        // Release and press again immediately: the second press must win.
        let pressed = expectation(description: "the new hold settled")
        ducker.restore()
        ducker.duck { pressed.fulfill() }
        wait(for: [pressed], timeout: 5)

        XCTAssertTrue(ducker.isDucking, "the new hold must still own the level")
        XCTAssertLessThan(io.levels[kAudioObjectPropertyElementMain]!, 0.8,
                          "and the output must be DOWN for the utterance being recorded")
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5,
                       "…and the user's real level is still what finally comes back")
    }

    // The press landing in the ONE window a generation check cannot cover: after
    // reclaim has validated its generation and before its hardware write lands.
    // The bookkeeping is protected, so the new hold keeps its ownership — but it
    // inherits an element with no confirmed level, and a hold that skips that
    // element records its utterance against full-volume playback.
    func testAPressLandingInsideAReclaimsWriteStillEndsUpDucked() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        var writes = 0
        io.afterWrite = { _, _ in
            writes += 1
            if writes == 1 { io.readsFail = true; io.writesFail = true }
        }
        settle { ducker.duck(completion: $0) }        // leaves an owed, unconfirmed element
        io.afterWrite = nil
        io.readsFail = false
        io.writesFail = false

        // The press fires from INSIDE the reclaim's write, which is the exact
        // interleaving a check-then-write cannot exclude.
        var pressed = false
        io.beforeWrite = { _, _ in
            guard !pressed else { return }
            pressed = true
            ducker.duck()
        }
        settle { ducker.restore(completion: $0) }
        io.beforeWrite = nil

        let settled = expectation(description: "the new hold settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertLessThan(io.levels[kAudioObjectPropertyElementMain]!, 0.8,
                          "the hold that won must still be ducking, not sitting at full volume")

        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5,
                       "…and the user's real level is what finally comes back")
    }

    // Per-channel device, one channel taken over by the user: ONLY that channel
    // is released. Surrendering the whole device would leave the other one parked
    // at a ducked level with nobody left who intends to restore it.
    func testSurrenderIsPerChannelNotPerDevice() {
        let io = FakeVolumeIO(elements: [1, 2], level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        var stolen = false
        io.afterWrite = { [weak io] element, _ in
            guard element == 1, !stolen else { return }
            stolen = true
            io?.levels[1] = 0.5                        // the user grabs the LEFT channel
        }
        settle { ducker.duck(completion: $0) }
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[1]!, 0.5, accuracy: 1e-5, "the channel the user took is theirs")
        XCTAssertEqual(io.levels[2]!, 0.8, accuracy: 1e-5, "the channel we still owned came back")
    }

    // A mute during a duck of an already-quiet device must read as a USER change.
    // With a flat tolerance it doesn't: ducking 0.10 lands near 0.015, and 0.0 is
    // within 0.02 of that — so the restore would put the user's sound back on.
    func testMutingAQuietDeviceIsRecognisedAsTheUsers() {
        XCTAssertFalse(OutputDucker.stillOurs(current: 0.0, applied: 0.015),
                       "a mute is never our own ducked level")
        // …while a device that quantises a normal level stays ours.
        XCTAssertTrue(OutputDucker.stillOurs(current: 0.7969, applied: 0.8))
    }

    // A press landing while the previous release is still fading back TAKES OVER
    // the duck, instead of letting the old restore raise the music during the new
    // hold — and the user's original level is still what the next restore lands on.
    func testANewPressTakesOverAFadingRestore() {
        let io = FakeVolumeIO(level: 0.8)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }
        let secondPress = expectation(description: "second duck settled")
        ducker.restore()                       // release…
        ducker.duck { secondPress.fulfill() }   // …and press again immediately
        wait(for: [secondPress], timeout: 5)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8 * 0.15, accuracy: 1e-4,
                       "the new hold ends ducked, not with the music back up")
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5,
                       "and the ORIGINAL level is what finally comes back")
    }

    // MARK: Devices that push back

    // A device with no settable volume is a no-op — never a mute, never a crash.
    func testDeviceWithoutVolumeControlIsANoOp() {
        let io = FakeVolumeIO(elements: [], level: 0.5)
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }
        XCTAssertFalse(ducker.isDucking)
        XCTAssertEqual(io.writeCount, 0)
    }

    // Per-channel devices (no master control) must keep their BALANCE. Averaging
    // left and right into one number and writing it back to both would silently
    // re-centre a balance the user set.
    func testPerChannelDeviceKeepsItsBalance() {
        let io = FakeVolumeIO(elements: [1, 2], level: 0.8)
        io.levels[2] = 0.4                       // right channel quieter on purpose
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }
        XCTAssertEqual(io.levels[1]!, 0.8 * 0.15, accuracy: 1e-5)
        XCTAssertEqual(io.levels[2]!, 0.4 * 0.15, accuracy: 1e-5)
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[1]!, 0.8, accuracy: 1e-5)
        XCTAssertEqual(io.levels[2]!, 0.4, accuracy: 1e-5, "the user's balance survives")
    }

    // A restore whose writes silently fail must NOT be reported as done: the
    // journal has to survive so the next release — and failing that, the next
    // launch — puts the volume back.
    func testUnverifiedRestoreKeepsTheRecoveryRecord() {
        let io = FakeVolumeIO(level: 0.8)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        io.writesFail = true
        settle { ducker.restore(completion: $0) }
        XCTAssertNotNil(defaults.dictionary(forKey: OutputDucker.orphanKey),
                        "an unverified restore must keep its recovery record")
        XCTAssertTrue(ducker.isDucking, "still on the hook to put the volume back")
        // …and the retry works once the device does.
        io.writesFail = false
        settle { ducker.restore(completion: $0) }
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.8, accuracy: 1e-5)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // MARK: Quit

    // Termination cannot wait for a fade, so restoreNow writes synchronously —
    // by the time it returns, the volume is back and the record is gone.
    func testRestoreNowIsSynchronousAndVerified() {
        let io = FakeVolumeIO(level: 0.75)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        XCTAssertTrue(ducker.restoreNow())
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.75, accuracy: 1e-5,
                       "the volume is back BEFORE the process can exit")
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    func testRestoreNowReportsFailureAndKeepsTheRecord() {
        let io = FakeVolumeIO(level: 0.75)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        io.writesFail = true
        XCTAssertFalse(ducker.restoreNow(), "an unverified quit-time restore says so")
        XCTAssertNotNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // MARK: Crash recovery

    // Killed mid-duck: the next launch finds the level exactly where we left it
    // and puts the original back.
    func testRestoreOrphanedRecoversAKilledRun() {
        let io = FakeVolumeIO(level: 0.9)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }     // …and now the app "dies"
        XCTAssertLessThan(io.levels[kAudioObjectPropertyElementMain]!, 0.2)

        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.9, accuracy: 1e-5)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // …but a level the USER chose after the crash is theirs. Recovery only ever
    // reverses a level still sitting where we left it.
    func testRestoreOrphanedLeavesAUserChosenLevelAlone() {
        let io = FakeVolumeIO(level: 0.9)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        io.levels[kAudioObjectPropertyElementMain] = 0.35   // user picks a quiet level

        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.35, accuracy: 1e-5,
                       "recovery must not overwrite a level the user chose")
    }

    // A device that is merely UNPLUGGED right now keeps its record: it still
    // carries our ducked level and will come back with it. Dropping the record
    // would be the one state from which the volume can never be recovered.
    func testRestoreOrphanedKeepsTheRecordForAnAbsentDevice() {
        let io = FakeVolumeIO(level: 0.9)
        let defaults = makeDefaults()
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        io.deviceMissing = true
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertNotNil(defaults.dictionary(forKey: OutputDucker.orphanKey))

        // …and when it comes back, the next launch puts the level back.
        io.deviceMissing = false
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.9, accuracy: 1e-5)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // A malformed record is dropped rather than retried forever.
    func testRestoreOrphanedDropsAMalformedRecord() {
        let defaults = makeDefaults()
        let io = FakeVolumeIO()
        defaults.set(["some-device": ["uid": "some-device"]], forKey: OutputDucker.orphanKey)
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // Two devices, one of them unplugged while still ducked: dictating through
    // the other must NOT overwrite the absent one's only route back to its level.
    func testASecondDeviceDoesNotOverwriteAnAbsentDevicesRecord() {
        let defaults = makeDefaults()
        let absent = OutputDucker.Journal(
            uid: "unplugged-dac",
            originals: [kAudioObjectPropertyElementMain: 0.9],
            applied: [kAudioObjectPropertyElementMain: 0.13])
        defaults.set(["unplugged-dac": absent.record], forKey: OutputDucker.orphanKey)

        let io = FakeVolumeIO(level: 0.5)          // a different output device
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }
        settle { ducker.restore(completion: $0) }

        let store = defaults.dictionary(forKey: OutputDucker.orphanKey)
        XCTAssertNotNil(store?["unplugged-dac"],
                        "the absent device's record must survive another device's dictation")
        XCTAssertNil(store?[io.deviceUID], "…while the device we finished with lets go of its own")
    }

    // Killed BETWEEN the write and its confirmation: the device sits at a level
    // that was only ever written-ahead, and recovery still recognises it as ours.
    func testRestoreOrphanedRecognisesAWrittenAheadLevel() {
        let defaults = makeDefaults()
        let io = FakeVolumeIO(level: 0.9)
        let journal = OutputDucker.Journal(
            uid: io.deviceUID,
            originals: [kAudioObjectPropertyElementMain: 0.9],
            applied: [kAudioObjectPropertyElementMain: 0.6],   // last confirmed
            pending: [kAudioObjectPropertyElementMain: 0.45])  // in flight when it died
        // Records are stored per device UID, so one unplugged device's record
        // cannot be overwritten by a duck on another output.
        defaults.set([io.deviceUID: journal.record], forKey: OutputDucker.orphanKey)
        io.levels[kAudioObjectPropertyElementMain] = 0.45      // the write did land

        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.9, accuracy: 1e-5,
                       "a level we wrote but never confirmed is still ours to put back")
    }

    func testRestoreOrphanedIsANoOpWithoutARecord() {
        let defaults = makeDefaults()
        let io = FakeVolumeIO()
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.writeCount, 0)
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // A recovery that could NOT put the level back must not then be ducked on
    // top of. Doing so would snapshot OLIV's own ducked scalar as the "original"
    // and overwrite the one record that still remembers the user's real volume —
    // losing it for good. The press goes un-ducked instead, and the true original
    // survives for the next attempt.
    func testAFailedRecoveryBlocksDuckingRatherThanLosingTheOriginal() {
        let defaults = makeDefaults()
        let io = FakeVolumeIO(level: 0.9)
        let ducker = OutputDucker(io: io, defaults: defaults)
        settle { ducker.duck(completion: $0) }          // 0.9 -> ~0.135
        let ducked = io.levels[kAudioObjectPropertyElementMain]!
        // The app "dies" here, and on the next run the device refuses writes.
        io.writesFail = true
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertNotNil(defaults.dictionary(forKey: OutputDucker.orphanKey),
                        "a failed recovery keeps its record")

        let second = OutputDucker(io: io, defaults: defaults)
        settle { second.duck(completion: $0) }
        XCTAssertFalse(second.isDucking, "must not duck a device whose real level is still lost")
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, ducked, accuracy: 1e-5)

        // …and once the device accepts writes again, the ORIGINAL comes back.
        io.writesFail = false
        OutputDucker.restoreOrphaned(defaults: defaults, io: io)
        XCTAssertEqual(io.levels[kAudioObjectPropertyElementMain]!, 0.9, accuracy: 1e-5,
                       "the user's real level survived the whole sequence")
        XCTAssertNil(defaults.dictionary(forKey: OutputDucker.orphanKey))
    }

    // A device that will not report its level is left strictly alone: we cannot
    // tell whose level it is, and guessing is how a user's choice gets taken.
    func testUnreadableDeviceIsNeverWritten() {
        let io = FakeVolumeIO(level: 0.8)
        io.readsFail = true
        let ducker = OutputDucker(io: io, defaults: makeDefaults())
        settle { ducker.duck(completion: $0) }
        XCTAssertEqual(io.writeCount, 0)
        XCTAssertFalse(ducker.isDucking)
    }

    // MARK: Pure seams

    func testDuckedVolumeScalesTheUserLevel() {
        XCTAssertEqual(OutputDucker.duckedVolume(original: 0.8, level: 0.25), 0.2, accuracy: 1e-6)
        XCTAssertEqual(OutputDucker.duckedVolume(original: 0, level: 0.15), 0, accuracy: 1e-6)
    }

    // Out-of-range levels are clamped: level 0 would MUTE the user's speakers,
    // level > 1 would raise them mid-dictation.
    func testDuckedVolumeClampsTheLevel() {
        XCTAssertGreaterThan(OutputDucker.duckedVolume(original: 1, level: 0), 0)
        XCTAssertLessThanOrEqual(OutputDucker.duckedVolume(original: 1, level: 5), 1)
    }

    // Ownership is judged against what we APPLIED, never against where a fade was
    // headed — the distinction the mid-fade release bug turned on.
    func testOwnershipComparesAgainstWhatWasApplied() {
        XCTAssertTrue(OutputDucker.stillOurs(current: 0.687, applied: 0.687))
        XCTAssertTrue(OutputDucker.stillOurs(current: 0.70, applied: 0.687))
        XCTAssertFalse(OutputDucker.stillOurs(current: 0.45, applied: 0.687))
    }

    // The fade lands EXACTLY on its destination; a ramp that stops short leaves
    // the user's volume wrong forever.
    func testRampLandsExactlyOnTarget() {
        let down = OutputDucker.rampLevels(from: 0.8, to: 0.12, steps: 6)
        XCTAssertEqual(down.count, 6)
        XCTAssertEqual(down.last!, 0.12, accuracy: 1e-6)
        XCTAssertEqual(down, down.sorted(by: >), "monotonic — no blip louder than the original")
        XCTAssertEqual(OutputDucker.rampLevels(from: 0.8, to: 0.1, steps: 1), [0.1])
        XCTAssertEqual(OutputDucker.rampLevels(from: 0.8, to: 0.1, steps: 0), [0.1])
    }

    // The journal must survive the round trip through UserDefaults, per element —
    // it is what a killed run leaves behind for the next launch.
    func testJournalRoundTrips() {
        let journal = OutputDucker.Journal(
            uid: "abc", originals: [1: 0.8, 2: 0.4], applied: [1: 0.12, 2: 0.06])
        let decoded = OutputDucker.Journal(record: journal.record)
        XCTAssertEqual(decoded?.uid, "abc")
        XCTAssertEqual(decoded?.originals[1] ?? 0, 0.8, accuracy: 1e-6)
        XCTAssertEqual(decoded?.applied[2] ?? 0, 0.06, accuracy: 1e-6)
        XCTAssertNil(OutputDucker.Journal(record: ["uid": "abc"]), "a partial record is not a journal")
    }
}
