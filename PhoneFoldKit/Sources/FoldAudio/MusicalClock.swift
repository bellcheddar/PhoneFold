import Foundation
import FoldCore

/// A note with a time on it: what the synthesiser is actually handed.
public struct ScheduledNote: Sendable, Hashable {
    public let note: NoteEvent
    /// Seconds from the start of playback.
    public let time: Double
    /// Seconds the note sounds for, its beats converted at the tempo of its own moment.
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

/// The musical clock: a tempo-driven scheduler in front of a bounded note queue.
///
/// PLAN.md: "**Musical clock decoupled from inference.** A fixed-tempo scheduler consumes a
/// jitter buffer of frames. If inference starves the buffer, hold a sustained pad and let the
/// harmony breathe. Never block, never glitch."
///
/// Three properties follow from that and are the whole design:
///
/// 1. **It never blocks.** `submit` returns false when the queue is full rather than waiting,
///    and `advance` emits whatever is due rather than waiting for what is not. Folding runs on
///    its own thread at its own pace and the music is never held up by it.
/// 2. **It never allocates while playing.** The queue is a fixed array, allocated once, and
///    `advance` appends into a caller-owned buffer the caller has reserved. An allocation on
///    the audio thread is a dropped buffer, which is an audible click.
/// 3. **Starving is a musical event, not a gap.** When nothing arrives in time the clock keeps
///    the beat and holds the last pad. The harmony breathes; it does not stop.
///
/// **Why a queue of absolute times rather than a bar at a time.** One raw readout is one
/// *beat*, and a beat's worth of contacts is spread across four semiquavers - so a flurry of
/// sixteen runs four beats past the readout that produced it and overlaps the three after it.
/// A scheduler that held one bar at a time would have to throw that tail away. Notes are
/// therefore placed on an absolute timeline as they are submitted, and `advance` emits
/// whatever is due, whichever moment it came from.
///
/// The clock is deliberately free of any audio framework: it converts beats to seconds and
/// nothing else, so it can be tested exactly rather than listened to.
public struct MusicalClock: Sendable {

    /// How many notes may be waiting at once.
    ///
    /// A moment produces at most sixteen contacts and about a dozen texture notes, and a
    /// contact flurry overlaps three or four moments, so a hundred and twenty-eight is several
    /// times the worst case and costs a few kilobytes.
    public static let defaultCapacity = 128

    private var pending: [ScheduledNote]
    private var pendingCount = 0

    /// When the next submitted moment begins, in seconds from the start of playback.
    private var nextMomentTime: Double = 0
    /// The last moment seen, which is what a starved beat holds.
    private var last: ScoreMoment?
    private var now: Double = 0

    /// The most beats one `advance` may hold for.
    ///
    /// A long stall catches up over the next few ticks rather than filling the queue with a
    /// minute of pad in a single call - which is what an unbounded catch-up did: advancing
    /// sixty seconds after one moment held until the queue was full and refused the rest.
    static let maximumHeldBeatsPerTick = 8

    /// Beats the clock had to hold because nothing was ready. Reported, because a piece that
    /// is mostly holds is a piece whose engine cannot keep up, and that should be visible
    /// rather than merely sounding sparse.
    public private(set) var starvedBeats = 0
    /// Notes refused because the queue was full. Also reported: it means the fold is outrunning
    /// playback, which is the opposite problem and equally worth knowing.
    public private(set) var refusedNotes = 0
    /// Whether the last `advance` had to hold.
    public private(set) var isStarving = false

    public init(capacity: Int = MusicalClock.defaultCapacity) {
        pending = [ScheduledNote](repeating: ScheduledNote(
            note: NoteEvent(voice: .pad, note: MIDINote(pitch: 60, velocity: 1), residue: 0),
            time: 0, duration: 0, timbre: TimbreState(cutoff: 1, detuneCents: 0, reverb: 0)),
            count: Swift.max(capacity, 8))
    }

    /// Notes waiting to be played.
    public var depth: Int { pendingCount }
    public var capacity: Int { pending.count }
    /// When the next submitted moment will begin.
    public var nextBeat: Double { nextMomentTime }

