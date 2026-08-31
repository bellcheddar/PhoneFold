import Foundation
import simd
import FoldCore
import FoldAudio

/// Turns the fold that is on screen into the music that is in the ears.
///
/// It owns the one `Sonifier` for a run and the one `FoldAudioEngine`, and it is the only
/// thing that knows about both. `FoldPlayer` hands it raw frames as they are produced; it
/// scores them, hands the bars to the engine with the coordinates that go with them, and runs
/// a small scheduler that starts notes off the **audio** clock.
///
/// **The audio clock, not the UI clock.** A scheduler driven by the frame callback drifts
/// against the samples by however much the main thread is late, and a piece two minutes long
/// accumulates that drift the whole way. `AVAudioEngine`'s own render time is the only clock
/// the music can honestly be on.
final class ScoreConductor: @unchecked Sendable {

    /// How often the scheduler looks for notes that have come due.
    ///
    /// Ten milliseconds. The clock places notes to the sample, so this only bounds how late a
    /// note can be started, and 10 ms is under the threshold at which a listener hears an
    /// onset as late.
    static let tickInterval = Duration.milliseconds(10)

    /// How far ahead of the playhead bars may be queued.
    ///
    /// The fold produces readouts faster than the music consumes them, so without a limit the
    /// queue would fill and refuse. Four seconds is enough to ride out a stalled frame and
    /// short enough that a seek does not have a wall of stale music behind it.
    static let lookahead = 4.0

    private let engine: FoldAudioEngine
    private let haptics = FoldHaptics()
    private var sonifier: Sonifier
    private var scheduler: Task<Void, Never>?

    /// The virtual MIDI source, when Studio has one open. Nil on the phone, and nil on the Mac
    /// until someone asks for it: creating a MIDI endpoint makes the app appear in every DAW's
    /// device list, which is not something to do to a user who never asked.
    var midi: MIDISource?
    private var baseline: Double?
    /// Frames scored but not yet handed over, because the engine is far enough ahead.
    private var waiting: [(moment: ScoreMoment, positions: [SIMD3<Float>])] = []
    /// Haptic events waiting for their beat, with the time and beat length they belong to.
    ///
    /// Not played when the bar is queued: a bar is handed over up to four seconds before it
    /// sounds, and a tap four seconds ahead of its note is not the same event reaching two
    /// senses, it is a fault.
    private var hapticQueue: [(time: Double, beatDuration: Double, events: [HapticEvent])] = []
    /// Every moment written, in order, for the MIDI export. PLAN.md asks for a parallel event
    /// log written as the music plays, and this is it: what was heard, not a second scoring of
    /// the same frames.
    private var played: [ScoreMoment] = []
    /// A score computed up front, played in place of the one the sonifier would write.
    ///
    /// A duet is two folds merged, so it cannot be written a frame at a time from one of them.
    /// The sonifier still runs - it is the clock that decides *when* a moment falls, and the
    /// animation is paced from the same rule - but the moment that is played comes from here.
    /// Substituting rather than bypassing keeps the picture and the sound on one timeline.
    private var prepared: [ScoreMoment] = []
    private let lock = NSLock()

    private(set) var style: StyleProfile

    let pacing: Sonifier.Pacing

    init(style: StyleProfile, residues: [AminoAcid], readouts: Int) {
        self.style = style
        pacing = Sonifier.pacing(readouts: readouts, style: style)
        engine = FoldAudioEngine(style: style, residueCount: residues.count)
        sonifier = Sonifier(style: style, residues: residues,
                            beatsPerMoment: pacing.beatsPerMoment,
                            readoutsPerMoment: pacing.readoutsPerMoment)
    }

    /// How long a readout should stay on screen for the animation to finish with the music.
    ///
    /// **This is what reconciles the two clocks.** The animation has to take the same time as
    /// the piece or the music is cut off half-played, and the piece's length is set by the
    /// pacing: Marc chose about forty-five seconds on 2026-08-31, against the twelve the
    /// renderer used from Phase 2 and the two minutes one beat per readout produced.
    ///
    /// The style's midpoint tempo is used rather than the live one, because the pace has to be
    /// chosen before the fold has happened. The accelerando then runs slightly ahead of the
    /// animation early and slightly behind it late, which the jitter buffer absorbs.
    static func secondsPerReadout(style: StyleProfile, readouts: Int) -> Float {
        Float(Sonifier.pacing(readouts: readouts, style: style)
            .secondsPerReadout(readouts: readouts, style: style))
    }

    // MARK: - Transport

