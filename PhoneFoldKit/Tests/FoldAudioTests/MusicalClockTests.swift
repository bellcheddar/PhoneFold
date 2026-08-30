import Testing
import Foundation
@testable import FoldAudio
import FoldCore

/// The musical clock: one readout to a beat, a bounded note queue, and no allocation while
/// playing.
@Suite("Musical clock")
struct MusicalClockTests {

    static func note(_ voice: Voice, beat: Double, pitch: UInt8 = 60, residue: Int = 0,
                     duration: Double = 1) -> NoteEvent {
        NoteEvent(voice: voice, note: MIDINote(pitch: pitch, velocity: 90),
                  residue: residue, beatOffset: beat, duration: duration)
    }

    static func moment(_ index: Int, tempo: Double = 60, notes: [NoteEvent]? = nil,
                       degree: Int = 0) -> ScoreMoment {
        ScoreMoment(frameIndex: index, tempo: tempo,
                    notes: notes ?? [note(.contact, beat: 0), note(.pad, beat: 0, duration: 4),
                                     note(.rhythm, beat: 0.5)],
                    timbre: Sonifier.timbre(meanConfidence: 80),
                    degree: degree, isCadence: false, isModulation: false,
                    compaction: 0.5, droppedContacts: 0)
    }

    // MARK: - Time

    @Test("a beat lasts as long as its tempo says")
    func beatDuration() {
        #expect(MusicalClock.beatDuration(tempo: 60) == 1)
        #expect(MusicalClock.beatDuration(tempo: 120) == 0.5)
        // One readout is one beat, not one bar: at a bar each, a 180-readout fold is an
        // eight-minute piece over an animation the app plays in twelve seconds.
        #expect(MusicalClock.momentDuration(tempo: 60) == Sonifier.beatsPerMoment)
        // A nonsense tempo must not divide by zero into an infinite beat.
        #expect(MusicalClock.beatDuration(tempo: 0).isFinite)
        #expect(MusicalClock.beatDuration(tempo: -30).isFinite)
        #expect(MusicalClock.beatDuration(tempo: .nan).isFinite)
    }

