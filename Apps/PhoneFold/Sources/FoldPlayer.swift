import Foundation
import SwiftUI
import simd
import FoldCore
import FoldEngine
import FoldGeometry
import FoldRender

/// Drives one fold: pulls frames from the engine and publishes what the stage should draw.
///
/// The engine's stream is pull-based, so this consumes it at whatever rate the display can
/// keep up with and no frame is ever dropped. If the device slows down, the fold slows down.
@MainActor
final class FoldPlayer: ObservableObject {

    @Published private(set) var frame: FoldFrame?
    @Published private(set) var mesh: TubeMesh?
    @Published private(set) var flashes: [FlashInstance] = []
    @Published private(set) var metrics: FrameMetrics?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published var colourMode: ColourMode = .confidence

    private(set) var provider: (any FoldFrameProvider)?
    private var task: Task<Void, Never>?
    private var flashPool = ContactFlashPool()

    var confidenceSource: ConfidenceSource {
        provider?.confidenceSource ?? .pLDDT
    }
    var isGenerated: Bool { provider?.isGenerated ?? false }
    var title: String { provider?.metadata.name ?? "PhoneFold" }

    func play(_ provider: some FoldFrameProvider) {
        stop()
        self.provider = provider
        flashPool = ContactFlashPool(frameRate: 60)
        isPlaying = true

        let engine = FoldEngine(configuration: .init(frameRate: 60,
                                                     secondsPerRawFrame: 1.0 / 8.0,
                                                     paced: true))
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sequence = try await engine.frames(for: provider)
                let total = sequence.frameCount
                for await frame in sequence {
                    if Task.isCancelled { break }
                    self.consume(frame, of: total, residues: provider.residues)
                }
            } catch {
                print("fold failed: \(error)")
            }
            self.isPlaying = false
        }
    }

    private func consume(_ frame: FoldFrame, of total: Int, residues: [AminoAcid]) {
        let ca = frame.backbone.map(\.ca)

        flashPool.add(frame.newContacts, atFrame: frame.index)
        flashPool.advance(to: frame.index)

        self.frame = frame
        self.mesh = TubeGeometry.build(caPositions: ca,
                                       secondaryStructure: frame.secondaryStructure)
        self.flashes = flashPool.instances(atFrame: frame.index, caPositions: ca)
        self.metrics = Metrics.compute(caPositions: ca, residues: residues,
                                       confidence: frame.pLDDT)
        self.progress = total > 1 ? Double(frame.index) / Double(total - 1) : 0
    }

    func stop() {
        task?.cancel()
        task = nil
        isPlaying = false
    }

    deinit { task?.cancel() }
}
