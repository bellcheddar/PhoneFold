import Testing
import Foundation
import simd
@testable import FoldAudio
import FoldCore

/// The sonification mapping: PLAN.md's core table, row by row.
///
/// `#require` wraps its argument in a closure, so a mutating call cannot go inside one. Every
/// `sonifier.moment(for:)` is therefore taken into a local first.
@Suite("Sonification")
struct SonifierTests {

    // MARK: - Frame construction

    /// A frame with the properties a test wants to talk about, and nothing accidental.
    static func frame(index: Int = 0, recycle: Int = 0, residues n: Int = 12,
                      structure: [SecondaryStructure]? = nil,
                      confidence: [Float]? = nil,
                      contacts: [ContactEvent] = [],
                      radiusOfGyration: Float? = nil,
                      interpolated: Bool = false) -> FoldFrame {
        let states = structure ?? Array(repeating: .coil, count: n)
        let plddt = confidence ?? Array(repeating: Float(80), count: n)
        // A straight line of alpha carbons at 3.8 A. The coordinates only matter to the
        // renderer; the sonifier reads the derived quantities, which are passed in.
        let backbone = (0..<n).map { i -> BackboneResidue in
            let p = SIMD3<Float>(Float(i) * 3.8, 0, 0)
            return BackboneResidue(n: p, ca: p, c: p, o: p)
        }
        let mean = plddt.isEmpty ? 0 : plddt.reduce(0, +) / Float(plddt.count)
        return FoldFrame(index: index, recycle: recycle, blockIndex: 0,
                         backbone: backbone, pLDDT: plddt,
                         secondaryStructure: states.map {
                             SSAssignment(structure: $0, confidence: 1)
                         },
                         newContacts: contacts,
                         radiusOfGyration: radiusOfGyration
                             ?? Float(1.927 * pow(Double(n), 0.598)),
                         meanPLDDT: mean, isInterpolated: interpolated)
    }

    static var style: StyleProfile {
        get throws {
            let loaded = try StyleLibrary.profiles(in: StyleProfileTests.stylesDirectory)
            return try #require(loaded["fantasy"])
        }
    }

    static func acids(_ sequence: String) -> [AminoAcid] {
        sequence.map { AminoAcid(code: $0) }
    }

    static func sonifier(residues: [AminoAcid]? = nil, count: Int = 12) throws -> Sonifier {
        Sonifier(style: try style,
                 residues: residues ?? Array(repeating: AminoAcid.alanine, count: count))
    }

    /// A sonifier that has already seen its first frame.
    ///
    /// The first raw frame establishes the starting state and its contacts are not sounded, so
    /// a test about contact *events* has to be past it or it is testing the opening bar.
    static func started(count: Int = 12) throws -> Sonifier {
        var sonifier = try Self.sonifier(count: count)
        _ = sonifier.moment(for: Self.frame(index: 0, residues: count))
        return sonifier
    }

    // MARK: - Interpolated frames

    @Test("interpolated frames make no music")
    func interpolatedFramesAreSilent() throws {
        var sonifier = try Self.sonifier()
        // PLAN.md: triggering on interpolated frames turns one contact into a burst of sixty.
        let interpolated = Self.frame(index: 1, contacts: [
            ContactEvent(i: 0, j: 9, distance: 7, isHydrophobicPair: true),
        ], interpolated: true)
        #expect(sonifier.moment(for: interpolated) == nil)
        #expect(sonifier.moment(for: Self.frame(index: 0)) != nil)
        // And it stayed silent as an event source: the interpolated frame did not consume the
        // establishing slot either.
        #expect(sonifier.moment(for: Self.frame(index: 2))?.establishedContacts == 0)
    }

    @Test("an empty frame makes no music rather than crashing")
    func emptyFrameIsSilent() throws {
        var sonifier = try Self.sonifier(count: 0)
        #expect(sonifier.moment(for: Self.frame(residues: 0)) == nil)
    }

    // MARK: - Contacts

