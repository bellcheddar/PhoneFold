import Testing
import Foundation
@testable import FoldAudio

/// The musical primitives everything else in the score is built from.
@Suite("Musical scale")
struct MusicalScaleTests {

    @Test("A scale degree lands where a musician would expect")
    func degreesAreCorrect() {
        // A minor: A, B, C, D, E, F, G. MIDI 57 is A3.
        let aMinor = MusicalScale(root: 57, mode: .minor)
        #expect(aMinor.pitch(degree: 0) == 57)   // A
        #expect(aMinor.pitch(degree: 1) == 59)   // B
        #expect(aMinor.pitch(degree: 2) == 60)   // C
        #expect(aMinor.pitch(degree: 4) == 64)   // E
        #expect(aMinor.pitch(degree: 7) == 69)   // A, an octave up
        // C major: C, D, E, F, G, A, B.
        let cMajor = MusicalScale(root: 60, mode: .major)
        #expect(cMajor.pitch(degree: 3) == 65)   // F
        #expect(cMajor.pitch(degree: 6) == 71)   // B
        // Dorian differs from minor in exactly one note, the sixth.
        let dDorian = MusicalScale(root: 62, mode: .dorian)
        let dMinor = MusicalScale(root: 62, mode: .minor)
        #expect(dDorian.pitch(degree: 5) == dMinor.pitch(degree: 5) + 1)
        for degree in [0, 1, 2, 3, 4, 6] {
            #expect(dDorian.pitch(degree: degree) == dMinor.pitch(degree: degree))
        }
    }

    /// Negative degrees are not an edge case here: register is driven by the trajectory, and a
    /// long-range contact asks for a note well below the tonic.
    @Test("Degrees below the tonic descend rather than clamping")
    func negativeDegreesDescend() {
        let aMinor = MusicalScale(root: 57, mode: .minor)
        #expect(aMinor.pitch(degree: -1) == 55)   // G below A
        #expect(aMinor.pitch(degree: -7) == 45)   // A, an octave below
        #expect(aMinor.pitch(degree: -8) == 43)   // G below that
        // Strictly descending, all the way down.
        var previous = 128
        for degree in stride(from: 0, through: -20, by: -1) {
            let pitch = Int(aMinor.pitch(degree: degree))
            #expect(pitch < previous, "degree \(degree) did not descend")
            previous = pitch
        }
    }

    @Test("Pitches stay inside MIDI's range however far a degree runs")
    func pitchesStayInRange() {
        let scale = MusicalScale(root: 57, mode: .minor)
        for degree in stride(from: -200, through: 200, by: 7) {
            let pitch = scale.pitch(degree: degree)
            #expect(pitch <= 127)
        }
    }

    @Test("Aeolian and natural minor are the same scale under two names")
    func aeolianIsNaturalMinor() {
        #expect(MusicalMode.aeolian.intervals == MusicalMode.minor.intervals)
    }

    @Test("Snapping moves a chromatic pitch into the key, never out of it")
    func snapLandsInTheScale() {
        let scale = MusicalScale(root: 60, mode: .major)   // C major, no sharps
        // C# snaps down to C; F# snaps down to F.
        #expect(scale.snap(61) == 60)
        #expect(scale.snap(66) == 65)
        // A note already in the key is unchanged.
        for degree in 0..<7 {
            let inKey = scale.pitch(degree: degree)
            #expect(scale.snap(inKey) == inKey)
        }
    }

    @Test("A note's frequency is concert pitch")
    func frequencyIsConcertPitch() {
        #expect(abs(MIDINote(pitch: 69, velocity: 100).frequency - 440) < 1e-9)
        #expect(abs(MIDINote(pitch: 57, velocity: 100).frequency - 220) < 1e-9)
        // Velocity is clamped into 1...127: zero would mean note-off, which this is not.
        #expect(MIDINote(pitch: 60, velocity: 0).velocity == 1)
        #expect(MIDINote(pitch: 200, velocity: 200).pitch == 127)
    }
}

/// The property PLAN.md is most explicit about: the same protein always yields the same piece.
@Suite("Sequence seed")
struct SequenceSeedTests {

    /// **The reason this is not `Hasher`.** Swift's standard hashing is randomly seeded per
    /// process by design, so a piece built on it would differ every launch. This test would
    /// pass within one run and fail across two, which is the worst kind of green.
    @Test("The same sequence always gives the same seed")
    func seedIsStable() {
        let ubiquitin = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"
        // Literals computed independently, from FNV-1a's published definition rather than
        // from this implementation. The first version of this test wrote
        // `x == literal || x == x`, which cannot fail - the tautology it was warning about in
        // its own comment. A stability test that compares a value against itself pins nothing.
        #expect(SequenceSeed(sequence: ubiquitin).value == 0xb3569d42cb3c6d78)
        #expect(SequenceSeed(sequence: "ACDEF").value == 0x973701502298f994)
        #expect(SequenceSeed(sequence: ubiquitin) == SequenceSeed(sequence: ubiquitin))
        // Case cannot change the music: a sequence is a sequence however it was typed.
        #expect(SequenceSeed(sequence: "acdef") == SequenceSeed(sequence: "ACDEF"))
    }

    @Test("Different proteins give different seeds")
    func differentSequencesDiffer() {
        let seeds = Set(["MQIFVKTL", "MQIFVKTM", "ACDEFGHIK", "A", ""]
            .map { SequenceSeed(sequence: $0).value })
        #expect(seeds.count == 5, "two different sequences collided")
        // An empty sequence must still seed something usable.
        #expect(SequenceSeed(sequence: "").value != 0)
    }

    @Test("The generator is deterministic and reasonably distributed")
    func generatorIsDeterministic() {
        let seed = SequenceSeed(sequence: "MQIFVKTLTGKTITLEVE")
        var a = seed.generator(), b = seed.generator()
        for _ in 0..<1000 { #expect(a.next() == b.next()) }

        var rng = seed.generator()
        var values: [Double] = []
        for _ in 0..<20_000 { values.append(rng.uniform()) }
        let mean = values.reduce(0, +) / Double(values.count)
        #expect(abs(mean - 0.5) < 0.01, "uniform mean is \(mean)")
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })

        // `pick` must cover its options rather than favouring one.
        var picker = seed.generator()
        var counts = [String: Int]()
        for _ in 0..<6000 { counts[picker.pick(["a", "b", "c"])!, default: 0] += 1 }
        #expect(counts.count == 3)
        for count in counts.values { #expect(count > 1500 && count < 2500, "skewed: \(counts)") }
        #expect(picker.pick([Int]()) == nil)
    }
}
