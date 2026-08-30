import Testing
import Foundation
@testable import FoldAudio
import FoldCore

/// What the fold feels like. The mapping is asserted here; playing it is CoreHaptics' problem
/// and needs hardware this test does not have.
@Suite("Haptics")
struct HapticScoreTests {

    static func contact(beat: Double, residue: Int, partner: Int, velocity: UInt8 = 100,
                        voice: Voice = .contact) -> NoteEvent {
        NoteEvent(voice: voice, note: MIDINote(pitch: 60, velocity: velocity),
                  residue: residue, partner: partner, beatOffset: beat, duration: 1)
    }

    static func moment(notes: [NoteEvent] = [], compaction: Double = 0,
                       isCadence: Bool = false, beats: Double = 1) -> ScoreMoment {
        ScoreMoment(frameIndex: 0, tempo: 120, notes: notes,
                    timbre: Sonifier.timbre(meanConfidence: 80), degree: 0,
                    isCadence: isCadence, isModulation: false, compaction: compaction,
                    droppedContacts: 0, beats: beats)
    }

    @Test("a contact is a tap, and a long-range one is a sharper tap")
    func contactsAreTaps() {
        let events = HapticScore.events(for: Self.moment(notes: [
            Self.contact(beat: 0, residue: 0, partner: 4),     // local
            Self.contact(beat: 0.25, residue: 0, partner: 9),  // medium
            Self.contact(beat: 0.5, residue: 0, partner: 40),  // long-range
        ]))
        let taps = events.filter { $0.kind == .transient }
        #expect(taps.count == 3)
        // PLAN.md: "transient on contact formation, sharper for long-range". Two parts of the
        // chain that were far apart meeting should not feel like a helix turn closing.
        #expect(taps[0].sharpness < taps[1].sharpness)
        #expect(taps[1].sharpness < taps[2].sharpness)
        // And they land with their notes, not on the downbeat.
        #expect(taps.map(\.beatOffset) == [0, 0.25, 0.5])
    }

    @Test("core packing is felt hardest")
    func corePackingIsStrongest() {
        let events = HapticScore.events(for: Self.moment(notes: [
            Self.contact(beat: 0, residue: 0, partner: 40, velocity: 100),
            Self.contact(beat: 0.25, residue: 1, partner: 41, velocity: 100, voice: .bass),
        ]))
        let taps = events.filter { $0.kind == .transient }
        #expect(taps.count == 2)
        // The bass voice is a long-range hydrophobic contact: the core forming, and the one
        // event in the whole piece most worth feeling.
        #expect(taps[1].intensity > taps[0].intensity)
        #expect(taps.allSatisfy { $0.intensity <= 1 })
    }

    @Test("a burst is capped, because sixteen taps in a beat is a buzz")
    func tapsAreCapped() {
        let crowd = (0..<16).map {
            Self.contact(beat: Double($0) * 0.25, residue: $0, partner: $0 + 20)
        }
        let taps = HapticScore.events(for: Self.moment(notes: crowd))
            .filter { $0.kind == .transient }
        #expect(taps.count == HapticScore.maximumTaps)
    }

    @Test("a barely audible contact is not felt at all")
    func quietContactsAreNotFelt() {
        // Velocity 30 is the floor the confidence mapping uses for a completely unresolved
        // residue. Felt, it would be noise under the taps that matter.
        let events = HapticScore.events(for: Self.moment(notes: [
            Self.contact(beat: 0, residue: 0, partner: 20, velocity: 15),
        ]))
        #expect(!events.contains { $0.kind == .transient })
    }

    @Test("the rumble grows with the core and is silent before it exists")
    func rumbleTracksPacking() {
        // An unfolded chain that buzzed continuously would be a constant, not a signal.
        #expect(!HapticScore.events(for: Self.moment(compaction: 0.0))
            .contains { $0.kind == .rumble })
        #expect(!HapticScore.events(for: Self.moment(compaction: 0.3))
            .contains { $0.kind == .rumble })

        let middle = HapticScore.events(for: Self.moment(compaction: 0.6))
            .first { $0.kind == .rumble }
        let full = HapticScore.events(for: Self.moment(compaction: 1.0))
            .first { $0.kind == .rumble }
        #expect(middle != nil)
        #expect(full != nil)
        #expect(full!.intensity > middle!.intensity)
        // It runs the whole moment, so successive bars join into one sensation that tightens
        // rather than a string of separate buzzes.
        #expect(full!.duration == 1)
        #expect(full!.sharpness < 0.2, "a rumble is low, not crisp")
    }

    @Test("convergence has its own shape")
    func convergenceIsDistinct() {
        let events = HapticScore.events(for: Self.moment(
            notes: [Self.contact(beat: 0, residue: 0, partner: 30)],
            compaction: 0.9, isCadence: true))
        let cadence = events.filter { $0.kind == .convergence }
        #expect(cadence.count == 1)
        // Long and soft, so it cannot be mistaken for another contact however many are landing
        // around it.
        #expect(cadence[0].duration >= 2)
        #expect(cadence[0].sharpness < 0.3)
        #expect(cadence[0].intensity > 0.5)
        // And only on the frame it happens.
        #expect(!HapticScore.events(for: Self.moment(compaction: 0.9))
            .contains { $0.kind == .convergence })
    }

    @Test("events come out in the order they will be played")
    func eventsAreInOrder() {
        let events = HapticScore.events(for: Self.moment(notes: [
            Self.contact(beat: 0.75, residue: 0, partner: 30),
            Self.contact(beat: 0.25, residue: 1, partner: 31),
            Self.contact(beat: 0.5, residue: 2, partner: 32),
        ], compaction: 0.8, isCadence: true))
        for (a, b) in zip(events, events.dropFirst()) {
            #expect(a.beatOffset <= b.beatOffset)
        }
    }

    @Test("a quiet fold asks for nothing")
    func nothingHappeningFeelsLikeNothing() {
        #expect(HapticScore.events(for: Self.moment()).isEmpty)
    }

    @Test("the engine says it cannot buzz rather than pretending it can")
    func hardwareIsAskedNotAssumed() {
        // CoreHaptics imports on a Mac and in a simulator, neither of which has an actuator,
        // so the header being there proves nothing. This runs on a Mac: it must report no
        // hardware and count what it could not play, rather than throwing on the first event.
        let haptics = FoldHaptics()
        haptics.start()
        #expect(haptics.availability == .noHardware || haptics.availability.isReady)
        if !haptics.availability.isReady {
            haptics.play(HapticScore.events(for: Self.moment(compaction: 0.9)),
                         beatDuration: 0.5)
            #expect(haptics.skipped > 0, "a silent run should be a number, not an absence")
        }
        haptics.stop()
    }
}