    @Test("sequence separation sets register: local high, long-range low")
    func separationSetsRegister() throws {
        var sonifier = try Self.started(count: 40)
        let input = Self.frame(index: 1, residues: 40, contacts: [
            ContactEvent(i: 0, j: 4, distance: 7, isHydrophobicPair: false),   // local
            ContactEvent(i: 0, j: 9, distance: 7, isHydrophobicPair: false),   // medium
            ContactEvent(i: 0, j: 30, distance: 7, isHydrophobicPair: false),  // long-range
        ])
        let produced = sonifier.moment(for: input)
        let moment = try #require(produced)
        // All three are residue 0, so the only thing separating their pitches is the register
        // the contact range asks for.
        let byPartner = Dictionary(uniqueKeysWithValues:
            moment.notes.filter { $0.voice == .contact }
                .map { ($0.partner ?? -1, $0.note.pitch) })
        let local = try #require(byPartner[4])
        let medium = try #require(byPartner[9])
        let long = try #require(byPartner[30])
        #expect(local > medium)
        #expect(medium > long)
        #expect(Int(local) - Int(medium) == 12)
        #expect(Int(medium) - Int(long) == 12)
    }

    @Test("a long-range hydrophobic contact is a bass note, and the lowest thing playing")
    func coreContactsAreBass() throws {
        var sonifier = try Self.started(count: 40)
        let input = Self.frame(index: 1, residues: 40, contacts: [
            ContactEvent(i: 0, j: 30, distance: 7, isHydrophobicPair: true),
            ContactEvent(i: 1, j: 32, distance: 7, isHydrophobicPair: false),
        ])
        let produced = sonifier.moment(for: input)
        let moment = try #require(produced)
        let bass = try #require(moment.notes.first { $0.voice == .bass })
        let plain = try #require(moment.notes.first { $0.voice == .contact })
        #expect(bass.partner == 30)
        #expect(bass.note.pitch < plain.note.pitch)
        // Core packing rings on: PLAN.md gives it a haptic transient too, and a note that
        // decayed in a beat would not be there when the haptic landed.
        #expect(bass.duration > plain.duration)
    }

    @Test("a short-range hydrophobic pair is not core packing")
    func hydrophobicButLocalIsNotBass() throws {
        var sonifier = try Self.started(count: 40)
        let input = Self.frame(index: 1, residues: 40, contacts: [
            ContactEvent(i: 0, j: 4, distance: 7, isHydrophobicPair: true),
        ])
        let produced = sonifier.moment(for: input)
        let moment = try #require(produced)
        // Two hydrophobic residues four apart are the same turn of one helix, not a core.
        #expect(!moment.notes.contains { $0.voice == .bass })
    }

    @Test("a burst of contacts keeps the ones that carry the fold and reports the rest")
    func contactBurstIsCappedNotDropped() throws {
        var sonifier = try Self.started(count: 80)
        // Thirty contacts on one readout, above the measured p99 for a structure-based fold.
        // Two of them are long-range core packing.
        var contacts = (0..<28).map {
            ContactEvent(i: $0, j: $0 + 7, distance: 7, isHydrophobicPair: false)
        }
        contacts.append(ContactEvent(i: 2, j: 60, distance: 7, isHydrophobicPair: true))
        contacts.append(ContactEvent(i: 3, j: 55, distance: 7, isHydrophobicPair: true))

        let produced = sonifier.moment(for: Self.frame(index: 1, residues: 80,
                                                       contacts: contacts))
        let moment = try #require(produced)
        let sounded = moment.notes.filter { $0.voice == .contact || $0.voice == .bass }
        #expect(sounded.count == 16)
        #expect(moment.droppedContacts == 14)
        // Spread across the bar, so sixteen contacts are sixteen audible events.
        #expect(Set(sounded.map(\.beatOffset)).count == 16)
        // Both core contacts survived the cap: they are what the cap exists to protect.
        #expect(sounded.filter { $0.voice == .bass }.count == 2)
    }

