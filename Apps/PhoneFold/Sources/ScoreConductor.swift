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
    private var sonifier: Sonifier
    private var scheduler: Task<Void, Never>?
    private var baseline: Double?
    /// Frames scored but not yet handed over, because the engine is far enough ahead.
    private var waiting: [(moment: ScoreMoment, positions: [SIMD3<Float>])] = []
    private let lock = NSLock()

    let style: StyleProfile

    init(style: StyleProfile, residues: [AminoAcid], readouts: Int) {
        self.style = style
        engine = FoldAudioEngine(style: style, residueCount: residues.count)
        sonifier = Sonifier(style: style, residues: residues,
                            beatsPerMoment: Sonifier.beatsPerMoment(forReadouts: readouts))
    }

    /// How long a readout should stay on screen for the animation to finish with the music.
    ///
    /// **This is what reconciles the two clocks, and it is why a live fold now takes about two
    /// minutes rather than twelve seconds.** The score gives a readout one beat, so its length
    /// is a tempo away from being fixed; the animation has to take the same time or the piece
    /// is cut off half-played. Measured: at 12 s a 180-readout fold showed fifteen readouts a
    /// second and its music ran 122 s.
    ///
    /// The style's midpoint tempo is used rather than the live one, because the pace has to be
    /// chosen before the fold has happened. The accelerando then runs slightly ahead of the
    /// animation early and slightly behind it late, which the jitter buffer absorbs.
    static func secondsPerReadout(style: StyleProfile, readouts: Int) -> Float {
        let tempo = (style.tempoSlow + style.tempoFast) / 2
        let beats = Sonifier.beatsPerMoment(forReadouts: readouts)
        return Float(beats * 60 / Swift.max(tempo, 1))
    }

    // MARK: - Transport

    func start() throws {
        try engine.start()
        baseline = nil
        scheduler = Task.detached(priority: .userInitiated) { [engine] in
            while !Task.isCancelled {
                if let now = self.playbackTime(engine) {
                    self.drain(upTo: now)
                    engine.pump(to: now)
                }
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func stop() {
        scheduler?.cancel()
        scheduler = nil
        engine.stop()
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
        guard let moment = lock.withLock({ sonifier.moment(for: frame) }) else { return }
        let positions = frame.backbone.map(\.ca)
        lock.withLock { waiting.append((moment, positions)) }
    }

    /// Hand over whatever the engine has room for.
    private func drain(upTo now: Double) {
        while true {
            guard engine.nextBeat < now + Self.lookahead else { return }
            let next: (moment: ScoreMoment, positions: [SIMD3<Float>])? = lock.withLock {
                waiting.isEmpty ? nil : waiting.removeFirst()
            }
            guard let next else { return }
            engine.submit(next.moment, positions: next.positions)
        }
    }

    // MARK: - What it measured about itself

    var soundingVoices: Int { engine.soundingVoices }
    var starvedBeats: Int { engine.starvedBeats }
    var droppedForPolyphony: Int { engine.droppedForPolyphony }
    var pendingBars: Int { lock.withLock { waiting.count } }
}
