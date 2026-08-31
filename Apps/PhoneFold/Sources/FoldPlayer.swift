import Foundation
import SwiftUI
import simd
import FoldCore
import FoldEngine
import FoldGeometry
import FoldRender
import FoldAudio

/// One frame, fully prepared and ready for the renderer.
///
/// Immutable and `Sendable`, so the expensive work can happen off the main actor and only
/// the finished result crosses over.
struct PreparedFrame: Sendable {
    let index: Int
    let isInterpolated: Bool
    let caPositions: [SIMD3<Float>]
    let mesh: TubeMesh
    let confidence: [Float]
    let metrics: FrameMetrics
    let structureFractions: (helix: Float, sheet: Float, coil: Float)
    let newContacts: [ContactEvent]
    let progress: Double
    let preparationMilliseconds: Double
    let recycle: Int
    let secondaryStructure: [SSAssignment]
}

/// Everything needed to redraw a frame that has already been played, minus the mesh.
///
/// The mesh is the expensive part - 62,620 vertices at 314 residues - and rebuilding it from
/// the alpha carbons costs 2.5 ms, so it is rebuilt on demand rather than kept. What is kept
/// is small: about 5 MB for the longest bundled trajectory at its largest protein, against
/// gigabytes if the meshes were held.
struct ScrubFrame: Sendable {
    let index: Int
    let progress: Double
    let isInterpolated: Bool
    let recycle: Int
    let caPositions: [SIMD3<Float>]
    let secondaryStructure: [SSAssignment]
    let confidence: [Float]
    let metrics: FrameMetrics
    let structureFractions: (helix: Float, sheet: Float, coil: Float)
}

/// Drives one fold.
///
/// **Frame production runs off the main actor.** PLAN.md requires interaction never to be
/// blocked or delayed by the fold, and the engine, the tube geometry and the metrics are the
/// expensive part. Running them on the main actor starved SwiftUI badly enough that a Debug
/// build barely advanced and a Release build showed nothing at all: the loop simply never
/// yielded long enough for the view to draw. Only the RealityKit buffer write has to be on
/// the main actor, and that stays there.
@MainActor
final class FoldPlayer: ObservableObject {

    /// Where finished frames go for drawing.
    ///
    /// **Deliberately not `@Published`.** Publishing the mesh drove a full SwiftUI
    /// re-evaluation of the whole stage - including two `Chart`s over hundreds of samples -
    /// sixty times a second, and because the producer awaits the main actor to publish, the
    /// fold ended up paced by SwiftUI's layout rather than by its own clock. The renderer
    /// takes frames straight from here and writes the vertex buffer without SwiftUI being
    /// involved at all.
    var onFrame: (@MainActor (PreparedFrame, [FlashInstance]) -> Void)?

    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    /// Secondary structure by default.
    ///
    /// Marc asked to see the elements coloured differently *as they appear*, and that is also
    /// the headline PLAN.md gives Phase 2: "secondary structure formation is the visual
    /// headline". The confidence ramp is one tap away and is still the better view of a
    /// prediction settling; it is not the better view of a protein folding.
    @Published var colourMode: ColourMode = .secondaryStructure

    /// Accessibility settings, pushed down from the view that can read the environment.
    ///
    /// **The palette existed and was unreachable.** `ColourOptions.accessiblePalette` and the
    /// amber-and-blue secondary structure colours were written in Phase 2 and nothing ever set
    /// the flag, so the only way to see them was from a unit test. A capability nobody can
    /// reach is not a feature.
    @Published var accessiblePalette = false
    /// Slower orbit and no contact flashes.
    @Published var reduceMotion = false
    /// The aurora grade off, so the stage is a flat ground rather than a gradient wash.
    @Published var reduceTransparency = false
    /// Published at `hudUpdateInterval`, not per frame: the counters and traces are read by
    /// a human and gain nothing from sixty updates a second.
    @Published private(set) var history = FoldHistory()
    @Published private(set) var meter = ComputeMeter()
    /// On-screen diagnostic. simctl's console capture returns nothing for this app, so
    /// `print` is not a usable channel here; the screen is.
    @Published private(set) var diagnostic = "idle"

    /// Whether the fold is sonified. On by default: PhoneFold is a concert.
    @Published var isSoundOn = true
    /// Which style the score is written in. Changing it mid-fold switches on the next beat.
    @Published var styleID = "fantasy" {
        didSet {
            guard styleID != oldValue, let style = styles[styleID] else { return }
            conductor?.setStyle(style)
        }
    }
    /// What the music is doing, for the HUD.
    @Published private(set) var audioDiagnostic = ""