    @Test("contact velocity comes from both partners' confidence")
    func contactVelocityUsesBothPartners() throws {
        var sonifier = try Self.started(count: 40)
        var confidence = [Float](repeating: 50, count: 40)
        confidence[0] = 100
        confidence[30] = 0
        let input = Self.frame(
            index: 1, residues: 40, confidence: confidence,
            contacts: [ContactEvent(i: 0, j: 30, distance: 7, isHydrophobicPair: false)])
        let produced = sonifier.moment(for: input)
        let moment = try #require(produced)
        let note = try #require(moment.notes.first { $0.voice == .contact })
        // Mean of 100 and 0 is 50, which is halfway up the 30...120 velocity range.
        #expect(note.note.velocity == 75)
    }

    // MARK: - Texture

    @Test("helix content is a sustained pad, placed on the helix")
    func helixBecomesAPad() throws {
        var sonifier = try Self.sonifier(count: 20)
        var states = [SecondaryStructure](repeating: .coil, count: 20)
        for i in 4..<12 { states[i] = .helix }
        let produced = sonifier.moment(for: Self.frame(residues: 20, structure: states))
        let moment = try #require(produced)
        let pad = moment.notes.filter { $0.voice == .pad }
        #expect(!pad.isEmpty)
        // Held for the whole bar, and positioned where the helix actually is - which is what
        // makes the spatial mix mean anything.
        #expect(pad.allSatisfy { $0.duration == 4 })
        #expect(pad.allSatisfy { (4..<12).contains($0.residue) })
    }

    @Test("sheet is staccato and coil is arpeggiated, and they interlock")
    func sheetAndCoilAreDistinct() throws {
        var sonifier = try Self.sonifier(count: 20)
        var states = [SecondaryStructure](repeating: .coil, count: 20)
        for i in 0..<10 { states[i] = .sheet }
        let produced = sonifier.moment(for: Self.frame(residues: 20, structure: states))
        let moment = try #require(produced)
        let rhythm = moment.notes.filter { $0.voice == .rhythm }
        let arpeggio = moment.notes.filter { $0.voice == .arpeggio }
        #expect(!rhythm.isEmpty)
        #expect(!arpeggio.isEmpty)
        #expect(rhythm.allSatisfy { $0.duration < 0.25 })
        #expect(rhythm.allSatisfy { (0..<10).contains($0.residue) })
        #expect(arpeggio.allSatisfy { (10..<20).contains($0.residue) })
        // Offset from each other, so the two figures interlock rather than double.
        let rhythmBeats = Set(rhythm.map(\.beatOffset))
        let arpeggioBeats = Set(arpeggio.map(\.beatOffset))
        #expect(rhythmBeats.isDisjoint(with: arpeggioBeats))
    }

    @Test("a trace of sheet still sounds")
    func smallContentIsNotRoundedToSilence() throws {
        var sonifier = try Self.sonifier(count: 100)
        var states = [SecondaryStructure](repeating: .coil, count: 100)
        states[50] = .sheet
        states[51] = .sheet
        let produced = sonifier.moment(for: Self.frame(residues: 100, structure: states))
        let moment = try #require(produced)
        // 2% of 8 notes rounds to zero; a two-residue strand must still be audible, or
        // silence reads as "no sheet" rather than "a little sheet".
        #expect(moment.notes.contains { $0.voice == .rhythm })
    }

    @Test("a structure with no coil has no arpeggio")
    func absentContentIsSilent() throws {
        var sonifier = try Self.sonifier(count: 20)
        let states = [SecondaryStructure](repeating: .helix, count: 20)
        let produced = sonifier.moment(for: Self.frame(residues: 20, structure: states))
        let moment = try #require(produced)
        #expect(!moment.notes.contains { $0.voice == .arpeggio })
        #expect(!moment.notes.contains { $0.voice == .rhythm })
        #expect(moment.notes.contains { $0.voice == .pad })
    }