    func start() throws {
        try engine.start()
        haptics.start()
        baseline = nil
        scheduler = Task.detached(priority: .userInitiated) { [engine] in
            while !Task.isCancelled {
                if let now = self.playbackTime(engine) {
                    self.drain(upTo: now)
                    engine.pump(to: now)
                    self.fireHaptics(upTo: now)
                }
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Stop the audio without ending the piece. The score stops advancing on its own, because
    /// the drain below is driven by `playbackTime`, which comes from the audio clock.
    func pause() {
        engine.pause()
        midi?.allNotesOff()
    }

    func resume() {
        try? engine.resume()
    }

    func stop() {
        scheduler?.cancel()
        scheduler = nil
        engine.stop()
        haptics.stop()
        // `played` is kept: the export is of the piece that was heard, and stopping playback
        // is not a reason to forget it.
        lock.withLock { waiting.removeAll(keepingCapacity: true) }
    }

    /// Seconds since the first tick, from the audio clock.
    private func playbackTime(_ engine: FoldAudioEngine) -> Double? {
        guard let absolute = engine.audioTime else { return nil }
        return lock.withLock {
            if let baseline { return absolute - baseline }
            baseline = absolute
            return 0
        }
    }

    // MARK: - Feeding it

    /// Score one frame. Interpolated frames are ignored, as the mapping requires.
    func receive(_ frame: FoldFrame) {
        guard let written = lock.withLock({ sonifier.moment(for: frame) }) else { return }
        let positions = frame.backbone.map(\.ca)
        lock.withLock {
            let moment = prepared.isEmpty ? written : prepared.removeFirst()
            waiting.append((moment, positions))
            played.append(moment)
        }
    }

    /// Hand the conductor a score to play instead of writing one.
    func prepare(_ moments: [ScoreMoment]) {
        lock.withLock { prepared = moments }
    }

    /// The score as it was written, for export.
    var playedMoments: [ScoreMoment] { lock.withLock { played } }

    /// Hand over whatever the engine has room for.
    private func drain(upTo now: Double) {
        while true {
            guard engine.nextBeat < now + Self.lookahead else { return }
            let next: (moment: ScoreMoment, positions: [SIMD3<Float>])? = lock.withLock {
                waiting.isEmpty ? nil : waiting.removeFirst()
            }
            guard let next else { return }
            // The moment's own start time, taken before the submit that advances it.
            let start = engine.nextBeat
            engine.submit(next.moment, positions: next.positions)
            // Mirror the moment to MIDI, if a DAW is listening. Taken from the same moment and
            // the same start time the synthesiser was just given, so a recorded take lines up
            // with what was heard rather than with a second reading of the score.
            if let midi { send(next.moment, from: start, to: midi) }

            let events = HapticScore.events(for: next.moment)
            if !events.isEmpty {
                let beat = MusicalClock.beatDuration(tempo: next.moment.tempo)
                lock.withLock { hapticQueue.append((start, beat, events)) }
            }
        }
    }

    /// Mirror one moment to the virtual MIDI source.
    ///
    /// **Approximately timed, and it says so.** Each note is dispatched by sleeping until its
    /// beat, which carries the jitter of the task scheduler - a few milliseconds - where the
    /// synthesiser's own notes are placed on the audio clock exactly. That is the right trade
    /// here: a DAW quantises or nudges a recorded take anyway, and the alternative is a second
    /// sample-accurate scheduler running beside the one that already works.
    private func send(_ moment: ScoreMoment, from start: Double, to midi: MIDISource) {
        let beat = MusicalClock.beatDuration(tempo: moment.tempo)
        guard let now = playbackTime(engine) else { return }
        for note in moment.notes {
            let delay = (start + note.beatOffset * beat) - now
            let scheduled = ScheduledNote(note: note, time: start + note.beatOffset * beat,
                                          duration: note.duration * beat,
                                          timbre: moment.timbre)
            if delay <= 0 {
                midi.play(scheduled)
            } else {
                Task.detached {
                    try? await Task.sleep(for: .seconds(delay))
                    midi.play(scheduled)
                }
            }
        }
    }

    /// Play the haptics whose beat has arrived.
    private func fireHaptics(upTo now: Double) {
        let due: [(time: Double, beatDuration: Double, events: [HapticEvent])] =
            lock.withLock {
                let ready = hapticQueue.filter { $0.time <= now }
                hapticQueue.removeAll { $0.time <= now }
                // A backlog means the device stalled; playing it all at once would be a jolt
                // rather than a fold, so only the most recent bar survives a pile-up.
                return ready.count > 2 ? Array(ready.suffix(1)) : ready
            }
        for batch in due { haptics.play(batch.events, beatDuration: batch.beatDuration) }
    }

    /// Switch style mid-piece, taking effect on the next beat.
    ///
    /// PLAN.md: "Style switching is live and beat-quantised, never a restart." The next
    /// unwritten moment is by construction the next beat, so that is the switch point: the
    /// sonifier writes from there in the new style, and the engine gives notes from there the
    /// new timbres. What is already queued plays out as written.
    func setStyle(_ newStyle: StyleProfile) {
        guard newStyle.id != style.id else { return }
        style = newStyle
        let boundary = engine.nextBeat
        lock.withLock { sonifier.adopt(newStyle) }
        engine.adopt(newStyle, from: boundary)
    }

    // MARK: - What it measured about itself

    /// Where the protein is, in the listener's world. See `SpatialStage`.
    ///
    /// Passed straight through: the conductor owns the engine, and the surface that knows where
    /// the protein is standing - which is only ever visionOS - has no other way to reach it.
    func setSpatialStage(_ stage: SpatialStage) { engine.setStage(stage) }

    /// Listen to one residue and nothing else. See `FoldAudioEngine.solo(residue:)`.
    func setSolo(residue: Int?) { engine.solo(residue: residue) }

    var soundingVoices: Int { engine.soundingVoices }
    var hapticsAvailability: FoldHaptics.Availability { haptics.availability }
    var starvedBeats: Int { engine.starvedBeats }
    var droppedForPolyphony: Int { engine.droppedForPolyphony }
    var pendingBars: Int { lock.withLock { waiting.count } }
}
