import Foundation
import FoldCore

/// A note with a time on it: what the synthesiser is actually handed.
public struct ScheduledNote: Sendable, Hashable {
    public let note: NoteEvent
    /// Seconds from the start of playback.
    public let time: Double
    /// Seconds the note sounds for, its beats converted at the tempo of its own bar.
    public let duration: Double
    /// The timbre in force when this note was scheduled. Carried on the note rather than read
    /// live, because the synthesiser may reach a note some milliseconds after the clock
    /// produced it and the confidence it was written under is the one it should sound under.
    public let timbre: TimbreState

    public init(note: NoteEvent, time: Double, duration: Double, timbre: TimbreState) {
        self.note = note
        self.time = time
        self.duration = duration
        self.timbre = timbre
    }
}

/// The musical clock: a fixed-tempo scheduler in front of a jitter buffer.
///
/// PLAN.md: "**Musical clock decoupled from inference.** A fixed-tempo scheduler consumes a
/// jitter buffer of frames. If inference starves the buffer, hold a sustained pad and let the
/// harmony breathe. Never block, never glitch."
///
/// Three properties follow from that and are the whole design:
///
/// 1. **It never blocks.** `submit` returns false when the buffer is full rather than waiting,
///    and `advance` emits whatever is ready rather than waiting for what is not. Folding runs
///    on its own thread at its own pace and the music is never held up by it.
/// 2. **It never allocates while playing.** The buffer is a ring of fixed capacity, allocated
///    once. `advance` appends into a caller-owned array that the caller has reserved. Nothing
///    on the path from a tick to a note grows a collection, because an allocation on the audio
///    thread is a dropped buffer, which is an audible click.
/// 3. **Starving is a musical event, not a gap.** When the buffer runs dry the clock keeps the
///    bar turning and holds the last pad. The harmony breathes; it does not stop.
///
/// The clock is deliberately free of any audio framework. It converts bars to seconds and
/// nothing else, so it can be tested exactly rather than listened to.
public struct MusicalClock: Sendable {

    /// How many bars of music may sit between the fold and the speaker.
    ///
    /// Sized in bars rather than seconds because that is the unit the buffer holds. At the
    /// slow end of the Fantasy style, 66 BPM, a bar is 3.6 seconds, so 32 bars is nearly two
    /// minutes of slack - far more than a fold ever needs, and it costs a few kilobytes.
    public static let defaultCapacity = 32

    /// The moments waiting to be played. A ring buffer: fixed storage, allocated once.
    private var buffer: [ScoreMoment?]
    private var head = 0
    private var tail = 0
    private var count = 0

    /// The bar currently sounding, and when it started.
    private var current: ScoreMoment?
    private var barStart: Double = 0
    /// How many of the current bar's notes have already been emitted. The notes of a moment
    /// are sorted by beat, so this is a simple watermark rather than a set.
    private var emitted = 0
    /// The last real moment seen, which is what a starved bar holds.
    private var last: ScoreMoment?

    /// Bars the clock had to hold because nothing was ready. Reported, because a piece that is
    /// mostly holds is a piece whose engine cannot keep up, and that should be visible rather
    /// than merely sounding sparse.
    public private(set) var starvedBars = 0
    /// Moments refused because the buffer was full. Also reported: it means the fold is
    /// outrunning playback, which is the opposite problem and equally worth knowing.
    public private(set) var refusedMoments = 0
    /// Whether the last `advance` had nothing to play.
    public private(set) var isStarving = false

    public init(capacity: Int = MusicalClock.defaultCapacity) {
        buffer = [ScoreMoment?](repeating: nil, count: Swift.max(capacity, 2))
    }

    /// Bars waiting to be played.
    public var depth: Int { count }
    public var capacity: Int { buffer.count }