    /// The style profiles that shipped in the bundle, loaded once.
    ///
    /// An empty library is not a crash: the app still folds and still draws, it just cannot
    /// sing, and the HUD says so rather than failing silently.
    private(set) lazy var styles: [String: StyleProfile] =
        (try? StyleLibrary.bundled()) ?? [:]
    private var conductor: ScoreConductor?

    /// Frames between HUD publishes. Six at 60 fps is ten updates a second.
    private let hudUpdateInterval = 6
    private var historyBuffer = FoldHistory()
    private var meterBuffer = ComputeMeter()
    private var lastHUDFrame = -1
    private(set) var latestFrame: PreparedFrame?

    /// Every frame played so far, so the traces can be scrubbed.
    ///
    /// The engine is deliberately **not** paused while scrubbing. It is paced to real time and
    /// finishes in about twelve seconds either way, so letting it run means the store keeps
    /// filling and the whole trajectory becomes reachable, rather than only the part that had
    /// played when the finger went down.
    private var store: [ScrubFrame] = []
    /// The store's progresses, kept alongside it.
    ///
    /// The search needs a plain `[Double]` and this runs on every movement of a finger; a
    /// `store.map(\.progress)` there would rebuild a seven-hundred-element array sixty times
    /// a second to look at one value in it.
    private var storeProgresses: [Double] = []
    /// Where the scrubber is, or nil when the display is following the live frame.
    @Published private(set) var scrubbedProgress: Double?
    /// The counters for the frame under the scrubber, so the readouts describe what is on the
    /// stage rather than where the fold has got to.
    @Published private(set) var scrubbedSample: HistorySample?
    var isScrubbing: Bool { scrubbedProgress != nil }

    private(set) var provider: (any FoldFrameProvider)?
    private var task: Task<Void, Never>?

    var confidenceSource: ConfidenceSource { provider?.confidenceSource ?? .pLDDT }
    var isGenerated: Bool { provider?.isGenerated ?? false }
    /// The claim this trajectory makes, in one line, or nil when it needs no qualification.
    var disclosure: String? { provider?.metadata.provenance.disclosure }
    var title: String { provider?.metadata.name ?? "PhoneFold" }

    /// How long to dwell on each raw readout, for a fold of about `targetSeconds`.
    ///
    /// Clamped at both ends, but loosely: the upper clamp was 1.2 s, which quietly capped an
    /// eight-readout trajectory at 8.4 s when the target said 12. It is 2.5 s now, so the
    /// target is what actually happens.
    ///
    /// Worth being clear about what a longer fold does and does not buy. One ESMFold recycle
    /// is **eight real structures** - the structure module's eight IPA layers - and stretching
    /// it only adds interpolation between the same eight. There is no denser honest sampling
    /// available: readouts taken mid-trunk were measured as geometrically broken, CA-CA
    /// distances of 5 to 18 angstroms, because the structure module is not trained to run
    /// there. A genuinely long descent with real structures at every step is what the
    /// diffusion trajectories are for - the bundled Genie 2 run is 201 of them.
    static func pace(forReadouts count: Int, targetSeconds: Float = 12) -> Float {
        let intervals = Float(Swift.max(count - 1, 1))
        return Swift.min(Swift.max(targetSeconds / intervals, 0.03), 2.5)
    }

