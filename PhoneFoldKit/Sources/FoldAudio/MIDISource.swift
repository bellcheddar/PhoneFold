import Foundation
import CoreMIDI
import Synchronization

/// A virtual CoreMIDI source, so a DAW can record the fold as it happens.
///
/// PLAN.md Phase 5a: "CoreMIDI virtual source: PhoneFold Studio appears as a MIDI device so
/// Logic, Ableton or any DAW can record the fold live. Marc can then actually produce a track
/// from a protein. Nothing in this space does this."
///
/// **The channel map is `MIDIFile`'s, not a second one.** A live take that put the pad on a
/// different channel from the exported `.mid` would be the worst kind of wrong: both files look
/// right on their own, and they only disagree once someone lines them up in a DAW hours later.
/// One mapping, used by the file writer and by this.
///
/// **Not `Sendable`-by-actor, because CoreMIDI is not async.** `MIDIReceived` is a synchronous
/// C call that is safe to make from any thread, and the notes arrive from the audio render
/// path, which must never wait on an actor. State here is a `Mutex` around the handful of
/// integers CoreMIDI hands back.
public final class MIDISource: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case couldNotCreateClient(OSStatus)
        case couldNotCreateSource(OSStatus)

        public var description: String {
            switch self {
            case .couldNotCreateClient(let status):
                "CoreMIDI would not create a client (OSStatus \(status))"
            case .couldNotCreateSource(let status):
                "CoreMIDI would not create the virtual source (OSStatus \(status))"
            }
        }
    }

    private struct Handles {
        var client = MIDIClientRef()
        var source = MIDIEndpointRef()
        /// Pitches currently sounding, per channel, so everything can be silenced on stop.
        var sounding: Set<Int> = []
    }

    private let handles = Mutex(Handles())
    public let name: String

    /// Create the virtual source. It appears to other applications immediately.
    ///
    /// **No retry, and that is a correction.** This briefly had a four-attempt retry loop,
    /// added because the CoreMIDI tests failed inside the full test suite with OSStatus -2 and
    /// the cause was guessed at as a transient MIDIServer refusal under machine load. That was
    /// wrong: the same failure reproduced on an idle machine, and the full suite run serially
    /// passes all 535 tests. The failure is an artefact of 86 suites executing concurrently in
    /// one process, not something a user or this code can provoke - measured separately, a
    /// quiet process makes 80 clients, 40 virtual sources, and 200 create-and-dispose cycles
    /// without one failure, and saturating the cooperative thread pool does not break it
    /// either. A retry defending against a condition that does not exist is cargo.
    public init(name: String = "PhoneFold") throws {
        self.name = name
        var client = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock(name as CFString, &client) { _ in }
        guard clientStatus == noErr else { throw Failure.couldNotCreateClient(clientStatus) }

        var source = MIDIEndpointRef()
        let sourceStatus = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard sourceStatus == noErr else {
            MIDIClientDispose(client)
            throw Failure.couldNotCreateSource(sourceStatus)
        }
        handles.withLock {
            $0.client = client
            $0.source = source
        }
    }

    deinit {
        handles.withLock {
            if $0.source != 0 { MIDIEndpointDispose($0.source) }
            if $0.client != 0 { MIDIClientDispose($0.client) }
        }
    }

    /// The endpoint, for a test or a UI that wants to name it.
    public var endpoint: MIDIEndpointRef { handles.withLock { $0.source } }

    // MARK: - Sending

    /// Send one three-byte channel message immediately.
    ///
    /// Immediately rather than scheduled: the caller is the musical clock, which already knows
    /// when a note should sound, and giving CoreMIDI a second opinion about timing would put
    /// two schedulers in series.
    public func send(status: UInt8, channel: UInt8, _ data1: UInt8, _ data2: UInt8) {
        // Positional: the CoreMIDI helper is a C inline function, so it imports unlabelled.
        let word = MIDI1UPChannelVoiceMessage(0, status >> 4, channel & 0x0F,
                                              data1 & 0x7F, data2 & 0x7F)
        var packetList = MIDIEventList()
        var packet = MIDIEventListInit(&packetList, ._1_0)
        packet = MIDIEventListAdd(&packetList, MemoryLayout<MIDIEventList>.size, packet,
                                  0, 1, [word])
        handles.withLock { handles in
            guard handles.source != 0 else { return }
            MIDIReceivedEventList(handles.source, &packetList)
            let key = Int(channel & 0x0F) << 8 | Int(data1 & 0x7F)
            if status == 0x90 && data2 > 0 {
                handles.sounding.insert(key)
            } else {
                handles.sounding.remove(key)
            }
        }
    }

    public func noteOn(channel: UInt8, pitch: UInt8, velocity: UInt8) {
        send(status: 0x90, channel: channel, pitch, velocity)
    }

    public func noteOff(channel: UInt8, pitch: UInt8) {
        send(status: 0x80, channel: channel, pitch, 0x40)
    }

    /// Send a scheduled note, and its note-off after the note's own duration.
    ///
    /// The off is a detached sleep rather than a queue, because the alternative is a second
    /// timing structure alongside `MusicalClock` and this one only has to be approximately
    /// right: a DAW records the gate length it is given, and a few milliseconds of drift on a
    /// note-off is inaudible where the same drift on a note-on would not be.
    public func play(_ scheduled: ScheduledNote) {
        let channel = MIDIFile.channel(for: scheduled.note.voice, part: scheduled.note.part)
        let pitch = scheduled.note.note.pitch
        noteOn(channel: channel, pitch: pitch, velocity: scheduled.note.note.velocity)
        let seconds = scheduled.duration
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.noteOff(channel: channel, pitch: pitch)
        }
    }

    /// Silence everything currently sounding.
    ///
    /// **Every note individually, not an all-notes-off controller.** CC 123 is widely
    /// implemented and not universally, and a stuck note in a DAW take is something the user
    /// finds much later while editing. Tracking what is sounding costs a set.
    public func allNotesOff() {
        let stuck = handles.withLock { handles -> [Int] in
            let sounding = Array(handles.sounding)
            handles.sounding.removeAll()
            return sounding
        }
        for key in stuck {
            send(status: 0x80, channel: UInt8(key >> 8), UInt8(key & 0xFF), 0x40)
        }
    }

    /// How many notes are sounding, for a test or a diagnostic.
    public var soundingCount: Int { handles.withLock { $0.sounding.count } }
}
