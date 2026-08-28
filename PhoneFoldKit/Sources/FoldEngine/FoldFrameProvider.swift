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

    public var metadata: TrajectoryMetadata { bundle.metadata }
    public var residues: [AminoAcid] { bundle.residues }
    public var readouts: [TrajectoryReadout] { bundle.readouts }

    public init(bundle: TrajectoryBundle) throws {
        guard bundle.isConsistent else { throw FoldEngineError.inconsistentTrajectory }
        self.bundle = bundle
    }

    public init(contentsOf url: URL) throws {
        try self.init(bundle: TrajectoryBundleCodec.read(contentsOf: url))
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
