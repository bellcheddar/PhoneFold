import Foundation
import simd

/// Backbone atoms of one residue, in angstroms.
///
/// N, CA, C and O only. Side chains are not predicted by the trunk readout and are not
/// rendered: PhoneFold draws a swept backbone tube, not an all-atom model.
public struct BackboneResidue: Sendable, Hashable {
    public var n: SIMD3<Float>
    public var ca: SIMD3<Float>
    public var c: SIMD3<Float>
    public var o: SIMD3<Float>

    public init(n: SIMD3<Float>, ca: SIMD3<Float>, c: SIMD3<Float>, o: SIMD3<Float>) {
        self.n = n; self.ca = ca; self.c = c; self.o = o
    }

    /// Every backbone atom in canonical order, for mmCIF export.
    public var atoms: [(name: String, position: SIMD3<Float>)] {
        [("N", n), ("CA", ca), ("C", c), ("O", o)]
    }
}

/// One frame of a folding trajectory: everything the renderer, the score and the readouts
/// need, computed once.
///
/// A frame is a value. It is produced by FoldEngine, enriched by FoldGeometry, and consumed
/// independently by FoldRender and FoldAudio, which never speak to each other.
public struct FoldFrame: Sendable {
    /// Monotonic index across the whole trajectory, including interpolated frames.
    public let index: Int
    /// Which recycle of the trunk produced this frame. Recycle boundaries are harmonic
    /// modulations in the score.
    public let recycle: Int
    /// Which trunk block the coordinate readout came from. Constant across the interpolated
    /// frames that follow a raw one.
    public let blockIndex: Int

    public let backbone: [BackboneResidue]
    /// Per-residue pLDDT, 0...100 on the AlphaFold scale.
    public let pLDDT: [Float]
    public let secondaryStructure: [SSAssignment]
    /// Contacts that formed on this frame. Empty on interpolated frames by construction.
    public let newContacts: [ContactEvent]

    /// Radius of gyration in angstroms. Drives tempo and register: compaction is an accelerando.
    public let radiusOfGyration: Float
    /// Mean pLDDT across all residues. Drives low-pass cutoff, detune and reverb wet mix.
    public let meanPLDDT: Float

    /// True when this frame was produced by interpolation between two raw model readouts
    /// rather than by the model itself.
    ///
    /// The score must ignore interpolated frames for event triggering, or a single contact
    /// becomes a machine-gun burst at 60 fps. The renderer uses them; the sequencer does not.
    public let isInterpolated: Bool

    public init(
        index: Int,
        recycle: Int,
        blockIndex: Int,
        backbone: [BackboneResidue],
        pLDDT: [Float],
        secondaryStructure: [SSAssignment],
        newContacts: [ContactEvent],
        radiusOfGyration: Float,
        meanPLDDT: Float,
        isInterpolated: Bool
    ) {
        self.index = index
        self.recycle = recycle
        self.blockIndex = blockIndex
        self.backbone = backbone
        self.pLDDT = pLDDT
        self.secondaryStructure = secondaryStructure
        self.newContacts = newContacts
        self.radiusOfGyration = radiusOfGyration
        self.meanPLDDT = meanPLDDT
        self.isInterpolated = isInterpolated
    }

    /// Number of residues in the frame.
    public var residueCount: Int { backbone.count }

    /// Fraction of residues assigned to each of the three states, in the order
    /// (helix, sheet, coil). Feeds the live stacked area chart and the textural balance of
    /// the score. Returns zeros for an empty frame rather than dividing by zero.
    public var structureFractions: (helix: Float, sheet: Float, coil: Float) {
        guard !secondaryStructure.isEmpty else { return (0, 0, 0) }
        var h = 0, e = 0
        for a in secondaryStructure {
            switch a.structure {
            case .helix: h += 1
            case .sheet: e += 1
            case .coil: break
            }
        }
        let total = Float(secondaryStructure.count)
        let hf = Float(h) / total, ef = Float(e) / total
        return (hf, ef, 1 - hf - ef)
    }

    /// Whether the frame is internally consistent. Every per-residue array must agree with
    /// the backbone length, and no coordinate may be non-finite.
    ///
    /// Phase 2's gate asserts zero geometry NaNs across a full sample trajectory; this is
    /// the predicate that assertion uses.
    public var isWellFormed: Bool {
        guard pLDDT.count == backbone.count,
              secondaryStructure.count == backbone.count else { return false }
        for r in backbone {
            for v in [r.n, r.ca, r.c, r.o] where !v.x.isFinite || !v.y.isFinite || !v.z.isFinite {
                return false
            }
        }
        return pLDDT.allSatisfy(\.isFinite) && radiusOfGyration.isFinite && meanPLDDT.isFinite
    }
}