    func play(_ provider: some FoldFrameProvider) {
        stop()
        self.provider = provider
        history.reset()
        historyBuffer.reset()
        meterBuffer = ComputeMeter()
        lastHUDFrame = -1
        latestFrame = nil
        store.removeAll(keepingCapacity: true)
        storeProgresses.removeAll(keepingCapacity: true)
        scrubbedProgress = nil
        scrubbedSample = nil
        // Playback, not inference: the app replays a precomputed trajectory, so there is no
        // compute unit to report yet. Saying so is better than implying a utilisation
        // reading that does not exist.
        meter.configure(workload: .playback, unit: .none)
        meterBuffer.configure(workload: .playback, unit: .none)
        isPlaying = true

        let residues = provider.residues
        // Pace from the trajectory's own length, so every fold takes about the same time on
        // screen whatever engine produced it.
        //
        // A fixed seconds-per-readout cannot do that: the bundled trajectories run from 8
        // readouts for one ESMFold recycle to 201 for a Genie 2 denoising run, a factor of
        // twenty-five. At the old fixed eighth of a second the first would be over in under a
        // second - not a fold, a flinch - and this is meant to be watched.
        // The score, if there is one, and the pace that lets the animation and the music
        // finish together. Without sound the trajectory keeps the twelve-second pace it had.
        let readouts = provider.readouts.count
        var conductor: ScoreConductor?
        var pace = Self.pace(forReadouts: readouts)
        if isSoundOn, let style = styles[styleID] ?? styles["fantasy"]
            ?? styles.values.sorted(by: { $0.id < $1.id }).first {
            let made = ScoreConductor(style: style, residues: residues, readouts: readouts)
            do {
                try made.start()
                conductor = made
                pace = ScoreConductor.secondsPerReadout(style: style, readouts: readouts)
                audioDiagnostic = "\(style.name), \(made.pacing.moments) bars, "
                    + String(format: "%.0f s", made.pacing.seconds(atTempo: (style.tempoSlow + style.tempoFast) / 2))
            } catch {
                audioDiagnostic = "silent: \(error)"
            }
        } else if isSoundOn {
            audioDiagnostic = "silent: no style profiles in the bundle"
        } else {
            audioDiagnostic = ""
        }
        self.conductor = conductor

        let engine = FoldEngine(configuration: .init(
            frameRate: 60,
            secondsPerRawFrame: pace,
            paced: true))

        // Detached, not a child of the main actor: a `Task {}` inside a @MainActor type
        // inherits main-actor isolation, which is exactly what starved the renderer.
        diagnostic = "starting"
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var flashPool = ContactFlashPool(frameRate: 60)
            var delivered = 0
            do {
                let sequence = try await engine.frames(for: provider)
                let total = sequence.frameCount
                await self?.note("stream total=\(total)")
                for await frame in sequence {
                    if Task.isCancelled { return }
                    // Scored before the mesh is built, so a note is never late because the
                    // geometry was slow.
                    conductor?.receive(frame)
                    let started = Date()
                    let ca = frame.backbone.map(\.ca)
                    let mesh = TubeGeometry.build(caPositions: ca,
                                                  secondaryStructure: frame.secondaryStructure)
                    let metrics = Metrics.compute(caPositions: ca, residues: residues,
                                                  confidence: frame.pLDDT)
                    flashPool.add(frame.newContacts, atFrame: frame.index)
                    flashPool.advance(to: frame.index)
                    let live = flashPool.instances(atFrame: frame.index, caPositions: ca)

                    let preparedFrame = PreparedFrame(
                        index: frame.index,
                        isInterpolated: frame.isInterpolated,
                        caPositions: ca,
                        mesh: mesh,
                        confidence: frame.pLDDT,
                        metrics: metrics,
                        structureFractions: frame.structureFractions,
                        newContacts: frame.newContacts,
                        progress: total > 1 ? Double(frame.index) / Double(total - 1) : 0,
                        preparationMilliseconds: Date().timeIntervalSince(started) * 1000,
                        recycle: frame.recycle,
                        secondaryStructure: frame.secondaryStructure)

                    delivered += 1
                    await self?.publish(preparedFrame, flashes: live)
                }
                await self?.note("done, delivered=\(delivered)")
            } catch {
                await self?.note("FAILED: \(error)")
            }
            await self?.finish()
        }
    }

    private func publish(_ frame: PreparedFrame, flashes: [FlashInstance]) {
        // The renderer first, and without touching any published state: this is the path
        // that has to keep up with the fold.
        latestFrame = frame
        store.append(ScrubFrame(
            index: frame.index, progress: frame.progress,
            isInterpolated: frame.isInterpolated, recycle: frame.recycle,
            caPositions: frame.caPositions, secondaryStructure: frame.secondaryStructure,
            confidence: frame.confidence, metrics: frame.metrics,
            structureFractions: frame.structureFractions))
        storeProgresses.append(frame.progress)
        // While the scrubber holds the stage, the live head must not draw over it.
        if !isScrubbing { onFrame?(frame, flashes) }

        historyBuffer.append(HistorySample(
            frameIndex: frame.index,
            progress: frame.progress,
            radiusOfGyration: frame.metrics.radiusOfGyration,
            compactness: frame.metrics.compactness,
            contactCount: frame.metrics.contactCount,
            meanConfidence: frame.metrics.meanConfidence,
            helixFraction: frame.structureFractions.helix,
            sheetFraction: frame.structureFractions.sheet,
            coilFraction: frame.structureFractions.coil,
            newContacts: frame.newContacts.count,
            isRawFrame: !frame.isInterpolated,
            recycle: frame.recycle))
        meterBuffer.record(frameCostMilliseconds: frame.preparationMilliseconds)

        // Publish the HUD at ten hertz, and always on the last frame so the final reading is
        // the real one rather than whatever the last multiple of six happened to be.
        let isFinal = frame.progress >= 0.999
        if isFinal || frame.index - lastHUDFrame >= hudUpdateInterval {
            lastHUDFrame = frame.index
            progress = frame.progress
            history = historyBuffer
            meter = meterBuffer
        }
    }

    // MARK: - Scrubbing

    /// Show the played frame nearest `target`, expressed as 0...1 through the trajectory.
    ///
    /// Clamped to what has actually been played: dragging past the live head holds at the
    /// newest frame rather than showing nothing, which is what makes dragging during playback
    /// feel like a scrubber rather than like a broken one.
    func scrub(to target: Double) {
        guard !store.isEmpty else { return }
        let wanted = Swift.min(Swift.max(target, 0), 1)
        scrubbedProgress = wanted
        guard let index = Scrubbing.nearestIndex(toProgress: wanted,
                                                 in: storeProgresses) else { return }
        render(store[index])
    }

    /// Hand the stage back to the live fold.
    func endScrub() {
        scrubbedProgress = nil
        scrubbedSample = nil
        if let latestFrame { onFrame?(latestFrame, []) }
    }

    /// Rebuild one stored frame's mesh and draw it.
    ///
    /// No contact flashes: they are events that happened at a moment, and replaying them
    /// under a scrubber would show flashes that are not firing now.
    private func render(_ frame: ScrubFrame) {
        let mesh = TubeGeometry.build(caPositions: frame.caPositions,
                                      secondaryStructure: frame.secondaryStructure)
        scrubbedSample = HistorySample(
            frameIndex: frame.index, progress: frame.progress,
            radiusOfGyration: frame.metrics.radiusOfGyration,
            compactness: frame.metrics.compactness,
            contactCount: frame.metrics.contactCount,
            meanConfidence: frame.metrics.meanConfidence,
            helixFraction: frame.structureFractions.helix,
            sheetFraction: frame.structureFractions.sheet,
            coilFraction: frame.structureFractions.coil,
            newContacts: 0, isRawFrame: !frame.isInterpolated, recycle: frame.recycle)
        let prepared = PreparedFrame(
            index: frame.index, isInterpolated: frame.isInterpolated,
            caPositions: frame.caPositions, mesh: mesh, confidence: frame.confidence,
            metrics: frame.metrics, structureFractions: frame.structureFractions,
            newContacts: [], progress: frame.progress, preparationMilliseconds: 0,
            recycle: frame.recycle, secondaryStructure: frame.secondaryStructure)
        onFrame?(prepared, [])
    }

    private func note(_ text: String) { diagnostic = text }

    /// What VoiceOver says about the stage.
    ///
    /// Built from the last frame rather than stored per frame: it is read on demand by the
    /// accessibility system, and computing a sentence sixty times a second for something
    /// nobody may be listening to is work for nothing.
    var stageDescription: String {
        guard let frame = latestFrame else { return "No fold is playing." }
        return StageDescription.describe(
            name: provider?.metadata.name,
            residueCount: frame.caPositions.count,
            fractions: frame.structureFractions,
            confidence: frame.metrics.meanConfidence,
            confidenceSource: provider?.confidenceSource ?? .pLDDT,
            progress: frame.progress)
    }

    /// The trajectory currently on screen, for an export to re-render from.
    ///
    /// The provider rather than the frames: a 52-second fold is about 3,100 frames and holding
    /// them would be gigabytes. The stream is deterministic, so an export rebuilds the same
    /// frames from the same provider - at its own resolution rather than the screen's.
    var exportProvider: (any FoldFrameProvider)? { provider }

    /// Styles in a stable order, for a picker that does not reshuffle itself.
    var orderedStyles: [StyleProfile] {
        // Fantasy first, because it is the default and PLAN.md's own first style; the rest
        // alphabetically, so adding one does not move the others.
        styles.values.sorted {
            $0.id == "fantasy" ? true : ($1.id == "fantasy" ? false : $0.id < $1.id)
        }
    }

    /// The score as a standard MIDI file, or nil if there is nothing to export.
    ///
    /// Built from the moments that were actually played rather than re-scored: a second pass
    /// over the same frames would give the same notes, but only because the mapping is
    /// deterministic, and exporting the thing that was heard needs no such argument.
    func midiExport() -> Data? {
        guard let conductor, !conductor.playedMoments.isEmpty else { return nil }
        return MIDIFile.encode(conductor.playedMoments, style: conductor.style)
    }

    private func finish() {
        isPlaying = false
        // The music outlives the last frame: a two-minute piece has a jitter buffer and a
        // release tail behind the playhead, and cutting it off at the last readout would end
        // every fold on a chopped chord. It stops when the buffer has drained.
        let ending = conductor
        conductor = nil
        guard let ending else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            ending.stop()
            await MainActor.run { if self?.conductor == nil { self?.audioDiagnostic = "" } }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // Stopped, not left to drain: `stop()` means a new fold is starting or the user has
        // finished with this one, and either way the old music must not still be playing
        // under the new one.
        conductor?.stop()
        conductor = nil
        audioDiagnostic = ""
        isPlaying = false
    }

    deinit { task?.cancel() }
}
