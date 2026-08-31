import Testing
import Foundation
@testable import FoldAudio
import FoldCore

/// Two folds played together, and what makes them sound like disagreement.
@Suite("Mutation duet")
struct MutationDuetTests {

    static func moment(_ index: Int, pitches: [UInt8], residues: [Int]) -> ScoreMoment {
        let notes = zip(pitches, residues).enumerated().map { offset, pair in
            NoteEvent(voice: .contact, note: MIDINote(pitch: pair.0, velocity: 90),
                      residue: pair.1, beatOffset: Double(offset) * 0.25, duration: 1)
        }
        return ScoreMoment(frameIndex: index, tempo: 100, notes: notes,
                           timbre: Sonifier.timbre(meanConfidence: 80), degree: 0,
                           isCadence: false, isModulation: false, compaction: 0.5,
                           droppedContacts: 0)
    }

    // MARK: - The interval

    @Test("agreement is unison and disagreement is a tritone")
    func intervalFollowsDivergence() {
        // The ladder runs from the most consonant interval to the least, so a fold the two
        // agree about is sung in unison and one they do not is a tritone.
        #expect(MutationDuet.interval(divergence: 0) == 0)
        #expect(MutationDuet.interval(divergence: 1) == 6, "full divergence is a tritone")
        // And it is monotone in consonance, not in semitones: an octave is more consonant than
        // a major second even though it is further away in pitch.
        let ladder = MutationDuet.consonanceLadder
        #expect(ladder.first == 0)
        #expect(ladder.last == 6)
        #expect(ladder.contains(7), "the fifth has to be in there")
        #expect(Set(ladder).count == ladder.count, "an interval appears twice")
    }

    @Test("divergence is measured in confidence points, and saturates")
    func divergenceIsBounded() {
        #expect(MutationDuet.divergence(90, 90) == 0)
        #expect(MutationDuet.divergence(90, 60) == 1, "thirty points is full divergence")
        #expect(MutationDuet.divergence(90, 10) == 1, "and it does not go further")
        // Sign does not matter: a mutation that raises confidence is as much a difference as
        // one that lowers it.
        #expect(MutationDuet.divergence(60, 90) == MutationDuet.divergence(90, 60))
        #expect(MutationDuet.divergence(.nan, 50) == 0)
    }

    // MARK: - The merge