    // MARK: - Confidence

    @Test("low confidence sounds murky and out of tune")
    func confidenceDrivesTimbre() {
        let murky = Sonifier.timbre(meanConfidence: 20)
        let clear = Sonifier.timbre(meanConfidence: 95)
        #expect(murky.cutoff < clear.cutoff)
        #expect(murky.detuneCents > clear.detuneCents)
        #expect(murky.reverb > clear.reverb)
        // The named endpoints, so a later tweak to the curve has to be deliberate.
        #expect(abs(Sonifier.timbre(meanConfidence: 0).cutoff - 500) < 0.001)
        #expect(abs(Sonifier.timbre(meanConfidence: 100).cutoff - 14000) < 0.001)
        #expect(Sonifier.timbre(meanConfidence: 100).detuneCents == 0)
    }

    @Test("per-residue confidence is that residue's velocity")
    func confidenceDrivesVelocity() {
        #expect(Sonifier.velocity(confidence: 0) == 30)
        #expect(Sonifier.velocity(confidence: 100) == 120)
        #expect(Sonifier.velocity(confidence: 50) == 75)
        // A residue is never silent, however badly resolved: it must be heard sounding wrong.
        #expect(Sonifier.velocity(confidence: -50) >= 30)
        #expect(Sonifier.velocity(confidence: 500) <= 127)
    }

    // MARK: - Compaction

    @Test("compaction is measured against chain length, not against an absolute radius")
    func compactionIsLengthNormalised() {
        // Kohn et al. denatured, and Dima and Thirumalai native, at each length.
        for n in [20, 76, 129, 300] {
            let denatured = Float(1.927 * pow(Double(n), 0.598))
            let native = Float(2.2 * pow(Double(n), 0.38))
            #expect(Sonifier.compaction(radiusOfGyration: denatured, residueCount: n) < 0.01)
            #expect(Sonifier.compaction(radiusOfGyration: native, residueCount: n) > 0.99)
        }
        // Without normalisation a 20-mer would read as permanently compact and a 300-mer as
        // permanently extended: check that a real native radius reads as folded at both ends.
        // Trp-cage, 20 residues, Rg about 7.2 A. Lysozyme, 129 residues, about 14.3 A.
        #expect(Sonifier.compaction(radiusOfGyration: 7.2, residueCount: 20) > 0.9)
        #expect(Sonifier.compaction(radiusOfGyration: 14.3, residueCount: 129) > 0.9)
    }

    @Test("compaction refuses to report nonsense")
    func compactionIsRobust() {
        #expect(Sonifier.compaction(radiusOfGyration: .nan, residueCount: 100) == 0)
        #expect(Sonifier.compaction(radiusOfGyration: 0, residueCount: 100) == 0)
        #expect(Sonifier.compaction(radiusOfGyration: 10, residueCount: 0) == 0)
        #expect(Sonifier.compaction(radiusOfGyration: 1, residueCount: 100) == 1)
        #expect(Sonifier.compaction(radiusOfGyration: 1000, residueCount: 100) == 0)
    }

    @Test("compaction drives an accelerando")
    func compactionDrivesTempo() throws {
        var sonifier = try Self.sonifier(count: 100)
        let slack = Self.frame(index: 0, residues: 100,
                               radiusOfGyration: Float(1.927 * pow(100.0, 0.598)))
        let tight = Self.frame(index: 1, residues: 100,
                               radiusOfGyration: Float(2.2 * pow(100.0, 0.38)))
        let a = sonifier.moment(for: slack)
        let unfolded = try #require(a)
        let b = sonifier.moment(for: tight)
        let folded = try #require(b)
        let style = try Self.style
        #expect(folded.tempo > unfolded.tempo)
        #expect(abs(unfolded.tempo - style.tempoSlow) < 0.5)
        #expect(abs(folded.tempo - style.tempoFast) < 0.5)
    }

    // MARK: - Harmony

