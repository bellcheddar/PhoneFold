import Testing
import Foundation
import Darwin
@testable import FoldAudio
import FoldCore

/// The musical clock: fixed tempo, a bounded jitter buffer, and no allocation while playing.
/// Serialised because two of these tests measure the process's malloc block count, which is
/// process-wide: another test allocating on another thread would be counted as this one's.
@Suite("Musical clock", .serialized)
struct MusicalClockTests {

    static func note(_ voice: Voice, beat: Double, pitch: UInt8 = 60,
                     residue: Int = 0) -> NoteEvent {
        NoteEvent(voice: voice, note: MIDINote(pitch: pitch, velocity: 90),
                  residue: residue, beatOffset: beat, duration: 1)
    }

    static func moment(_ index: Int, tempo: Double = 60, notes: [NoteEvent]? = nil,
                       degree: Int = 0) -> ScoreMoment {
        ScoreMoment(frameIndex: index, tempo: tempo,
                    notes: notes ?? [note(.contact, beat: 0), note(.pad, beat: 0),
                                     note(.rhythm, beat: 2)],
                    timbre: Sonifier.timbre(meanConfidence: 80),
                    degree: degree, isCadence: false, isModulation: false,
                    compaction: 0.5, droppedContacts: 0)
    }

    // MARK: - Time

    @Test("a bar lasts as long as its tempo says")
    func barDuration() {
        // Four beats at 60 BPM is four seconds; at 120, two.
        #expect(MusicalClock.barDuration(tempo: 60) == 4)
        #expect(MusicalClock.barDuration(tempo: 120) == 2)
        // A nonsense tempo must not divide by zero into an infinite bar.
        #expect(MusicalClock.barDuration(tempo: 0).isFinite)
        #expect(MusicalClock.barDuration(tempo: -30).isFinite)
    }

