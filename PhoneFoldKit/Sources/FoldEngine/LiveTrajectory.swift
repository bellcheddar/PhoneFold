import Foundation
import simd
import FoldCore

/// Which engine computes a fold.
///
/// All three run on the device and none of them ships a precomputed trajectory. What separates
/// them is the claim each one supports, which is why `provenance` is part of the engine rather
/// than something the caller chooses: an engine cannot be pointed at the wrong disclosure.
public enum FoldingEngine: String, CaseIterable, Sendable, Codable, Hashable {
    /// A CA-level structure-based (Go) simulation toward a known structure.
    case structureBased = "structure-based"
    /// A geometric interpolation toward a known structure.
    case morph
    /// Genie 2 denoising: a generated protein, not a named one.
    case generative

    public var displayName: String {
        switch self {
        case .structureBased: "Simulate"
        case .morph: "Morph"
        case .generative: "Generate"
        }
    }

    /// One line on what this engine actually does, for the picker.
    public var summary: String {
        switch self {
        case .structureBased:
            "Coarse-grained physics relaxing a named protein into its known structure"
        case .morph:
            "A smooth interpolation into the known structure. Not physics"
        case .generative:
            "Genie 2 invents a backbone from noise. Not a named protein"
        }
    }

    public var provenance: TrajectoryProvenance {
        switch self {
        case .structureBased: .structureBasedFolding
        case .morph: .geometricMorph
        case .generative: .genie2Denoising
        }
    }

    /// Whether this engine needs a reference structure to fold toward.
    public var needsReferenceStructure: Bool { self != .generative }
}

/// Runs an engine on the device and assembles the result into a `TrajectoryBundle`.
///
/// The bundle is the app's existing currency: everything downstream - interpolation, secondary
/// structure, contacts, the metrics panel, the renderer - consumes one and does not care where
/// it came from. Producing one here means a live fold plays through exactly the same path as a
/// bundled trajectory, with no second code path to keep in step.
public enum LiveTrajectory {

    public enum Failure: Error, CustomStringConvertible {
        case tooShort(residues: Int)
        case cancelled
        /// The generative engine does not fold toward a reference and is driven separately.
        case notAReferenceEngine(FoldingEngine)

        public var description: String {
            switch self {
            case .tooShort(let n): "A chain of \(n) residues is too short to fold."
            case .cancelled: "The fold was cancelled."
            case .notAReferenceEngine(let engine):
                "\(engine.displayName) does not fold toward a reference structure."
            }
        }
    }

    /// Fold `sequence` toward `native`, on this device, and return a playable trajectory.
    ///
    /// - Parameters:
    ///   - progress: called with 0...1 as the simulation advances. A structure-based fold of a
    ///     76-residue protein is tens of seconds of arithmetic, so the caller needs this to
    ///     show something other than a frozen screen.
    ///   - shouldContinue: polled per emitted frame, so a cancelled playback stops the
    ///     simulation instead of running it to the end and throwing the answer away.
    public static func fold(engine: FoldingEngine,
                            native: [SIMD3<Double>],
                            metadata: TrajectoryMetadata,
                            residues: [AminoAcid],
                            seed: UInt64 = 1,
                            steps: Int? = nil,
                            frameCount: Int = 180,
                            mutation: Mutation? = nil,
                            progress: (@Sendable (Double) -> Void)? = nil,
                            shouldContinue: (@Sendable () -> Bool)? = nil)
        throws -> TrajectoryBundle {
        guard native.count >= 4 else { throw Failure.tooShort(residues: native.count) }
        let start = UnfoldedChain.build(residues: native.count, seed: seed)

        let frames: [[SIMD3<Double>]]
        let confidence: [[Float]]

        switch engine {
        case .structureBased:
            var parameters = StructureBasedModel.Parameters()
            parameters.seed = seed
            parameters.frameCount = frameCount
            // A substitution perturbs the native contact energies rather than the structure:
            // the mutant folds toward the same target under a different landscape.
            parameters.mutation = mutation
            if let steps { parameters.steps = steps }
            let model = StructureBasedModel(native: native, parameters: parameters)
            frames = model.fold(from: start, progress: progress, shouldContinue: shouldContinue)
            // Per-residue fraction of native contacts: a real measurement of how folded each
            // residue is, and what the colour ramp reads. A residue locking into the core
            // goes from nothing to complete while the tails are still loose, which is the
            // thing worth watching.
            confidence = frames.map { model.perResidueNativeFraction($0).map { Float($0 * 100) } }

        case .morph:
            var parameters = MorphSimulation.Parameters()
            parameters.seed = seed
            parameters.frameCount = frameCount
            let morph = MorphSimulation(native: native, parameters: parameters)
            frames = morph.run(from: start)
            // How far each residue has travelled toward where it ends up, as a fraction of
            // how far it had to go. Uniform in torsion space but emphatically not in space -
            // a residue near the fixed end barely moves while a tail sweeps tens of angstroms
            // - so this still says something about the order in which things settle.
            let journey = zip(start, native).map { simd_length($1 - $0) }
            confidence = frames.map { frame in
                zip(zip(frame, native), journey).map { pair, total in
                    guard total > 1e-6 else { return Float(100) }
                    let remaining = simd_length(pair.1 - pair.0)
                    return Float(Swift.min(Swift.max(1 - remaining / total, 0), 1) * 100)
                }
            }

        case .generative:
            // Genie 2 samples from noise through Core ML and has no reference to fold toward,
            // so it is driven by its own path rather than by this builder.
            throw Failure.notAReferenceEngine(engine)
        }

        guard !frames.isEmpty else { throw Failure.cancelled }

        var readouts: [TrajectoryReadout] = []
        readouts.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            readouts.append(TrajectoryReadout(
                recycle: 0,
                blockIndex: index,
                caPositions: frame.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) },
                confidence: index < confidence.count ? confidence[index]
                                                     : [Float](repeating: 0, count: frame.count)))
        }
        return TrajectoryBundle(metadata: metadata, readouts: readouts)
    }
}

extension StructureBasedModel {
    /// How much of each residue's own native contact set it has formed.
    ///
    /// The per-residue version of `fractionNative`, and the thing that makes a structure-based
    /// fold worth watching in colour: the hydrophobic core locks in first and completely while
    /// the termini are still loose, and a single number over the whole chain hides that.
    /// A residue with no native contacts of its own takes the chain's overall value, because
    /// 0/0 is not 0. Some residues - a flexible terminus, a residue on a convex surface - have
    /// no long-range partners at all, and scoring them zero would paint them as permanently
    /// unfolded even in the native structure, which is both wrong and exactly the sort of thing
    /// a viewer would read as meaningful.
    public func perResidueNativeFraction(_ x: [SIMD3<Double>],
                                         tolerance: Double = 1.2) -> [Double] {
        var formed = [Double](repeating: 0, count: x.count)
        var total = [Double](repeating: 0, count: x.count)
        for index in 0..<contactCount {
            let (i, j, sigma) = contact(at: index)
            total[i] += 1; total[j] += 1
            if simd_length(x[j] - x[i]) < sigma * tolerance {
                formed[i] += 1; formed[j] += 1
            }
        }
        let overall = fractionNative(x, tolerance: tolerance)
        return zip(formed, total).map { $1 > 0 ? $0 / $1 : overall }
    }
}