    @Test("a recycle boundary modulates the harmony")
    func recycleBoundaryModulates() throws {
        var sonifier = try Self.sonifier()
        let a = sonifier.moment(for: Self.frame(index: 0, recycle: 0))
        let first = try #require(a)
        let b = sonifier.moment(for: Self.frame(index: 1, recycle: 0))
        let same = try #require(b)
        let c = sonifier.moment(for: Self.frame(index: 2, recycle: 1))
        let next = try #require(c)
        #expect(!first.isModulation)
        #expect(!same.isModulation)
        #expect(same.degree == first.degree)
        #expect(next.isModulation)
        #expect(next.degree != first.degree)
    }

    @Test("a confidence plateau cadences to the tonic and stays there")
    func convergenceCadences() throws {
        var sonifier = try Self.sonifier()
        var moments: [ScoreMoment] = []
        // Ten frames climbing, then twelve flat and high: the plateau PLAN.md calls
        // convergence.
        let curve = stride(from: Float(40), to: 90, by: 5).map { $0 }
            + Array(repeating: Float(92), count: 8)
        for (i, value) in curve.enumerated() {
            let frame = Self.frame(index: i, recycle: i / 4,
                                   confidence: Array(repeating: value, count: 12))
            let produced = sonifier.moment(for: frame)
            moments.append(try #require(produced))
        }
        let cadences = moments.filter(\.isCadence)
        #expect(cadences.count == 1, "the cadence must happen once, not on every flat frame")
        let cadence = try #require(cadences.first)
        let progression = try Self.style.progression
        let tonic = try #require(progression.last)
        #expect(cadence.degree == tonic)
        // Having resolved, it stays resolved: no modulation may pull it off the tonic.
        let after = moments.drop { $0.frameIndex < cadence.frameIndex }
        #expect(after.allSatisfy { $0.degree == tonic })
        #expect(after.dropFirst().allSatisfy { !$0.isModulation })
    }

    @Test("a chain that never resolves never cadences")
    func disorderNeverCadences() throws {
        var sonifier = try Self.sonifier()
        // Flat, but flat and low: an intrinsically disordered region, which PLAN.md says
        // stays a detuned wash for the whole piece.
        var moments: [ScoreMoment] = []
        for i in 0..<40 {
            let frame = Self.frame(index: i, confidence: Array(repeating: Float(28), count: 12))
            if let moment = sonifier.moment(for: frame) { moments.append(moment) }
        }
        #expect(moments.count == 40)
        let cadenced = moments.contains { $0.isCadence }
        #expect(!cadenced)
        #expect(moments.allSatisfy { $0.timbre.detuneCents > 20 })
    }

    @Test("an oscillating confidence is not a plateau")
    func oscillationIsNotConvergence() {
        var detector = PlateauDetector()
        // Mean slope zero, span far too wide. A slope test would call this converged.
        var fired = false
        for i in 0..<60 where detector.update(i.isMultiple(of: 2) ? 60 : 95) { fired = true }
        #expect(!fired, "an oscillation was reported as a plateau")
    }

    // MARK: - Determinism, which is the phase gate

    @Test("the same protein always yields the same piece")
    func scoreIsDeterministic() throws {
        let residues = Self.acids("MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ")
        let style = try Self.style
        let frames = (0..<24).map { i in
            Self.frame(index: i, recycle: i / 6, residues: residues.count,
                       structure: (0..<residues.count).map {
                           $0 % 3 == 0 ? .helix : ($0 % 3 == 1 ? .sheet : .coil)
                       },
                       confidence: (0..<residues.count).map { Float(50 + ($0 * 7) % 45) },
                       contacts: i.isMultiple(of: 3)
                           ? [ContactEvent(i: i % 10, j: i % 10 + 14, distance: 7,
                                           isHydrophobicPair: i.isMultiple(of: 6))]
                           : [])
        }
        // PLAN.md's gate: identical output across three runs.
        let runs = (0..<3).map { _ in
            Sonifier.score(style: style, residues: residues, frames: frames)
        }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
        #expect(!runs[0].isEmpty)
        #expect(runs[0].contains { !$0.notes.isEmpty })
    }

    @Test("a different sequence yields a different piece")
    func differentProteinsDiffer() throws {
        let style = try Self.style
        let frames = (0..<8).map { Self.frame(index: $0, residues: 20) }
        let a = Sonifier.score(style: style,
                               residues: Self.acids("ACDEFGHIKLMNPQRSTVWY"), frames: frames)
        let b = Sonifier.score(style: style,
                               residues: Self.acids("YWVTSRQPNMLKIHGFEDCA"), frames: frames)
        #expect(a != b)
    }

    @Test("scrubbing to a frame gives the same chord as playing to it")
    func voicingIsSeekable() {
        // The stochastic choice is derived from the frame's own position, not from a stream
        // advanced frame by frame - otherwise the same protein would sound different
        // depending on how you got there.
        let seed = SequenceSeed(sequence: "MKTAYIAKQ")
        for position in [0, 1, 97, 1_000] {
            var played = seed.stream(at: position)
            var scrubbed = seed.stream(at: position)
            #expect(played.next() == scrubbed.next())
        }
        var a = seed.stream(at: 10)
        var b = seed.stream(at: 11)
        #expect(a.next() != b.next())
    }

    // MARK: - Spatial audio needs every note placed

    @Test("every note names a residue that exists")
    func everyNoteIsPlaceable() throws {
        let n = 30
        var sonifier = try Self.started(count: n)
        var states = [SecondaryStructure](repeating: .coil, count: n)
        for i in 0..<10 { states[i] = .helix }
        for i in 10..<20 { states[i] = .sheet }
        let input = Self.frame(
            index: 1, residues: n, structure: states,
            contacts: [ContactEvent(i: 1, j: 25, distance: 7, isHydrophobicPair: true)])
        let produced = sonifier.moment(for: input)
        let moment = try #require(produced)
        #expect(!moment.notes.isEmpty)
        for note in moment.notes {
            // Spatial audio positions each note at its residue's live coordinate; an index
            // outside the chain has no coordinate to be placed at.
            for residue in note.spatialResidues {
                #expect((0..<n).contains(residue))
            }
            #expect(note.note.pitch >= 1 && note.note.pitch <= 127)
            #expect(note.beatOffset >= 0 && note.beatOffset < Sonifier.beatsPerBar)
        }
        // A contact is placed between its two partners, not at one end.
        let contact = try #require(moment.notes.first { $0.voice == .bass })
        #expect(contact.spatialResidues == [1, 25])
    }

    // MARK: - The pitch layer

    @Test("the pitch layer maps residues by property, and R K D E shift an octave")
    func pitchLayerFollowsTayEtAl() throws {
        let layer = PitchLayer(style: try Self.style)
        // Every acid lands on a degree of the scale.
        for acid in AminoAcid.allCases {
            #expect((0..<7).contains(layer.degree(for: acid)))
        }
        // Residues of similar hydropathy sit on adjacent degrees, which is what makes a run
        // of like residues move stepwise instead of leaping.
        #expect(layer.degree(for: .isoleucine) == 0)   // most hydrophobic
        #expect(layer.degree(for: .valine) == 1)
        #expect(layer.degree(for: .leucine) == 2)

        // The four charged residues Tay et al. use as octave-shift triggers.
        for acid in [AminoAcid.arginine, .lysine, .asparticAcid, .glutamicAcid] {
            let shifted = layer.pitch(for: acid, octave: 0)
            let plain = layer.scale.pitch(degree: layer.degree(for: acid), octaveShift: 0)
            #expect(Int(shifted) - Int(plain) == 12)
        }
        // And a residue that is not a trigger is not shifted.
        let alanine = layer.pitch(for: .alanine, octave: 0)
        #expect(alanine == layer.scale.pitch(degree: layer.degree(for: .alanine),
                                             octaveShift: 0))
    }
}

