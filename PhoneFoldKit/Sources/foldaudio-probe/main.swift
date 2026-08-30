import Foundation
import Darwin
import FoldAudio

// A harness for PLAN.md's Phase 3 gate: "No audio-thread allocations detected in the
// scheduler (assert with a test harness)."
//
// **It has to be its own process.** The only allocation counter Darwin exposes is
// `malloc_zone_statistics`, which is process-wide, and swift-testing runs suites in parallel -
// so measured from inside the test process the figure is dominated by whatever else is running
// at that moment. Measured that way the same loop reported 2 blocks alone and 8,092 blocks
// under a full test run. Here nothing else is running, so a delta is the scheduler's.

func blocks() -> Int64 {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return Int64(stats.blocks_in_use)
}

func moment(_ index: Int, tempo: Double = 120) -> ScoreMoment {
    let notes = [
        NoteEvent(voice: .contact, note: MIDINote(pitch: 60, velocity: 90), residue: 0,
                  beatOffset: 0, duration: 1),
        NoteEvent(voice: .pad, note: MIDINote(pitch: 55, velocity: 70), residue: 1,
                  beatOffset: 0, duration: 4),
        NoteEvent(voice: .rhythm, note: MIDINote(pitch: 67, velocity: 80), residue: 2,
                  beatOffset: 2, duration: 0.2),
    ]
    return ScoreMoment(frameIndex: index, tempo: tempo, notes: notes,
                       timbre: Sonifier.timbre(meanConfidence: 80), degree: 0,
                       isCadence: false, isModulation: false, compaction: 0.5,
                       droppedContacts: 0)
}

let moments = (0..<64).map { moment($0) }

/// Play `bars` bars, feeding the buffer as fast as it drains.
func play(bars: Int) -> (starved: Int, refused: Int, capacity: Int) {
    var clock = MusicalClock(capacity: 64)
    var out: [ScheduledNote] = []
    out.reserveCapacity(4096)
    var time = 0.0
    for i in 0..<bars {
        clock.submit(moments[i % moments.count])
        time += 2
        clock.advance(to: time, into: &out)
        out.removeAll(keepingCapacity: true)
    }
    return (clock.starvedBars, clock.refusedMoments, out.capacity)
}

/// Play one bar and then let the buffer run dry for `bars` bars.
func hold(bars: Int) -> Int {
    var clock = MusicalClock(capacity: 8)
    var out: [ScheduledNote] = []
    out.reserveCapacity(4096)
    clock.submit(moment(0))
    var time = 2.0
    clock.advance(to: time, into: &out)
    out.removeAll(keepingCapacity: true)
    for _ in 0..<bars {
        time += 2
        clock.advance(to: time, into: &out)
        out.removeAll(keepingCapacity: true)
    }
    return clock.starvedBars
}

// Warm each path first. The first bulk pass through a code path costs a few hundred blocks
// once and never again - runtime warm-up, not the scheduler - so measuring it would be
// asserting something untrue about the runtime rather than something true about the code.
_ = play(bars: 10_000)
_ = hold(bars: 10_000)

var line: [String] = []

var mark = blocks()
let playedTen = play(bars: 10_000)
line.append("play10k=\(blocks() - mark)")
mark = blocks()
let playedHundred = play(bars: 100_000)
line.append("play100k=\(blocks() - mark)")

mark = blocks()
let heldTen = hold(bars: 10_000)
line.append("hold10k=\(blocks() - mark)")
mark = blocks()
let heldHundred = hold(bars: 100_000)
line.append("hold100k=\(blocks() - mark)")

line.append("starved=\(heldTen),\(heldHundred)")
line.append("playStarved=\(playedTen.starved),\(playedHundred.starved)")
line.append("refused=\(playedTen.refused),\(playedHundred.refused)")
line.append("capacity=\(playedTen.capacity)")
print(line.joined(separator: " "))