    @Test("both folds are heard, and each note says which one it is")
    func bothPartsArePresent() {
        let wild = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60, 64], residues: [0, 1])],
            confidence: [[90, 90]])
        let mutant = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60, 64], residues: [0, 1])],
            confidence: [[90, 90]])
        let merged = MutationDuet.merge(wildType: wild, mutant: mutant)
        #expect(merged.count == 1)
        let notes = merged[0].notes
        #expect(notes.count == 4)
        #expect(notes.filter { $0.part == .wildType }.count == 2)
        #expect(notes.filter { $0.part == .mutant }.count == 2)
        // Agreeing everywhere, the mutant sings the wild type's notes.
        let wildPitches = notes.filter { $0.part == .wildType }.map(\.note.pitch).sorted()
        let mutantPitches = notes.filter { $0.part == .mutant }.map(\.note.pitch).sorted()
        #expect(wildPitches == mutantPitches)
    }

    @Test("where the folds disagree, the mutant is displaced")
    func disagreementDisplacesTheMutant() {
        // Residue 0 agrees, residue 1 does not.
        let wild = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60, 64], residues: [0, 1])],
            confidence: [[90, 90]])
        let mutant = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60, 64], residues: [0, 1])],
            confidence: [[90, 50]])
        let notes = MutationDuet.merge(wildType: wild, mutant: mutant)[0].notes

        let agreeing = notes.first { $0.part == .mutant && $0.residue == 0 }
        let disagreeing = notes.first { $0.part == .mutant && $0.residue == 1 }
        let agreeingPitch = Int(agreeing?.note.pitch ?? 0)
        let disagreeingPitch = Int(disagreeing?.note.pitch ?? 0)
        #expect(agreeingPitch == 60, "an agreeing residue is in unison")
        // Forty points apart is beyond full divergence: a tritone.
        #expect(disagreeingPitch == 70, "\(disagreeingPitch) against an expected 70")
    }

    @Test("a duet is truncated to the shorter part rather than half-empty")
    func mismatchedLengthsAreTruncated() {
        let wild = MutationDuet.Part(
            moments: (0..<5).map { Self.moment($0, pitches: [60], residues: [0]) },
            confidence: Array(repeating: [90], count: 5))
        let mutant = MutationDuet.Part(
            moments: (0..<2).map { Self.moment($0, pitches: [60], residues: [0]) },
            confidence: Array(repeating: [90], count: 2))
        let merged = MutationDuet.merge(wildType: wild, mutant: mutant)
        // A duet whose second half is a solo is not a duet, and should be visibly shorter
        // rather than quietly one-sided.
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.notes.contains { $0.part == .mutant } })
    }

    @Test("the wild type keeps the harmony")
    func wildTypeSetsTheKey() {
        var wildMoment = Self.moment(0, pitches: [60], residues: [0])
        wildMoment = ScoreMoment(frameIndex: 0, tempo: 100, notes: wildMoment.notes,
                                 timbre: wildMoment.timbre, degree: 3, isCadence: true,
                                 isModulation: false, compaction: 0.9, droppedContacts: 0)
        let wild = MutationDuet.Part(moments: [wildMoment], confidence: [[90]])
        let mutant = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60], residues: [0])], confidence: [[40]])
        let merged = MutationDuet.merge(wildType: wild, mutant: mutant)[0]
        // The reference decides the tonality: a duet whose key was set by the thing under test
        // would be reading the answer off the experiment.
        #expect(merged.degree == 3)
        #expect(merged.isCadence)
        #expect(merged.compaction == 0.9)
    }

    @Test("the readout names where the folds diverge, with the sign kept")
    func divergentResiduesAreReported() {
        let wild = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60], residues: [0])],
            confidence: [[90, 90, 90, 40]])
        let mutant = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60], residues: [0])],
            confidence: [[90, 55, 88, 90]])
        let divergent = MutationDuet.divergentResidues(wildType: wild, mutant: mutant, limit: 2)
        #expect(divergent.count == 2)
        // What an engineer wants is not "it sounded wrong" but where.
        #expect(divergent[0].residue == 1 || divergent[0].residue == 3)
        // The sign is kept: a mutation that *raises* confidence somewhere is as interesting as
        // one that lowers it, and reporting only the drops would hide it.
        #expect(divergent.contains { $0.delta < 0 })
        #expect(divergent.contains { $0.delta > 0 })
    }

    @Test("a duet puts its two folds on different MIDI channels")
    func partsGetTheirOwnChannels() throws {
        let style = try SonifierTests.style
        let wild = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [60], residues: [0])], confidence: [[90]])
        let mutant = MutationDuet.Part(
            moments: [Self.moment(0, pitches: [67], residues: [0])], confidence: [[50]])
        let merged = MutationDuet.merge(wildType: wild, mutant: mutant)
        let parsed = try MIDIFile.decode(MIDIFile.encode(merged, style: style))
        #expect(parsed.notes.count == 2)
        #expect(Set(parsed.notes.map(\.channel)).count == 2, "both folds are on one channel")
        // Nothing on channel 9, which General MIDI plays as percussion whatever the note says.
        #expect(!parsed.notes.contains { $0.channel == 9 })
        // And the tracks are labelled, so a DAW shows two proteins rather than five mixtures.
        #expect(parsed.trackNames.contains { $0.contains("wildType") })
        #expect(parsed.trackNames.contains { $0.contains("mutant") })
    }
}