extension SonifierTests {

    @Test("the first frame establishes the starting state rather than sounding it")
    func firstFrameIsInventoryNotEvents() throws {
        var sonifier = try Self.sonifier(count: 40)
        // A bundled ESMFold readout opens with its entire contact map. Sounding that would
        // start every piece with a crash that says nothing about folding.
        let opening = (0..<200).map {
            ContactEvent(i: $0 % 30, j: $0 % 30 + 8, distance: 7, isHydrophobicPair: false)
        }
        let first = sonifier.moment(for: Self.frame(index: 0, residues: 40, contacts: opening))
        let opened = try #require(first)
        #expect(opened.establishedContacts == 200)
        #expect(opened.droppedContacts == 0, "an opening state is not a dropped event")
        #expect(!opened.notes.contains { $0.voice == .contact || $0.voice == .bass })
        // The bar is not silent: the texture voices still play the structure.
        #expect(!opened.notes.isEmpty)

        // The next frame's contacts are events, and they sound.
        let second = sonifier.moment(for: Self.frame(
            index: 1, residues: 40,
            contacts: [ContactEvent(i: 0, j: 20, distance: 7, isHydrophobicPair: false)]))
        let event = try #require(second)
        #expect(event.establishedContacts == 0)
        #expect(event.notes.contains { $0.voice == .contact })
    }
}

