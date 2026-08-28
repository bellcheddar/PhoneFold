import Foundation
import simd

/// Where a trajectory's coordinates actually came from.
///
/// This is provenance, not decoration. PLAN.md section 4 requires the About panel to be able
/// to answer "where did this come from", and the no-fake-data rule means a bundle must be
/// able to say so honestly. There is deliberately no case for "synthesised" or "interpolated
/// from a known structure": such a file must not exist.
public enum TrajectoryProvenance: String, Codable, Sendable, Hashable {
    /// Real ESMFold inference, coordinates read out of the folding trunk mid-trajectory.
    case esmFoldReadout = "esmfold-trunk-readout"
    /// Real Core ML inference on the exported stateful trunk step model.
    case coreMLTrunkStep = "coreml-trunk-step"
    /// A deterministic geometric construction used only as a test fixture. **Never shipped
    /// in an app bundle** and never presented to a user as a fold.
    case testFixture = "test-fixture"
}

/// Everything about a trajectory that is not a coordinate.
public struct TrajectoryMetadata: Codable, Sendable, Hashable {
    /// Display name, for example "Ubiquitin".
    public var name: String
    /// One-letter sequence. `residueCount` is derived from this, never stored separately.
    public var sequence: String
    /// UniProt accession where there is one.
    public var accession: String?
    /// Source organism, for the gallery caption.
    public var organism: String?
    /// What to listen for, shown in the sample gallery. PLAN.md Phase 4.
    public var listeningNote: String?
    /// Experimental reference structure for this protein, if one exists, as a PDB ID.
    /// Used by the accuracy regression and by Studio's structure comparison.
    public var referencePDBID: String?

    public var provenance: TrajectoryProvenance
    /// Checkpoint or model identifier the coordinates came from, e.g. `facebook/esmfold_v1`.
    public var sourceModel: String
    /// Trunk blocks between coordinate readouts. PLAN.md starts at 4.
    public var blocksPerReadout: Int
    /// Number of recycles run.
    public var recycles: Int
    /// ISO 8601, when the trajectory was generated.
    public var generated: String
    /// Free-text notes: toolchain versions, device, anything a later reader will want.
    public var notes: String?

    public var residueCount: Int { sequence.count }

    public init(
        name: String, sequence: String, accession: String? = nil, organism: String? = nil,
        listeningNote: String? = nil, referencePDBID: String? = nil,
        provenance: TrajectoryProvenance, sourceModel: String,
        blocksPerReadout: Int, recycles: Int, generated: String, notes: String? = nil
    ) {
        self.name = name; self.sequence = sequence; self.accession = accession
        self.organism = organism; self.listeningNote = listeningNote
        self.referencePDBID = referencePDBID; self.provenance = provenance
        self.sourceModel = sourceModel; self.blocksPerReadout = blocksPerReadout
        self.recycles = recycles; self.generated = generated; self.notes = notes
    }
}

/// One raw coordinate readout from the model. Not a `FoldFrame`: no secondary structure, no
/// contacts, no metrics, and never interpolated.
///
/// Those are all *derived*, by FoldGeometry, at load time. Storing them would create a second
/// source of truth that could silently disagree with the live path, and would let a bundle
/// ship a P-SEA assignment that the shipping P-SEA implementation would never produce.
public struct TrajectoryReadout: Sendable, Hashable {
    public let recycle: Int
    public let blockIndex: Int
    public let backbone: [BackboneResidue]
    /// Per-residue pLDDT on the AlphaFold 0...100 scale.
    public let pLDDT: [Float]

    public init(recycle: Int, blockIndex: Int, backbone: [BackboneResidue], pLDDT: [Float]) {
        self.recycle = recycle; self.blockIndex = blockIndex
        self.backbone = backbone; self.pLDDT = pLDDT
    }
}

/// A decoded `.pftraj` file: metadata plus every raw readout, in order.
public struct TrajectoryBundle: Sendable {
    public var metadata: TrajectoryMetadata
    public var readouts: [TrajectoryReadout]

    public init(metadata: TrajectoryMetadata, readouts: [TrajectoryReadout]) {
        self.metadata = metadata
        self.readouts = readouts
    }

    /// The sequence as amino acids. Unresolvable codes become `.unknown` rather than failing.
    public var residues: [AminoAcid] { metadata.sequence.map(AminoAcid.init(code:)) }

    /// Every readout must have one backbone residue and one pLDDT per sequence position, and
    /// no non-finite numbers anywhere.
    public var isConsistent: Bool {
        let n = metadata.residueCount
        guard n > 0, !readouts.isEmpty else { return false }
        for r in readouts {
            guard r.backbone.count == n, r.pLDDT.count == n else { return false }
            guard r.pLDDT.allSatisfy({ $0.isFinite }) else { return false }
            for res in r.backbone {
                for v in [res.n, res.ca, res.c, res.o]
                where !v.x.isFinite || !v.y.isFinite || !v.z.isFinite { return false }
            }
        }
        return true
    }
}
