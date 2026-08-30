import Testing
import Foundation
@testable import FoldAudio
import FoldCore

/// The MIDI export: PLAN.md's gate is that it "parses correctly and round-trips".
@Suite("MIDI export")
struct MIDIExportTests {

    static func note(_ voice: Voice, beat: Double, pitch: UInt8, velocity: UInt8 = 90,
                     residue: Int = 0, duration: Double = 1) -> NoteEvent {
        NoteEvent(voice: voice, note: MIDINote(pitch: pitch, velocity: velocity),
                  residue: residue, beatOffset: beat, duration: duration)
    }

    static func moment(_ index: Int, tempo: Double = 120, beats: Double = 1,
                       notes: [NoteEvent]) -> ScoreMoment {
        ScoreMoment(frameIndex: index, tempo: tempo, notes: notes,
                    timbre: Sonifier.timbre(meanConfidence: 80), degree: 0,
                    isCadence: false, isModulation: false, compaction: 0.5,
                    droppedContacts: 0, beats: beats)
    }

    // MARK: - The bytes themselves

    @Test("variable-length quantities match the specification's own examples")
    func variableLengthIsCorrect() {
        // From the Standard MIDI File specification's table.
        #expect(MIDIFile.variableLength(0) == [0x00])
        #expect(MIDIFile.variableLength(0x40) == [0x40])
        #expect(MIDIFile.variableLength(0x7F) == [0x7F])
        #expect(MIDIFile.variableLength(0x80) == [0x81, 0x00])
        #expect(MIDIFile.variableLength(0x2000) == [0xC0, 0x00])
        #expect(MIDIFile.variableLength(0x3FFF) == [0xFF, 0x7F])
        #expect(MIDIFile.variableLength(0x100000) == [0xC0, 0x80, 0x00])
        #expect(MIDIFile.variableLength(0x0FFFFFFF) == [0xFF, 0xFF, 0xFF, 0x7F])
        // A negative delta is not expressible and must not wrap into a huge one.
        #expect(MIDIFile.variableLength(-5) == [0x00])
    }

