import Testing
import Foundation
import CoreMIDI
import Synchronization
@testable import FoldAudio

/// PLAN.md Phase 5a's machine gate: "the CoreMIDI source appears and emits valid events to a
/// loopback client."
///
/// These tests are the loopback client. They create a real CoreMIDI input port, connect it to
/// PhoneFold's virtual source, and read back the bytes that actually crossed CoreMIDI - not the
/// bytes the sender believes it wrote. A test that only asserted what `send` was called with
/// would pass with the endpoint disposed.
@Suite("The virtual MIDI source, read back through CoreMIDI", .serialized)
struct MIDISourceTests {

    /// A CoreMIDI client that listens to one source and records what arrives.
    final class Loopback: Sendable {
        struct Message: Sendable, Hashable {
            let status: UInt8
            let channel: UInt8
            let data1: UInt8
            let data2: UInt8
        }

        private let received = Mutex<[Message]>([])
        private let client = Mutex(MIDIClientRef())
        private let port = Mutex(MIDIPortRef())

        init(connectingTo source: MIDIEndpointRef) throws {
            var clientRef = MIDIClientRef()
            try check(MIDIClientCreateWithBlock("PhoneFoldTestClient" as CFString,
                                                &clientRef) { _ in })
            var portRef = MIDIPortRef()
            try check(MIDIInputPortCreateWithProtocol(
                clientRef, "in" as CFString, ._1_0, &portRef) { [self] eventList, _ in
                    var packet = UnsafeMutablePointer(mutating:
                        withUnsafePointer(to: eventList.pointee.packet) { $0 })
                    for _ in 0..<eventList.pointee.numPackets {
                        let words = withUnsafeBytes(of: packet.pointee.words) { raw in
                            Array(raw.bindMemory(to: UInt32.self)
                                .prefix(Int(packet.pointee.wordCount)))
                        }
                        for word in words {
                            // A MIDI 1.0 channel-voice message in a Universal MIDI Packet:
                            // 0x2 message type, then status, channel, and two data bytes.
                            let status = UInt8((word >> 20) & 0x0F)
                            guard status != 0 else { continue }
                            received.withLock {
                                $0.append(Message(status: status << 4,
                                                  channel: UInt8((word >> 16) & 0x0F),
                                                  data1: UInt8((word >> 8) & 0x7F),
                                                  data2: UInt8(word & 0x7F)))
                            }
                        }
                        packet = MIDIEventPacketNext(packet)
                    }
                })
            try check(MIDIPortConnectSource(portRef, source, nil))
            client.withLock { $0 = clientRef }
            port.withLock { $0 = portRef }
        }

        deinit {
            let portRef = port.withLock { $0 }
            let clientRef = client.withLock { $0 }
            if portRef != 0 { MIDIPortDispose(portRef) }
            if clientRef != 0 { MIDIClientDispose(clientRef) }
        }

        var messages: [Message] { received.withLock { $0 } }

        /// CoreMIDI delivers on its own thread, so give it a moment before asserting.
        func settle() async {
            try? await Task.sleep(for: .milliseconds(250))
        }

        private func check(_ status: OSStatus) throws {
            struct CoreMIDIFailure: Error { let status: OSStatus }
            guard status == noErr else { throw CoreMIDIFailure(status: status) }
        }
    }

    @Test("The source appears to CoreMIDI as a real endpoint")
    func sourceAppears() throws {
        let source = try MIDISource(name: "PhoneFoldTest")
        #expect(source.endpoint != 0)

        // Findable by name from outside, which is what a DAW does.
        var found = false
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr,
               (name?.takeRetainedValue() as String?) == "PhoneFoldTest" {
                found = true
            }
        }
        #expect(found, "a DAW finds the source by name, so the test does too")
    }

    /// The gate's own sentence: valid events reaching a loopback client.
    @Test("A note on and a note off cross CoreMIDI intact")
    func notesArrive() async throws {
        let source = try MIDISource(name: "PhoneFoldTestNotes")
        let loopback = try Loopback(connectingTo: source.endpoint)
        await loopback.settle()

        source.noteOn(channel: 2, pitch: 64, velocity: 100)
        source.noteOff(channel: 2, pitch: 64)
        await loopback.settle()

        let messages = loopback.messages
        #expect(messages.count >= 2, "got \(messages)")
        let on = try #require(messages.first { $0.status == 0x90 })
        #expect(on.channel == 2)
        #expect(on.data1 == 64)
        #expect(on.data2 == 100)
        let off = try #require(messages.first { $0.status == 0x80 })
        #expect(off.channel == 2)
        #expect(off.data1 == 64)
    }

    /// The reason this shares `MIDIFile.channel(for:part:)` rather than having its own map: a
    /// live take and the exported file have to line up in the DAW, and nothing would catch it
    /// if they did not.
    @Test("A scheduled note uses the same channel the file export would")
    func channelMatchesTheFileExport() async throws {
        let source = try MIDISource(name: "PhoneFoldTestChannel")
        let loopback = try Loopback(connectingTo: source.endpoint)
        await loopback.settle()

        let event = NoteEvent(voice: .pad, note: MIDINote(pitch: 60, velocity: 90),
                              residue: 0, partner: nil, beatOffset: 0, duration: 1,
                              part: .mutant)
        source.play(ScheduledNote(note: event, time: 0, duration: 0.05,
                                  timbre: TimbreState(cutoff: 8000, detuneCents: 0, reverb: 0)))
        await loopback.settle()

        let expected = MIDIFile.channel(for: .pad, part: .mutant)
        let on = try #require(loopback.messages.first { $0.status == 0x90 })
        #expect(on.channel == expected)
        #expect(on.data1 == 60)
    }

    /// A stuck note is found much later, while editing, which is the worst time to find it.
    @Test("allNotesOff silences everything that was sounding")
    func noStuckNotes() async throws {
        let source = try MIDISource(name: "PhoneFoldTestStuck")
        let loopback = try Loopback(connectingTo: source.endpoint)
        await loopback.settle()

        source.noteOn(channel: 0, pitch: 60, velocity: 90)
        source.noteOn(channel: 1, pitch: 67, velocity: 90)
        source.noteOn(channel: 1, pitch: 72, velocity: 90)
        #expect(source.soundingCount == 3)

        source.allNotesOff()
        await loopback.settle()
        #expect(source.soundingCount == 0)

        let offs = loopback.messages.filter { $0.status == 0x80 }
        #expect(offs.count == 3, "one note-off per sounding note, not a CC 123 nobody implements")
        #expect(Set(offs.map(\.data1)) == [60, 67, 72])
    }

    @Test("A velocity-zero note on is treated as a note off")
    func velocityZeroIsAnOff() throws {
        let source = try MIDISource(name: "PhoneFoldTestZero")
        source.noteOn(channel: 0, pitch: 60, velocity: 90)
        #expect(source.soundingCount == 1)
        source.noteOn(channel: 0, pitch: 60, velocity: 0)
        #expect(source.soundingCount == 0, "running-status style note off still clears the note")
    }
}
