import Foundation

/// Three-state secondary structure. Three states, not eight: the renderer sweeps three
/// cross sections, the score has three textural layers, and a CA-only assignment cannot
/// honestly distinguish a 3-10 helix from an alpha helix early in a trajectory.
public enum SecondaryStructure: UInt8, CaseIterable, Sendable, Hashable {
    case coil = 0
    case helix = 1
    case sheet = 2

    /// DSSP-style single-character code, for logs and for comparing against a reference.
    public var code: Character {
        switch self {
        case .helix: "H"; case .sheet: "E"; case .coil: "C"
        }
    }
}

/// A per-residue secondary structure assignment carrying its own confidence.
///
/// The confidence is what makes the renderer's cross section *morph* rather than snap:
/// structure grows in as confidence rises. It is also why hysteresis lives in FoldGeometry
/// and not here — this type records an assignment, it does not decide one.
public struct SSAssignment: Sendable, Hashable {
    public var structure: SecondaryStructure
    /// 0...1. Clamped on construction; a renderer should never receive 1.4.
    public var confidence: Float

    public init(structure: SecondaryStructure, confidence: Float) {
        self.structure = structure
        self.confidence = min(max(confidence, 0), 1)
    }

    /// An unassigned residue: coil, no confidence. The state every trajectory starts in.
    public static let unassigned = SSAssignment(structure: .coil, confidence: 0)
}