    @Test("the header says what the file is")
    func headerIsWellFormed() throws {
        let style = try SonifierTests.style
        let data = MIDIFile.encode([Self.moment(0, notes: [Self.note(.pad, beat: 0, pitch: 60)])],
                                   style: style)
        let bytes = [UInt8](data)
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "MThd")
        #expect(Array(bytes[4..<8]) == [0, 0, 0, 6])
        #expect(Array(bytes[8..<10]) == [0, 1], "format 1: a conductor track and voice tracks")
        #expect(Array(bytes[10..<12]) == [0, 2], "the conductor track, and one voice")
        #expect(Int(bytes[12]) << 8 | Int(bytes[13]) == MIDIFile.ticksPerQuarter)
        #expect(String(decoding: bytes[14..<18], as: UTF8.self) == "MTrk")
    }

    // MARK: - Round trip

    @Test("what goes in comes back out")
    func roundTripsExactly() throws {
        let style = try SonifierTests.style
        let score = [
            Self.moment(0, tempo: 120, notes: [
                Self.note(.pad, beat: 0, pitch: 57, velocity: 70, duration: 4),
                Self.note(.contact, beat: 0.25, pitch: 69, velocity: 110, duration: 1),
                Self.note(.rhythm, beat: 0.5, pitch: 76, velocity: 60, duration: 0.25),
            ]),
            Self.moment(1, tempo: 99, notes: [
                Self.note(.bass, beat: 0, pitch: 33, velocity: 100, duration: 2),
                Self.note(.arpeggio, beat: 0.75, pitch: 64, velocity: 80, duration: 0.25),
            ]),
        ]
        let parsed = try MIDIFile.decode(MIDIFile.encode(score, style: style))

        #expect(parsed.format == 1)
        #expect(parsed.ticksPerQuarter == MIDIFile.ticksPerQuarter)
        #expect(parsed.notes.count == 5)

        // Every note, at the right tick, on the right channel, for the right length.
        let tpq = Double(MIDIFile.ticksPerQuarter)
        var expected: [(NoteEvent, Double)] = []
        var beat = 0.0
        for moment in score {
            for note in moment.notes { expected.append((note, beat)) }
            beat += moment.beats
        }
        for (event, momentBeat) in expected {
            let tick = Int(((momentBeat + event.beatOffset) * tpq).rounded())
            let match = parsed.notes.first {
                $0.tick == tick && $0.pitch == event.note.pitch
                    && $0.channel == MIDIFile.channel(for: event.voice)
            }
            let found = try #require(match, "\(event.voice) at beat \(momentBeat + event.beatOffset) is missing")
            #expect(found.velocity == event.note.velocity)
            #expect(found.lengthInTicks == Int((event.duration * tpq).rounded()))
        }
    }

    @Test("the accelerando survives, as a tempo map rather than a baked-in speed")
    func tempoMapRoundTrips() throws {
        let style = try SonifierTests.style
        // Three moments at rising tempo, as compaction produces.
        let score = (0..<3).map { i in
            Self.moment(i, tempo: [66.0, 99, 132][i],
                        notes: [Self.note(.pad, beat: 0, pitch: 60)])
        }
        let parsed = try MIDIFile.decode(MIDIFile.encode(score, style: style))
        let tempi = parsed.tempi
        #expect(tempi.count == 3)
        for (index, expected) in [66.0, 99, 132].enumerated() {
            #expect(abs(tempi[index].bpm - expected) < 0.05,
                    "tempo \(index) came back as \(tempi[index].bpm)")
            #expect(tempi[index].tick == index * MIDIFile.ticksPerQuarter)
        }
        // Ticks are tempo-independent, so the notes stay a beat apart whatever the tempo does.
        #expect(parsed.notes.map(\.tick) == (0..<3).map { $0 * MIDIFile.ticksPerQuarter })
    }

    @Test("a tempo that does not change is not written twice")
    func tempoIsWrittenOnlyOnChange() throws {
        let style = try SonifierTests.style
        let score = (0..<8).map {
            Self.moment($0, tempo: 100, notes: [Self.note(.pad, beat: 0, pitch: 60)])
        }
        let parsed = try MIDIFile.decode(MIDIFile.encode(score, style: style))
        #expect(parsed.tempoChanges.count == 1, "eight identical tempi is one tempo event")
    }

    @Test("each voice gets its own channel and its own named track")
    func voicesAreSeparated() throws {
        let style = try SonifierTests.style
        let score = [Self.moment(0, notes: Voice.allCases.enumerated().map { index, voice in
            Self.note(voice, beat: 0, pitch: UInt8(50 + index * 3))
        })]
        let parsed = try MIDIFile.decode(MIDIFile.encode(score, style: style))
        #expect(Set(parsed.notes.map(\.channel)).count == Voice.allCases.count)
        // The conductor track carries the style's name; the rest are named for their voice, so
        // a DAW shows five labelled lines rather than five untitled ones.
        #expect(parsed.trackNames.first == style.name)
        #expect(Set(parsed.trackNames.dropFirst()) == Set(Voice.allCases.map(\.rawValue)))
        // Nothing on channel 9, which General MIDI plays as percussion whatever the note says.
        #expect(!parsed.notes.contains { $0.channel == 9 })
    }

    @Test("a repeated note is released before it is struck again")
    func repeatedNotesDoNotSwallowEachOther() throws {
        let style = try SonifierTests.style
        // The same pitch twice, the first ending exactly where the second begins.
        let score = [Self.moment(0, beats: 2, notes: [
            Self.note(.contact, beat: 0, pitch: 60, duration: 1),
            Self.note(.contact, beat: 1, pitch: 60, duration: 1),
        ])]
        let parsed = try MIDIFile.decode(MIDIFile.encode(score, style: style))
        // Without ordering note-offs ahead of note-ons on the same tick, the second onset is
        // cancelled by the first note's release and only one note survives.
        #expect(parsed.notes.count == 2)
        #expect(parsed.notes.allSatisfy { $0.lengthInTicks == MIDIFile.ticksPerQuarter })
    }

    @Test("the same score writes the same bytes")
    func exportIsDeterministic() throws {
        let style = try SonifierTests.style
        let score = (0..<12).map { i in
            Self.moment(i, tempo: 66 + Double(i) * 5, notes: Voice.allCases.map { voice in
                Self.note(voice, beat: Double(voice.slot) * 0.2, pitch: UInt8(48 + voice.slot * 4))
            })
        }
        let runs = (0..<3).map { _ in MIDIFile.encode(score, style: style) }
        #expect(runs[0] == runs[1])
        #expect(runs[1] == runs[2])
    }

    // MARK: - Reading files this did not write

    @Test("running status is understood")
    func runningStatusIsHandled() throws {
        // A note-on, then a second with its status byte omitted - which is how most writers
        // save space, and what a reader tested only against its own writer would never meet.
        var track: [UInt8] = [0x00, 0xFF, 0x03, 0x04] + Array("test".utf8)
        track += [0x00, 0x90, 60, 100]      // note on, explicit status
        track += [0x00, 64, 100]            // note on, running status
        track += [0x60, 0x80, 60, 64]       // note off
        track += [0x00, 64, 64]             // note off, running status
        track += [0x00, 0xFF, 0x2F, 0x00]
        let file = MIDIFile.chunk("MThd", MIDIFile.bigEndian(0, bytes: 2)
                                  + MIDIFile.bigEndian(1, bytes: 2)
                                  + MIDIFile.bigEndian(480, bytes: 2))
            + MIDIFile.chunk("MTrk", track)
        let parsed = try MIDIFile.decode(Data(file))
        #expect(parsed.notes.count == 2)
        #expect(Set(parsed.notes.map(\.pitch)) == [60, 64])
        #expect(parsed.notes.allSatisfy { $0.lengthInTicks == 0x60 })
    }

    @Test("a note-on with zero velocity is a note-off")
    func zeroVelocityIsANoteOff() throws {
        let track: [UInt8] = [0x00, 0x90, 60, 100, 0x40, 0x90, 60, 0x00,
                              0x00, 0xFF, 0x2F, 0x00]
        let file = MIDIFile.chunk("MThd", MIDIFile.bigEndian(0, bytes: 2)
                                  + MIDIFile.bigEndian(1, bytes: 2)
                                  + MIDIFile.bigEndian(480, bytes: 2))
            + MIDIFile.chunk("MTrk", track)
        let parsed = try MIDIFile.decode(Data(file))
        // Files in the wild use this far more often than 0x80. A reader that ignored it would
        // report every note as running to the end of the piece.
        #expect(parsed.notes.count == 1)
        #expect(parsed.notes.first?.lengthInTicks == 0x40)
    }

    @Test("rubbish is refused, and says what was wrong")
    func malformedFilesAreRefused() {
        #expect(throws: MIDIFile.Malformed.notAMIDIFile) {
            try MIDIFile.decode(Data("this is not a midi file at all".utf8))
        }
        #expect(throws: MIDIFile.Malformed.self) { try MIDIFile.decode(Data()) }
        // SMPTE timing sets the top bit of the division. It is legal MIDI and this writer does
        // not produce it, so it is refused by name rather than silently misread as ticks.
        let smpte = MIDIFile.chunk("MThd", MIDIFile.bigEndian(0, bytes: 2)
                                   + MIDIFile.bigEndian(1, bytes: 2)
                                   + [0xE8, 0x28])
        #expect(throws: MIDIFile.Malformed.self) { try MIDIFile.decode(Data(smpte)) }
    }

    @Test("the same pitch twice over is truncated, not lost")
    func overlappingPitchesAreTruncated() throws {
        let style = try SonifierTests.style
        // What the score really asks for: a pad sustaining four beats, restruck every beat.
        let score = (0..<4).map { i in
            Self.moment(i, notes: [Self.note(.pad, beat: 0, pitch: 60, duration: 4)])
        }
        let parsed = try MIDIFile.decode(MIDIFile.encode(score, style: style))
        // MIDI cannot express two of the same pitch overlapping on one channel; a reader has
        // no way to tell which note a later note-off ends. Truncating is what a DAW does, and
        // it is the difference between four notes and one.
        #expect(parsed.notes.count == 4)
        let tpq = MIDIFile.ticksPerQuarter
        #expect(parsed.notes.prefix(3).allSatisfy { $0.lengthInTicks == tpq },
                "each is cut off where the next begins")
        #expect(parsed.notes.last?.lengthInTicks == 4 * tpq, "and the last keeps its full length")
    }

    // MARK: - A real trajectory

    @Test("a real fold exports and comes back with every note")
    func realScoreRoundTrips() async throws {
        let input = try await OfflineRenderTests.score("ubiquitin")
        let data = MIDIFile.encode(input.score, style: input.style)
        let parsed = try MIDIFile.decode(data)
        // Every distinguishable note comes back. Two notes of the same pitch beginning on the
        // same tick of the same channel are the same musical instant twice: the synthesiser
        // gives each its own voice and both are heard, but MIDI has no way to tell them apart
        // however they are written, so the file carries one. Measured on ubiquitin: 71 notes,
        // one such pair.
        var distinct: Set<[Int]> = []
        var tick = 0
        for moment in input.score {
            for note in moment.notes {
                let onset = tick + Int((note.beatOffset * Double(MIDIFile.ticksPerQuarter)).rounded())
                distinct.insert([Int(MIDIFile.channel(for: note.voice)), Int(note.note.pitch), onset])
            }
            tick += Int((moment.beats * Double(MIDIFile.ticksPerQuarter)).rounded())
        }
        let written = input.score.reduce(0) { $0 + $1.notes.count }
        #expect(written > 0)
        #expect(parsed.notes.count == distinct.count,
                "\(written) notes went in, \(distinct.count) are distinguishable, \(parsed.notes.count) came back")
        #expect(Set(parsed.notes.map { [Int($0.channel), Int($0.pitch), $0.tick] }) == distinct)
        #expect(parsed.notes.allSatisfy { $0.lengthInTicks > 0 })
        #expect(parsed.notes.allSatisfy { $0.velocity > 0 })
        // The whole piece, in order, with the accelerando intact.
        #expect(parsed.tempoChanges.count > 1)
        #expect(zip(parsed.notes, parsed.notes.dropFirst()).allSatisfy { $0.tick <= $1.tick })
    }
}
