import Foundation
import simd
import SwiftUI
import FoldCore
import FoldEngine

/// Runs a fold on this device and hands the result to the player.
///
/// The simulation is arithmetic, not I/O: a structure-based fold of 76 residues is tens of
/// seconds of it, and running that anywhere near the main actor would freeze the app for the
/// duration. It runs on a detached task and reports progress, because a frozen screen and a
/// slow screen look identical to someone holding a phone.
@MainActor
final class FoldRunner: ObservableObject {

    enum State: Equatable {
        case idle
        case folding(progress: Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The engine the user has chosen. Persisted for the session only.
    @Published var engine: FoldingEngine = .structureBased

    private var task: Task<Void, Never>?

    /// How long a fold runs, in integration steps.
    ///
    /// Measured on an M1 Max at 18.9 microseconds a step for 76 residues: 2,000,000 steps is
    /// a complete fold of ubiquitin - Q from 0.09 to 0.96 - and 38 seconds of arithmetic.
    /// Fewer steps is not a faster fold, it is an unfinished one: 200,000 steps stops at
    /// Q = 0.49, a chain that has collapsed but not packed.
    static let stepsForCompleteFold = 2_000_000

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Fold `reference` with the chosen engine and play the result.
    func run(reference: ReferenceStructure, engine: FoldingEngine,
             seed: UInt64 = 1, into player: FoldPlayer) {
        cancel()
        guard engine.needsReferenceStructure else {
            state = .failed("\(engine.displayName) does not fold toward a reference structure.")
            return
        }
        state = .folding(progress: 0)

        let metadata = TrajectoryMetadata(
            name: reference.name,
            sequence: reference.sequence,
            accession: reference.accession,
            provenance: engine.provenance,
            sourceModel: "on-device",
            blocksPerReadout: 1,
            recycles: 1,
            generated: ISO8601DateFormatter().string(from: Date()),
            notes: engine.provenance.disclosure)
        let residues = reference.residues
        let native = reference.caPositions
        let steps = engine == .structureBased ? Self.stepsForCompleteFold : 0

        // The progress and completion hops go back to the main actor through this box rather
        // than by capturing `self`: a detached closure cannot capture a main-actor-isolated
        // reference, and threading it through `weak self` inside the nested closure is exactly
        // the capture the compiler refuses.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .folding = self.state else { return }
                self.state = .folding(progress: fraction)
            }
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let isCancelled: @Sendable () -> Bool = { !Task.isCancelled }
            do {
                let bundle = try LiveTrajectory.fold(
                    engine: engine, native: native, metadata: metadata, residues: residues,
                    seed: seed, steps: steps > 0 ? steps : nil,
                    progress: report,
                    shouldContinue: isCancelled)
                if Task.isCancelled { return }
                let provider = try SampleTrajectoryProvider(bundle: bundle, recycles: .all)
                await MainActor.run { [weak self] in
                    self?.state = .idle
                    player.play(provider)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .failed("\(error)")
                }
            }
        }
    }
}

/// The engine picker, and what each engine actually claims.
struct EnginePicker: View {
    @Binding var engine: FoldingEngine
    /// Engines that cannot run yet, with the reason, so the UI never offers a dead control.
    let unavailable: [FoldingEngine: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(FoldingEngine.allCases, id: \.self) { candidate in
                    let blocked = unavailable[candidate]
                    Button {
                        if blocked == nil { engine = candidate }
                    } label: {
                        Text(candidate.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(engine == candidate
                                               ? Color(hex: 0x2B5CE6)
                                               : Color.white.opacity(0.08)))
                            .foregroundStyle(blocked == nil
                                             ? .white : Color.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(blocked != nil)
                }
            }
            // The engine's own description of what it does, which is also the honest limit of
            // what it claims. Shown always rather than behind a tap: the difference between
            // simulating toward a known answer and predicting one is the whole point.
            Text(unavailable[engine] ?? engine.summary)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x6B7C93))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the stage shows while a fold is being computed.
struct FoldingProgressView: View {
    let progress: Double
    let engine: FoldingEngine

    var body: some View {
        VStack(spacing: 10) {
            Text("Folding on this device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Color(hex: 0x22E5FF))
                        .frame(width: geometry.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(width: 220, height: 4)
            Text(engine.summary)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x6B7C93))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
    }
}