    /// How long one beat lasts at a given tempo.
    public static func beatDuration(tempo: Double) -> Double {
        guard tempo > 0, tempo.isFinite else { return 1 }
        return 60 / tempo
    }

    /// How long one moment lasts at a given tempo.
    public static func momentDuration(tempo: Double) -> Double {
        beatDuration(tempo: tempo) * Sonifier.beatsPerMoment
    }

    /// Place a moment's notes on the timeline. Returns false if any had to be refused.
    ///
    /// **Never blocks and never grows.** A producer that is refused should slow down; it must
    /// not be allowed to make the queue unbounded, because an unbounded queue converts a fast
    /// fold into a growing latency between what is on screen and what is in the ears.
    @discardableResult
    public mutating func submit(_ moment: ScoreMoment) -> Bool {
        let beat = Self.beatDuration(tempo: moment.tempo)
        var accepted = true
        for note in moment.notes {
            guard pendingCount < pending.count else {
                refusedNotes += 1
                accepted = false
                continue
            }
            pending[pendingCount] = ScheduledNote(
                note: note,
                time: nextMomentTime + note.beatOffset * beat,
                duration: Swift.max(note.duration, 0.01) * beat,
                timbre: moment.timbre)
            pendingCount += 1
        }
        nextMomentTime += Self.momentDuration(tempo: moment.tempo)
        last = moment
        return accepted
    }

    /// Emit every note due at or before `time`, appending into `out`.
    ///
    /// `out` is the caller's array and is never cleared here: the caller reserves it once and
    /// empties it with `removeAll(keepingCapacity: true)` between ticks. That is what keeps the
    /// whole path free of allocation.
    ///
    /// Time is monotonic seconds from the start of playback. Going backwards is ignored rather
    /// than treated as a rewind - a scrub resets the clock instead, because a clock that could
    /// run backwards would have to un-sound notes that had already been played.
    public mutating func advance(to time: Double, into out: inout [ScheduledNote]) {
        guard time.isFinite, time >= now else { return }
        now = time
        isStarving = false

        // Hold, if the fold has not kept up. Bounded, so a long stall catches up over the next
        // few ticks rather than emitting a minute of music at once.
        if let held = last {
            // Strictly past, not merely at. A producer that submits a moment and then advances
            // the playhead to exactly that moment's end has not fallen behind - it is on time -
            // and treating the boundary as starvation marked every such tick.
            var beats = 0
            while now > nextMomentTime, beats < Self.maximumHeldBeatsPerTick {
                beats += 1
                starvedBeats += 1
                isStarving = true
                hold(held)
                nextMomentTime += Self.momentDuration(tempo: held.tempo)
            }
        }

        // Everything due, whichever moment it came from. A linear scan over a fixed array: the
        // overlap between a contact flurry and the moments after it means the queue is not in
        // time order, and sorting it would be work on the audio thread for no audible gain.
        var index = 0
        while index < pendingCount {
            if pending[index].time <= now {
                out.append(pending[index])
                pendingCount -= 1
                pending[index] = pending[pendingCount]
            } else {
                index += 1
            }
        }
    }

    /// A held beat: the pad only, sustained. No onsets, because nothing happened - the fold has
    /// not produced a new readout, and inventing contact events to fill the silence would be
    /// inventing structure.
    private mutating func hold(_ moment: ScoreMoment) {
        let beat = Self.beatDuration(tempo: moment.tempo)
        for note in moment.notes where note.voice == .pad {
            guard pendingCount < pending.count else {
                refusedNotes += 1
                return
            }
            pending[pendingCount] = ScheduledNote(
                note: note, time: nextMomentTime,
                duration: Sonifier.beatsPerBar * beat, timbre: moment.timbre)
            pendingCount += 1
        }
    }

    /// Drop everything and restart the clock at a given time.
    ///
    /// Used when the transport seeks. The queued notes belong to where the playhead *was*, and
    /// playing them after a seek would be playing the wrong part of the protein.
    public mutating func reset(at time: Double = 0) {
        pendingCount = 0
        last = nil
        now = time
        nextMomentTime = time
        isStarving = false
    }
}