    @Test("notes come out at the times their beats ask for")
    func notesLandOnTheirBeats() {
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))
        var out: [ScheduledNote] = []
        out.reserveCapacity(64)

        clock.advance(to: 0, into: &out)
        #expect(out.count == 2, "the two notes on the beat, and nothing later")
        clock.advance(to: 0.4, into: &out)
        #expect(out.count == 2, "the off-beat has not arrived")
        clock.advance(to: 0.5, into: &out)
        #expect(out.count == 3)
        let last = out.last
        #expect(last?.time == 0.5)
        #expect(last?.duration == 1.0, "one beat at 60 BPM is one second")
    }

    @Test("tempo is honoured per moment, not fixed for the piece")
    func tempoIsPerMoment() {
        // The accelerando gives every moment its own length; a clock that assumed one tempo
        // would drift further out of step with the fold on every readout.
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))    // one second
        clock.submit(Self.moment(1, tempo: 120))   // half a second
        clock.submit(Self.moment(2, tempo: 120))
        var out: [ScheduledNote] = []
        out.reserveCapacity(64)
        clock.advance(to: 1.0, into: &out)
        #expect(out.contains { $0.time == 1.0 }, "the second moment begins at one second")
        clock.advance(to: 1.5, into: &out)
        #expect(out.contains { $0.time == 1.5 }, "and the third half a second later")
    }

    @Test("a flurry runs past its own beat instead of being thrown away")
    func overflowIsNotDropped() {
        // Sixteen contacts at semiquaver spacing is a four-beat run from a one-beat readout.
        // A scheduler that held one bar at a time would have to discard the tail.
        let flurry = (0..<16).map {
            Self.note(.contact, beat: Double($0) * Sonifier.contactSpacing,
                      pitch: UInt8(48 + $0), residue: $0)
        }
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60, notes: flurry))
        clock.submit(Self.moment(1, tempo: 60))
        clock.submit(Self.moment(2, tempo: 60))
        var out: [ScheduledNote] = []
        out.reserveCapacity(128)
        clock.advance(to: 10, into: &out)
        let contacts = out.filter { $0.note.voice == .contact }
        #expect(contacts.count == 16 + 2, "the flurry, plus the two later moments' own")
        // Its last note sits three and three-quarter beats after the readout that made it,
        // which is two whole moments later.
        #expect(contacts.map(\.time).max() == 3.75)
    }

    // MARK: - The queue

    @Test("a full queue refuses rather than growing")
    func queueIsBounded() {
        var clock = MusicalClock(capacity: 8)
        // `#expect` wraps its argument in a closure, so a mutating call is taken into a local.
        let first = clock.submit(Self.moment(0))
        #expect(first)
        var accepted = true
        for i in 1..<8 where !clock.submit(Self.moment(i)) { accepted = false }
        // An unbounded queue would turn a fast fold into a growing gap between what is on
        // screen and what is in the ears.
        #expect(!accepted)
        #expect(clock.depth == 8)
        #expect(clock.refusedNotes > 0)
    }

    @Test("the queue drains and refills rather than filling up permanently")
    func queueDrains() {
        var clock = MusicalClock(capacity: 16)
        var out: [ScheduledNote] = []
        out.reserveCapacity(1024)
        var time = 0.0
        for i in 0..<200 {
            clock.submit(Self.moment(i, tempo: 60))
            time += 1
            clock.advance(to: time, into: &out)
        }
        #expect(clock.refusedNotes == 0)
        #expect(clock.starvedBeats == 0)
        #expect(out.count == 600, "three notes a moment for two hundred moments")
    }

    @Test("starving holds the pad and keeps the beat")
    func starvationHoldsThePad() {
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))
        var out: [ScheduledNote] = []
        out.reserveCapacity(64)
        clock.advance(to: 0.9, into: &out)
        out.removeAll(keepingCapacity: true)

        // Nothing more submitted: the fold has stalled. Three beats pass.
        clock.advance(to: 4.0, into: &out)
        #expect(clock.isStarving)
        #expect(clock.starvedBeats == 3)
        // PLAN.md: hold a sustained pad and let the harmony breathe.
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.note.voice == .pad })
        // And it invents nothing: a held beat has no contact onsets, because nothing formed.
        #expect(!out.contains { $0.note.voice == .contact })

        // When the fold catches up, the music resumes without a gap.
        clock.submit(Self.moment(1, tempo: 60))
        out.removeAll(keepingCapacity: true)
        clock.advance(to: 5.0, into: &out)
        #expect(!clock.isStarving)
        #expect(out.contains { $0.note.voice == .contact })
    }

    @Test("a clock that has never been fed is not starving")
    func silenceBeforeTheFirstBeatIsNotStarvation() {
        var clock = MusicalClock()
        var out: [ScheduledNote] = []
        out.reserveCapacity(8)
        clock.advance(to: 30.0, into: &out)
        #expect(out.isEmpty)
        #expect(!clock.isStarving, "not yet started is not the same as fallen behind")
        #expect(clock.starvedBeats == 0)
    }

    @Test("a seek drops what was queued for where the playhead was")
    func resetClearsTheQueue() {
        var clock = MusicalClock()
        for i in 0..<8 { clock.submit(Self.moment(i)) }
        #expect(clock.depth > 0)
        clock.reset(at: 12)
        #expect(clock.depth == 0)
        var out: [ScheduledNote] = []
        out.reserveCapacity(16)
        clock.advance(to: 12, into: &out)
        #expect(out.isEmpty, "the old notes belonged to the old playhead")
        clock.submit(Self.moment(99))
        clock.advance(to: 12, into: &out)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.time == 12 })
    }

    @Test("time going backwards is ignored, not replayed")
    func timeNeverRunsBackwards() {
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))
        var out: [ScheduledNote] = []
        out.reserveCapacity(16)
        clock.advance(to: 0.6, into: &out)
        let after = out.count
        #expect(after > 0)
        clock.advance(to: 0.1, into: &out)
        // A clock that ran backwards would have to un-sound notes already played.
        #expect(out.count == after)
        clock.advance(to: .nan, into: &out)
        #expect(out.count == after)
    }

    // MARK: - Every note the sonifier makes is playable by this clock

    @Test("a moment's notes are in beat order and all of them sound")
    func momentsAreInBeatOrder() throws {
        let style = try SonifierTests.style
        var sonifier = Sonifier(style: style,
                                residues: SonifierTests.acids("MKTAYIAKQRQISFVKSHFSRQ"))
        var states = [SecondaryStructure](repeating: .coil, count: 22)
        for i in 0..<8 { states[i] = .helix }
        for i in 8..<15 { states[i] = .sheet }
        _ = sonifier.moment(for: SonifierTests.frame(index: 0, residues: 22, structure: states))
        let produced = sonifier.moment(for: SonifierTests.frame(
            index: 1, residues: 22, structure: states,
            contacts: (0..<5).map {
                ContactEvent(i: $0, j: $0 + 12, distance: 7, isHydrophobicPair: $0 == 0)
            }))
        let moment = try #require(produced)
        #expect(moment.notes.count > 8)
        // The clock walks a moment's notes in order, so one out of order would be skipped
        // rather than merely late.
        for (a, b) in zip(moment.notes, moment.notes.dropFirst()) {
            #expect(a.beatOffset <= b.beatOffset)
        }

        var clock = MusicalClock()
        clock.submit(moment)
        var out: [ScheduledNote] = []
        out.reserveCapacity(512)
        // Advanced in small steps, well past the last onset. Held pads accumulate once the
        // moment's own beat has passed, so the assertion is that every note the moment asked
        // for was emitted - not that nothing else was.
        for step in 1...600 { clock.advance(to: Double(step) * 0.05, into: &out) }
        let emitted = Set(out.map(\.note))
        for note in moment.notes {
            #expect(emitted.contains(note), "the clock never emitted \(note.voice) at beat \(note.beatOffset)")
        }
    }

    // MARK: - The phase gate: no allocation while playing

    /// Anchors `Bundle(for:)` on the test bundle, so the probe can be found beside it.
    private final class BundleAnchor {}

    static var probeURL: URL {
        Bundle(for: BundleAnchor.self).bundleURL
            .deletingLastPathComponent()
            .appending(path: "foldaudio-probe")
    }

    @Test("the scheduler allocates nothing while playing")
    func schedulerDoesNotAllocate() throws {
        // PLAN.md's Phase 3 gate: "No audio-thread allocations detected in the scheduler
        // (assert with a test harness)." An allocation on the audio thread is a late buffer,
        // which is an audible click.
        //
        // **The measurement runs in its own process, and it has to.** Darwin's only allocation
        // counter is `malloc_zone_statistics`, which is process-wide, and swift-testing runs
        // suites in parallel - so measured from inside this process the same loop reported 2
        // blocks running alone and 8,092 blocks under a full test run. That is not a flaky
        // test, it is the wrong instrument: it was measuring the whole process.
        let probe = Self.probeURL
        try #require(FileManager.default.isExecutableFile(atPath: probe.path),
                     "the allocation harness is not built at \(probe.path)")

        let process = Process()
        process.executableURL = probe
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        // Trimmed: the trailing newline would otherwise ride along on the last field and make
        // `Int(...)` return nil for it alone.
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var reported: [String: Int] = [:]
        for field in output.split(separator: " ") {
            let parts = field.split(separator: "=")
            guard parts.count == 2, let value = Int(parts[1].split(separator: ",")[0]) else {
                continue
            }
            reported[String(parts[0])] = value
        }

        for measurement in ["play10k", "play100k", "hold10k", "hold100k"] {
            let blocks = try #require(reported[measurement],
                                      "the harness did not report \(measurement): \(output)")
            #expect(blocks == 0, "\(measurement) allocated \(blocks) blocks")
        }
        // And the harness has to have actually done the work it claims.
        // Holding is bounded per tick, so a run of 10,000 ticks that each hold once reports
        // about that many - the point is that it starved throughout, not an exact count.
        let starved = try #require(reported["starved"])
        #expect(starved >= 9_000, "the held run did not starve")
        #expect(reported["playStarved"] == 0, "the played run should never have starved")
        #expect(reported["refused"] == 0)
        let capacity = try #require(reported["capacity"])
        #expect(capacity >= 4096, "the output array was reallocated during playback")
    }
}