    /// Offer a bar to the buffer. Returns false if there is no room.
    ///
    /// **Never blocks and never grows.** A producer that is refused should slow down or drop
    /// its own work; it must not be allowed to make the buffer unbounded, because an unbounded
    /// buffer converts a fast fold into a growing latency between what is on screen and what
    /// is in the ears.
    @discardableResult
    public mutating func submit(_ moment: ScoreMoment) -> Bool {
        guard count < buffer.count else {
            refusedMoments += 1
            return false
        }
        buffer[tail] = moment
        tail = (tail + 1) % buffer.count
        count += 1
        return true
    }

    private mutating func dequeue() -> ScoreMoment? {
        guard count > 0 else { return nil }
        let moment = buffer[head]
        buffer[head] = nil
        head = (head + 1) % buffer.count
        count -= 1
        return moment
    }

    /// How long one bar lasts at a given tempo.
    static func barDuration(tempo: Double) -> Double {
        guard tempo > 0 else { return 1 }
        return Sonifier.beatsPerBar * 60 / tempo
    }

    /// Emit every note due at or before `time`, appending into `out`.
    ///
    /// `out` is the caller's array and is never cleared here: the caller reserves it once and
    /// empties it with `removeAll(keepingCapacity: true)` between ticks. That is what keeps the
    /// whole path free of allocation.
    ///
    /// Time is monotonic seconds from the start of playback. Going backwards is ignored rather
    /// than treated as a rewind - a scrub restarts the clock instead, because a clock that
    /// could run backwards would have to un-sound notes that had already been played.
    public mutating func advance(to time: Double, into out: inout [ScheduledNote]) {
        guard time.isFinite else { return }
        isStarving = false

        // Bounded, so a long stall cannot spin here: a tick that has fallen many bars behind
        // catches up over the next few ticks rather than emitting a minute of music at once.
        for _ in 0..<Swift.max(buffer.count, 1) {
            if current == nil {
                if let next = dequeue() {
                    current = next
                    last = next
                    emitted = 0
                } else if let held = last, time >= barStart + Self.barDuration(tempo: held.tempo) {
                    // Starved. Keep the bar turning and hold the pad: PLAN.md asks for the
                    // harmony to breathe rather than for the music to stop.
                    barStart += Self.barDuration(tempo: held.tempo)
                    starvedBars += 1
                    isStarving = true
                    hold(held, into: &out)
                    continue
                } else {
                    // Nothing queued, but the current bar has not run out either. That is not
                    // starvation - the bar has simply not finished yet - and reporting it as
                    // starvation would mark every tick that lands on a downbeat.
                    return
                }
            }
            guard let moment = current else { return }
            let bar = Self.barDuration(tempo: moment.tempo)
            let beat = bar / Sonifier.beatsPerBar

            while emitted < moment.notes.count {
                let note = moment.notes[emitted]
                let onset = barStart + note.beatOffset * beat
                guard onset <= time else { break }
                out.append(ScheduledNote(note: note, time: onset,
                                         duration: note.duration * beat,
                                         timbre: moment.timbre))
                emitted += 1
            }

            guard time >= barStart + bar else { return }
            barStart += bar
            current = nil
        }
    }

    /// A held bar: the pad only, sustained for the whole bar. No onsets, because nothing
    /// happened - the fold has not produced a new frame, and inventing contact events to fill
    /// the silence would be inventing structure.
    private mutating func hold(_ moment: ScoreMoment, into out: inout [ScheduledNote]) {
        let bar = Self.barDuration(tempo: moment.tempo)
        let beat = bar / Sonifier.beatsPerBar
        for note in moment.notes where note.voice == .pad {
            out.append(ScheduledNote(note: note, time: barStart,
                                     duration: Sonifier.beatsPerBar * beat,
                                     timbre: moment.timbre))
        }
    }

    /// Drop everything and restart the clock at a given time.
    ///
    /// Used when the transport seeks. The buffered bars belong to where the playhead *was*,
    /// and playing them after a seek would be playing the wrong part of the protein.
    public mutating func reset(at time: Double = 0) {
        for i in buffer.indices { buffer[i] = nil }
        head = 0
        tail = 0
        count = 0
        current = nil
        last = nil
        emitted = 0
        barStart = time
        isStarving = false
    }
}
