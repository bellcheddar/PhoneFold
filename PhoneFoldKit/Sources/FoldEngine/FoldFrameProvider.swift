import Foundation
import simd
import FoldCore

/// A source of raw model readouts.
///
/// PLAN.md Phase 1 requires the rest of the app to be unable to tell providers apart, which
/// is what made changing engine from ESMFold to Genie 2 a Phase 0 concern rather than a
/// rewrite. Everything downstream consumes `FoldFrame` and never asks where it came from.
public protocol FoldFrameProvider: Sendable {
    var metadata: TrajectoryMetadata { get }
    var residues: [AminoAcid] { get }
    /// Raw readouts in trajectory order. Never interpolated.
    var readouts: [TrajectoryReadout] { get }
}

extension FoldFrameProvider {
    public var residueCount: Int { metadata.residueCount }
    /// What the per-residue confidence in these readouts actually means.
    public var confidenceSource: ConfidenceSource { metadata.provenance.confidenceSource }
    /// Whether this protein was generated rather than predicted.
    public var isGenerated: Bool { metadata.provenance.isGenerated }
}

/// Plays a bundled or generated `.pftraj` file.
public struct SampleTrajectoryProvider: FoldFrameProvider {
    public let bundle: TrajectoryBundle
    public let recycles: RecycleSelection

    /// How much of a recycled trajectory to play.
    ///
    /// **Why this exists.** ESMFold refines by *recycling*: the trunk runs, its structure is
    /// fed back in, and the whole thing runs again. Within one recycle the eight readouts are
    /// the structure module's eight IPA layers and they descend cleanly; at each new recycle
    /// the trunk re-enters from a coarser state, the structure re-expands, and the radius of
    /// gyration steps back up. Played end to end that is not one fold, it is the same fold
    /// four times with a jump between each.
    ///
    /// And measurement says the later passes earn very little. Against the four-recycle
    /// answer, the end of the first recycle is already 0.18 A RMSD on ubiquitin, 0.38 A on
    /// myoglobin and 0.75 A on trp-cage, for a pLDDT difference of 0.0, 1.7 and 4.6. Three
    /// quarters of the runtime, spent arriving at the same structure.
    ///
    /// So the default is the first recycle: one continuous descent into the fold. The whole
    /// trajectory stays in the file and stays playable - this is a choice about what to show,
    /// not a reason to throw data away.
    public enum RecycleSelection: Sendable, Equatable {
        /// The first pass only: a single uninterrupted descent.
        case first
        /// Every readout in the file, recycle jumps included.
        case all
    }

    public var metadata: TrajectoryMetadata { bundle.metadata }
    public var residues: [AminoAcid] { bundle.residues }

    public var readouts: [TrajectoryReadout] {
        switch recycles {
        case .all:
            return bundle.readouts
        case .first:
            guard let first = bundle.readouts.first?.recycle else { return bundle.readouts }
            let kept = bundle.readouts.filter { $0.recycle == first }
            // A trajectory that does not recycle at all - anything from a diffusion model -
            // has one recycle index throughout and is returned whole.
            return kept.isEmpty ? bundle.readouts : kept
        }
    }

    public init(bundle: TrajectoryBundle, recycles: RecycleSelection = .first) throws {
        guard bundle.isConsistent else { throw FoldEngineError.inconsistentTrajectory }
        self.bundle = bundle
        self.recycles = recycles
    }

    public init(contentsOf url: URL, recycles: RecycleSelection = .first) throws {
        try self.init(bundle: TrajectoryBundleCodec.read(contentsOf: url), recycles: recycles)
    }
}

public enum FoldEngineError: Error, CustomStringConvertible, Equatable {
    case inconsistentTrajectory
    case emptyTrajectory

    public var description: String {
        switch self {
        case .inconsistentTrajectory:
            "That trajectory's frames disagree with each other and cannot be played."
        case .emptyTrajectory:
            "That trajectory has no frames in it."
        }
    }
}
