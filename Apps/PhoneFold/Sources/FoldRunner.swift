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
        case fetching(accession: String)
        case folding(progress: Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The engine the user has chosen. Persisted for the session only.
    @Published var engine: FoldingEngine = .structureBased

    private var task: Task<Void, Never>?
    private let alphaFold = AlphaFoldClient()

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

    /// Fetch a structure from AlphaFold by accession, then fold toward it.
    ///
    /// Two steps that can each fail for different reasons, reported separately: an accession
    /// that has no prediction is a different problem from a network that is not there, and
    /// telling a user "could not fold" for either would be useless.
    func fetchAndRun(accession: String, engine: FoldingEngine, into player: FoldPlayer) {
        cancel()
        let trimmed = accession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .fetching(accession: trimmed.uppercased())
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let reference = try await self.alphaFold.reference(for: trimmed)
                guard !Task.isCancelled else { return }
                self.run(reference: reference, engine: engine, into: player)
            } catch {
                self.state = .failed("\(error)")
            }
        }
    }

    /// Generate a backbone with Genie 2, on the device.
    ///
    /// Nothing is folded toward here: the model starts from Gaussian noise and arrives at a
    /// backbone that has never existed. The protein has no name, no sequence and no reference,
    /// which is why it takes a different path from the other two engines rather than sharing
    /// theirs with a nil target.
    /// - Parameter seed: **3, not 1.** Seeds 1 and 2 are measured to diverge, and although the
    ///   sampler retries with the next seed, each wasted attempt is a thousand denoising steps
    ///   - half a minute on a Mac and several minutes on a phone. Starting from a draw that is
    ///   known to complete costs nothing and saves the user two of those.
    func generate(seed: UInt64 = 3, into player: FoldPlayer) {
        cancel()
        state = .folding(progress: 0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .folding = self.state else { return }
                self.state = .folding(progress: fraction)
            }
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let sampler = try Genie2Sampler.bundled()
                let frames = try sampler.sample(seed: seed, frameCount: 180,
                                                progress: report,
                                                shouldContinue: { !Task.isCancelled })
                if Task.isCancelled { return }
                let n = Genie2Sampler.residues
                let metadata = TrajectoryMetadata(
                    name: "Generated \(n) residues, seed \(seed)",
                    sequence: String(repeating: "A", count: n),
                    provenance: FoldingEngine.generative.provenance,
                    sourceModel: "genie2/base epoch 40, Core ML",
                    blocksPerReadout: 1, recycles: 1,
                    generated: ISO8601DateFormatter().string(from: Date()),
                    notes: FoldingEngine.generative.provenance.disclosure)
                var readouts: [TrajectoryReadout] = []
                for (index, frame) in frames.enumerated() {
                    // Denoising progress, which is what this engine's confidence channel is:
                    // how far along the reverse process a frame is, and nothing more.
                    let progress = Float(index) / Float(Swift.max(frames.count - 1, 1)) * 100
                    readouts.append(TrajectoryReadout(
                        recycle: 0, blockIndex: index,
                        caPositions: frame.map {
                            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
                        },
                        confidence: [Float](repeating: progress, count: n)))
                }
                let provider = try SampleTrajectoryProvider(
                    bundle: TrajectoryBundle(metadata: metadata, readouts: readouts),
                    recycles: .all)
                await MainActor.run { [weak self] in
                    self?.state = .idle
                    player.play(provider)
                }
            } catch {
                await MainActor.run { [weak self] in self?.state = .failed("\(error)") }
            }
        }
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
    var caption: String = "Folding on this device"

    var body: some View {
        VStack(spacing: 10) {
            Text(caption)
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


/// Type a UniProt accession and fold that protein.
///
/// The structure is downloaded from AlphaFold and the trajectory is computed here, which is a
/// distinction worth keeping straight: a downloaded reference is not a precomputed trajectory.
/// Every frame of the fold is still arithmetic done on this device.
struct AccessionField: View {
    @Binding var accession: String
    let state: FoldRunner.State
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("UniProt accession, e.g. P69905", text: $accession)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .frame(maxWidth: 260)
                .onSubmit(onSubmit)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif
            Button("Fold", action: onSubmit)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(hex: 0x2B5CE6)))
                .foregroundStyle(.white)
                .disabled(accession.trimmingCharacters(in: .whitespaces).isEmpty)
            if case .fetching(let which) = state {
                Text("fetching \(which)…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x6B7C93))
            }
            if case .failed(let message) = state {
                // Wrapped, not truncated. An error clipped to "Genie 2 produced no usable..."
                // hides the half of the sentence that says which of several causes it was,
                // which is the only part worth showing.
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0xFF3D9A))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