extension SonifierTests {

    @Test("a style change keeps the piece where it was, rather than restarting it")
    func styleSwitchIsNotARestart() throws {
        let styles = try StyleLibrary.profiles(in: StyleProfileTests.stylesDirectory)
        let fantasy = try #require(styles["fantasy"])
        let rock = try #require(styles["rock"])

        var sonifier = Sonifier(style: fantasy, residues: Self.acids("MKTAYIAKQRQ"))
        // Four moments on four recycles: three modulations, so the piece sits at index 3.
        //
        // Not six: Fantasy's progression both begins and ends on the tonic, so at index 5 the
        // *degree* is back to the opening one and "has it modulated" cannot be asked of the
        // degree alone. Index 3 is degree 6, which is unambiguous.
        var moments: [ScoreMoment] = []
        for i in 0..<4 {
            if let moment = sonifier.moment(for: Self.frame(index: i, recycle: i, residues: 11)) {
                moments.append(moment)
            }
        }
        let before = try #require(moments.last)
        #expect(before.degree == fantasy.progression[3], "the test needs to have modulated")
        #expect(before.degree != fantasy.progression[0])

        sonifier.adopt(rock)
        let produced = sonifier.moment(for: Self.frame(index: 4, recycle: 3, residues: 11))
        let after = try #require(produced)
        // PLAN.md: live and beat-quantised, never a restart. A rebuilt sonifier would send a
        // piece that had modulated three times back to the opening chord, which is the one
        // thing a listener hears as a restart whatever else stays the same.
        #expect(sonifier.style.id == "rock")
        // Rock's progression is five long and Fantasy's six: the position is clamped into it
        // rather than wrapped, so a piece that was late stays late.
        #expect(after.degree == rock.progression[3])
    }

    @Test("a piece that has resolved stays resolved through a style change")
    func styleSwitchKeepsTheCadence() throws {
        let styles = try StyleLibrary.profiles(in: StyleProfileTests.stylesDirectory)
        let fantasy = try #require(styles["fantasy"])
        let jazz = try #require(styles["jazz"])

        var sonifier = Sonifier(style: fantasy, residues: Self.acids("MKTAYIAKQRQ"))
        var cadenced = false
        for i in 0..<20 {
            let frame = Self.frame(index: i, residues: 11,
                                   confidence: Array(repeating: Float(93), count: 11))
            if let moment = sonifier.moment(for: frame), moment.isCadence { cadenced = true }
        }
        #expect(cadenced, "the test needs the piece to have resolved first")

        sonifier.adopt(jazz)
        let produced = sonifier.moment(for: Self.frame(
            index: 21, residues: 11, confidence: Array(repeating: Float(93), count: 11)))
        let after = try #require(produced)
        // Having resolved, it stays resolved: a switch must not send a finished piece back to
        // its opening chord.
        #expect(after.degree == jazz.progression[jazz.progression.count - 1])
        #expect(!after.isCadence, "it cadenced once already")
    }

