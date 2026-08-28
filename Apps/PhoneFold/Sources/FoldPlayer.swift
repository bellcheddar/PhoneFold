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

    @Published private(set) var prepared: PreparedFrame?
    @Published private(set) var flashes: [FlashInstance] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published var colourMode: ColourMode = .confidence
    @Published private(set) var history = FoldHistory()
    @Published private(set) var meter = ComputeMeter()
    /// On-screen diagnostic. simctl's console capture returns nothing for this app, so
    /// `print` is not a usable channel here; the screen is.
    @Published private(set) var diagnostic = "idle"

    private(set) var provider: (any FoldFrameProvider)?
    private var task: Task<Void, Never>?

    var mesh: TubeMesh? { prepared?.mesh }
    var confidence: [Float] { prepared?.confidence ?? [] }
    var confidenceSource: ConfidenceSource { provider?.confidenceSource ?? .pLDDT }
    var isGenerated: Bool { provider?.isGenerated ?? false }
    var title: String { provider?.metadata.name ?? "PhoneFold" }

    func play(_ provider: some FoldFrameProvider) {
        stop()
        self.provider = provider
        history.reset()
        // Playback, not inference: the app replays a precomputed trajectory, so there is no
        // compute unit to report yet. Saying so is better than implying a utilisation
        // reading that does not exist.
        meter.configure(workload: .playback, unit: .none)
        isPlaying = true

        let residues = provider.residues
        let engine = FoldEngine(configuration: .init(frameRate: 60,
                                                     secondsPerRawFrame: 1.0 / 8.0,
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
                        preparationMilliseconds: Date().timeIntervalSince(started) * 1000)

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
        self.prepared = frame
        self.flashes = flashes
        self.progress = frame.progress
        self.history.append(HistorySample(
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
            isRawFrame: !frame.isInterpolated))
        self.meter.record(frameCostMilliseconds: frame.preparationMilliseconds)
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