    @Test("notes come out at the times their beats ask for")
    func notesLandOnTheirBeats() {
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))
        var out: [ScheduledNote] = []
        out.reserveCapacity(64)

        clock.advance(to: 0, into: &out)
        #expect(out.count == 2, "the two notes on beat one, and nothing later")
        clock.advance(to: 1.9, into: &out)
        #expect(out.count == 2, "beat three has not arrived")
        clock.advance(to: 2.0, into: &out)
        #expect(out.count == 3)
        #expect(out.last?.time == 2.0)
        // One beat at 60 BPM is one second, so a one-beat note lasts one second.
        #expect(out.last?.duration == 1.0)
    }

    @Test("tempo is honoured per bar, not fixed for the piece")
    func tempoIsPerBar() {
        // The accelerando means each bar has its own length; a clock that assumed one tempo
        // would drift further out of step with the fold on every bar.
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))    // 4 seconds
        clock.submit(Self.moment(1, tempo: 120))   // 2 seconds
        var out: [ScheduledNote] = []
        out.reserveCapacity(64)
        clock.advance(to: 4.0, into: &out)
        // The second bar's downbeat is at 4 seconds, not at 8.
        let second = out.filter { $0.time == 4.0 }
        #expect(!second.isEmpty)
        clock.advance(to: 5.0, into: &out)
        // And its beat three is at 5 seconds, half a bar in at double tempo.
        #expect(out.contains { $0.time == 5.0 })
    }

    // MARK: - The buffer

    @Test("a full buffer refuses rather than growing")
    func bufferIsBounded() {
        var clock = MusicalClock(capacity: 4)
        // `#expect` wraps its argument in a closure, so a mutating call is taken into a
        // local first.
        for i in 0..<4 {
            let accepted = clock.submit(Self.moment(i))
            #expect(accepted)
        }
        // An unbounded buffer would turn a fast fold into a growing gap between what is on
        // screen and what is in the ears.
        let refused = clock.submit(Self.moment(4))
        #expect(!refused)
        #expect(clock.depth == 4)
        #expect(clock.refusedMoments == 1)
    }

    @Test("the ring wraps rather than filling up permanently")
    func ringWraps() {
        var clock = MusicalClock(capacity: 4)
        var out: [ScheduledNote] = []
        out.reserveCapacity(256)
        var time = 0.0
        // Twelve bars through a four-bar buffer: it has to wrap three times.
        for i in 0..<12 {
            let accepted = clock.submit(Self.moment(i, tempo: 60))
            #expect(accepted)
            time += 4
            clock.advance(to: time, into: &out)
        }
        #expect(clock.refusedMoments == 0)
        #expect(clock.starvedBars == 0)
        #expect(out.count == 36, "three notes a bar for twelve bars")
    }

    @Test("starving holds the pad and keeps the bar turning")
    func starvationHoldsThePad() {
        var clock = MusicalClock()
        clock.submit(Self.moment(0, tempo: 60))
        var out: [ScheduledNote] = []
        out.reserveCapacity(64)
        clock.advance(to: 4.0, into: &out)
        out.removeAll(keepingCapacity: true)

        // Nothing more submitted: the fold has stalled. Three bars pass.
        clock.advance(to: 16.0, into: &out)
        #expect(clock.isStarving)
        #expect(clock.starvedBars == 3)
        // PLAN.md: hold a sustained pad and let the harmony breathe.
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.note.voice == .pad })
        // And it invents nothing: a held bar has no contact onsets, because no contact formed.
        #expect(!out.contains { $0.note.voice == .contact })
        #expect(out.allSatisfy { $0.duration == 4.0 }, "held for the whole bar")

        // When the fold catches up, the music resumes on the next bar without a gap.
        clock.submit(Self.moment(1, tempo: 60))
        out.removeAll(keepingCapacity: true)
        clock.advance(to: 20.0, into: &out)
        #expect(!clock.isStarving)
        #expect(out.contains { $0.note.voice == .contact })
    }

    @Test("a clock that has never been fed is not starving")
    func silenceBeforeTheFirstBarIsNotStarvation() {
        var clock = MusicalClock()
        var out: [ScheduledNote] = []
        out.reserveCapacity(8)
        clock.advance(to: 30.0, into: &out)
        #expect(out.isEmpty)
        #expect(!clock.isStarving, "not yet started is not the same as fallen behind")
        #expect(clock.starvedBars == 0)
    }

    @Test("a seek drops what was queued for where the playhead was")
    func resetClearsTheBuffer() {
        var clock = MusicalClock()
        for i in 0..<8 { clock.submit(Self.moment(i)) }
        clock.reset(at: 12)
        #expect(clock.depth == 0)
        var out: [ScheduledNote] = []
        out.reserveCapacity(16)
        clock.advance(to: 12, into: &out)
        #expect(out.isEmpty, "the old bars belonged to the old playhead")
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
        clock.advance(to: 2.0, into: &out)
        let after = out.count
        clock.advance(to: 0.5, into: &out)
        // A clock that ran backwards would have to un-sound notes already played.
        #expect(out.count == after)
        clock.advance(to: .nan, into: &out)
        #expect(out.count == after)
    }

    // MARK: - Every note the sonifier makes is playable by this clock

    @Test("a moment's notes are in beat order")
    func momentsAreInBeatOrder() throws {
        // The clock walks a bar with a single watermark, so a note out of order would be
        // skipped rather than merely late - and a pad written after the contacts would never
        // sound at all.
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
        for (a, b) in zip(moment.notes, moment.notes.dropFirst()) {
            #expect(a.beatOffset <= b.beatOffset)
        }

        // And the clock emits all of them, none skipped.
        var clock = MusicalClock()
        clock.submit(moment)
        var out: [ScheduledNote] = []
        out.reserveCapacity(256)
        clock.advance(to: MusicalClock.barDuration(tempo: moment.tempo), into: &out)
        #expect(out.count == moment.notes.count)
    }

    // MARK: - The phase gate: no allocation while playing

    /// Anchors `Bundle(for:)` on the test bundle, so the probe can be found beside it.
    private final class BundleAnchor {}

    /// The allocation harness, built as `foldaudio-probe` alongside the test bundle.
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
        // test, it is the wrong instrument: it was measuring the whole process. In a process
        // that is doing nothing else, a delta is the scheduler's.
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

        // Trimmed: the trailing newline would otherwise ride along on the last field and
        // make `Int(...)` return nil for it alone.
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

        // Playing, and holding a starved bar - the path that runs when the device is under
        // load, and so the one where an allocation would be least affordable.
        for measurement in ["play10k", "play100k", "hold10k", "hold100k"] {
            let blocks = try #require(reported[measurement],
                                      "the harness did not report \(measurement); it said: \(output)")
            #expect(blocks == 0, "\(measurement) allocated \(blocks) blocks")
        }
        // And the harness has to have actually done the work it claims.
        #expect(reported["starved"] == 10_000, "the held run did not starve")
        #expect(reported["playStarved"] == 0, "the played run should never have starved")
        #expect(reported["refused"] == 0)
        let capacity = try #require(reported["capacity"])
        #expect(capacity >= 4096, "the output array was reallocated during playback")
    }
}