    @Test("adopting the style already in force changes nothing")
    func adoptingTheSameStyleIsANoOp() throws {
        let fantasy = try Self.style
        var sonifier = Sonifier(style: fantasy, residues: Self.acids("MKTAYIAKQ"))
        _ = sonifier.moment(for: Self.frame(index: 0, residues: 9))
        let before = sonifier.moment(for: Self.frame(index: 1, recycle: 1, residues: 9))
        sonifier.adopt(fantasy)
        let after = sonifier.moment(for: Self.frame(index: 2, recycle: 1, residues: 9))
        #expect(before?.degree == after?.degree)
    }
}

extension SonifierTests {

    @Test("swing moves the offbeat late and leaves the downbeat alone")
    func swingWarpsTheBeat() {
        // Straight is the identity, exactly - not nearly.
        for beat in [0.0, 0.25, 0.5, 0.75, 1.0, 2.5] {
            #expect(Sonifier.swung(beat, swing: 0) == beat)
        }
        // A downbeat never moves, whatever the swing.
        for beat in [0.0, 1.0, 2.0, 7.0] {
            #expect(abs(Sonifier.swung(beat, swing: 0.33) - beat) < 1e-12)
        }
        // Triplet feel: the offbeat eighth lands on two thirds of the beat.
        #expect(abs(Sonifier.swung(0.5, swing: 1.0 / 3) - 2.0 / 3) < 1e-12)
        #expect(abs(Sonifier.swung(1.5, swing: 1.0 / 3) - (1 + 2.0 / 3)) < 1e-12)

        // Every subdivision moves, not just the eighths - otherwise a semiquaver flurry would
        // run straight across a swung bar and sound like two pieces at once.
        #expect(Sonifier.swung(0.25, swing: 0.33) > 0.25)
        #expect(Sonifier.swung(0.75, swing: 0.33) > 0.75)
        // And the warp is monotonic, so nothing overtakes anything.
        let warped = stride(from: 0.0, through: 2.0, by: 0.05)
            .map { Sonifier.swung($0, swing: 0.33) }
        #expect(zip(warped, warped.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("a swung style places its notes late and a straight one does not")
    func swingReachesTheNotes() throws {
        let styles = try StyleLibrary.profiles(in: StyleProfileTests.stylesDirectory)
        let jazz = try #require(styles["jazz"])       // swing 0.33
        let rock = try #require(styles["rock"])       // swing 0
        #expect(jazz.swing > 0.2)
        #expect(rock.swing == 0)

        func offsets(_ style: StyleProfile) -> [Double] {
            var sonifier = Sonifier(style: style, residues: Self.acids("MKTAYIAKQRQISFVKSHFS"))
            var states = [SecondaryStructure](repeating: .coil, count: 20)
            for i in 0..<8 { states[i] = .sheet }
            _ = sonifier.moment(for: Self.frame(index: 0, residues: 20, structure: states))
            let produced = sonifier.moment(for: Self.frame(
                index: 1, residues: 20, structure: states,
                contacts: (0..<4).map {
                    ContactEvent(i: $0, j: $0 + 10, distance: 7, isHydrophobicPair: false)
                }))
            return (produced?.notes ?? []).map(\.beatOffset).filter { $0 > 0 }
        }
        let swung = offsets(jazz)
        let straight = offsets(rock)
        #expect(!swung.isEmpty && !straight.isEmpty)
        // Off-beat notes are later under swing. Downbeats are excluded above, because they do
        // not move and would dilute the comparison to nothing.
        #expect(swung.min()! > straight.min()!)
    }
}
