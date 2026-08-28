import Foundation
import SwiftUI
import simd
import FoldCore
import FoldEngine
import FoldGeometry
import FoldRender

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
    /// Published at `hudUpdateInterval`, not per frame: the counters and traces are read by
    /// a human and gain nothing from sixty updates a second.
    @Published private(set) var history = FoldHistory()
    @Published private(set) var meter = ComputeMeter()
    /// On-screen diagnostic. simctl's console capture returns nothing for this app, so
    /// `print` is not a usable channel here; the screen is.
    @Published private(set) var diagnostic = "idle"

    /// Frames between HUD publishes. Six at 60 fps is ten updates a second.
    private let hudUpdateInterval = 6
    private var historyBuffer = FoldHistory()
    private var meterBuffer = ComputeMeter()
    private var lastHUDFrame = -1
    private(set) var latestFrame: PreparedFrame?

    private(set) var provider: (any FoldFrameProvider)?
    private var task: Task<Void, Never>?

    var confidenceSource: ConfidenceSource { provider?.confidenceSource ?? .pLDDT }
    var isGenerated: Bool { provider?.isGenerated ?? false }
    var title: String { provider?.metadata.name ?? "PhoneFold" }

    /// How long to dwell on each raw readout, for a fold of about `targetSeconds`.
    ///
    /// Clamped at both ends: too fast and the interpolation has nothing to work with, too
    /// slow and a short trajectory drifts rather than folds.
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
        return Swift.min(Swift.max(targetSeconds / intervals, 0.03), 1.2)
    }

    func play(_ provider: some FoldFrameProvider) {
        stop()
        self.provider = provider
        history.reset()
        historyBuffer.reset()
        meterBuffer = ComputeMeter()
        lastHUDFrame = -1
        latestFrame = nil
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
        let engine = FoldEngine(configuration: .init(
            frameRate: 60,
            secondsPerRawFrame: Self.pace(forReadouts: provider.readouts.count),
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
                        recycle: frame.recycle)

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
        onFrame?(frame, flashes)

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

    private func note(_ text: String) { diagnostic = text }

    private func finish() { isPlaying = false }

    func stop() {
        task?.cancel()
        task = nil
        isPlaying = false
    }

    deinit { task?.cancel() }
}
