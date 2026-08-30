import Foundation
import simd

/// Where a trajectory's coordinates actually came from.
///
/// This is provenance, not decoration. PLAN.md section 4 requires the About panel to be able
/// to answer "where did this come from", and the no-fake-data rule means a bundle must be
/// able to say so honestly. There is deliberately no case for "synthesised" or "interpolated
/// from a known structure": such a file must not exist.
public enum TrajectoryProvenance: String, Codable, Sendable, Hashable, CaseIterable {
    /// Real ESMFold inference, coordinates read out of the folding trunk mid-trajectory.
    case esmFoldReadout = "esmfold-trunk-readout"
    /// Real Core ML inference on the exported stateful trunk step model.
    case coreMLTrunkStep = "coreml-trunk-step"
    /// Real foldingDiff sampling: a denoising path over backbone dihedrals, from noise to a
    /// folded backbone. The protein is **generated, not predicted** — it is novel, and its
    /// sequence comes from inverse folding rather than from an accession.
    case foldingDiffDenoising = "foldingdiff-denoising"
    /// Real Genie 2 sampling: an SE(3)-equivariant denoising path from noise to a compact
    /// backbone. Like foldingDiff the protein is **generated, not predicted**, and Genie 2
    /// emits a CA trace rather than a full backbone.
    case genie2Denoising = "genie2-denoising"
    /// Real PathDiffusion sampling: an evolution-guided folding pathway for a named protein,
    /// precomputed offline because the MSA pipeline cannot run on device.
    case pathDiffusionPathway = "pathdiffusion-pathway"
    /// A CA-level structure-based (Go) simulation, computed on the device, of a **named**
    /// protein relaxing into a structure that is already known.
    ///
    /// This is the one provenance that is a real dynamical pathway and not a prediction: the
    /// native coordinates define the energy landscape, so the model is handed the answer and
    /// finds a route to it. The app must say so - see `disclosure`.
    case structureBasedFolding = "structure-based-folding"
    /// A geometric interpolation from an unfolded coil into a known structure.
    ///
    /// Not folding at all, and never to be presented as such. It has no energy and no
    /// dynamics, and it passes through conformations that are sterically impossible
    /// (measured: closest non-bonded approach 0.28 A). It exists as the baseline the
    /// simulations are judged against.
    case geometricMorph = "geometric-morph"
    /// A deterministic geometric construction used only as a test fixture. **Never shipped
    /// in an app bundle** and never presented to a user as a fold.
    case testFixture = "test-fixture"

    /// Whether this trajectory came from real inference and may be shown to a user as a
    /// fold. Only `testFixture` may not, and the Phase 0 gate checks the shipped directory.
    public var isShippable: Bool { self != .testFixture }

    /// Whether the protein was generated rather than predicted from a known sequence.
    /// The UI must say so: a foldingDiff trajectory is a novel protein that has never
    /// existed, not a prediction of anything in the PDB.
    public var isGenerated: Bool {
        self == .foldingDiffDenoising || self == .genie2Denoising
    }

    /// Whether this trajectory was computed toward a structure that was already known.
    ///
    /// True for the structure-based simulation and the morph, and the distinction the app has
    /// to be careful about: those two produce a *named* protein arriving at its real fold, and
    /// neither of them predicted it. A viewer who is not told will reasonably assume they are
    /// watching a prediction, because that is what folding software normally does.
    public var isTowardKnownStructure: Bool {
        self == .structureBasedFolding || self == .geometricMorph
    }

    /// The one line the app must show alongside a fold, so its claim is never overstated.
    public var disclosure: String? {
        switch self {
        case .structureBasedFolding:
            "Simulated on device toward a known structure — not a prediction"
        case .geometricMorph:
            "Interpolation toward a known structure — not a fold"
        case .foldingDiffDenoising, .genie2Denoising:
            "Generated — this protein has never existed"
        case .esmFoldReadout, .coreMLTrunkStep, .pathDiffusionPathway, .testFixture:
            nil
        }
    }

    /// What the per-residue confidence in an accompanying frame actually means.
    public var confidenceSource: ConfidenceSource {
        switch self {
        case .esmFoldReadout, .coreMLTrunkStep, .pathDiffusionPathway: .pLDDT
        case .foldingDiffDenoising, .genie2Denoising: .denoisingProgress
        case .structureBasedFolding: .nativeContacts
        case .geometricMorph: .morphProgress
        case .testFixture: .pLDDT
        }
    }
}

/// What a per-residue confidence value means, so the UI never mislabels one as the other.
///
/// foldingDiff is a generator, not a predictor: it has no pLDDT, and calling its denoising
/// progress "pLDDT" would be a scientific claim it cannot support.
public enum ConfidenceSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// AlphaFold-style predicted local distance difference test, 0...100, read at the CA.
    case pLDDT = "plddt"
    /// How far along the denoising path a generated frame is, rescaled to 0...100.
    case denoisingProgress = "denoising-progress"
    /// The fraction of the native contacts a residue has formed, as a percentage.
    ///
    /// The reaction coordinate a structure-based model is actually read by, and a real
    /// measurement of how folded a residue is - not a confidence, because the model has no
    /// opinion about whether the answer is right. It was given the answer.
    case nativeContacts = "native-contacts"
    /// How far along a geometric interpolation a frame is. Carries no physical meaning at all.
    case morphProgress = "morph-progress"

    /// The label to show a user. Never interchangeable.
    public var displayName: String {
        switch self {
        case .pLDDT: "pLDDT"
        case .denoisingProgress: "Resolution"
        case .nativeContacts: "Contacts"
        case .morphProgress: "Progress"
        }
    }
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

    /// CA positions. **Always present**, because every engine produces them and because the
    /// renderer sweeps its tube through CA while P-SEA is CA-only by design.
    public let caPositions: [SIMD3<Float>]

    /// N, CA, C and O, present only when the source model actually emits them.
    ///
    /// `nil` for a CA-trace engine such as Genie 2. It is deliberately optional rather than
    /// filled in with constructed atoms: N and C built from CA positions alone would be
    /// invented coordinates presented as model output. Where a full backbone is genuinely
    /// needed, FoldGeometry constructs one at load time and says so.
    public let backbone: [BackboneResidue]?

    /// Per-residue confidence. What it *means* depends on the bundle's provenance: pLDDT on
    /// the AlphaFold 0...100 scale for a predictor, denoising progress for a generator.
    /// See `TrajectoryProvenance.confidenceSource`.
    public let confidence: [Float]

    /// Full-backbone readout.
    public init(recycle: Int, blockIndex: Int,
                backbone: [BackboneResidue], confidence: [Float]) {
        self.recycle = recycle
        self.blockIndex = blockIndex
        self.caPositions = backbone.map(\.ca)
        self.backbone = backbone
        self.confidence = confidence
    }

    /// CA-trace readout, for an engine that emits nothing else.
    public init(recycle: Int, blockIndex: Int,
                caPositions: [SIMD3<Float>], confidence: [Float]) {
        self.recycle = recycle
        self.blockIndex = blockIndex
        self.caPositions = caPositions
        self.backbone = nil
        self.confidence = confidence
    }

    /// Number of atoms per residue actually stored: 1 for a CA trace, 4 for a full backbone.
    public var atomsPerResidue: Int { backbone == nil ? 1 : 4 }
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

    /// Every readout must have one CA and one confidence value per sequence position, agree
    /// with the others about whether a full backbone is present, and contain no non-finite
    /// numbers anywhere.
    public var isConsistent: Bool {
        let n = metadata.residueCount
        guard n > 0, !readouts.isEmpty else { return false }
        let expectsBackbone = readouts[0].backbone != nil
        for r in readouts {
            guard r.caPositions.count == n, r.confidence.count == n else { return false }
            // A bundle must not mix CA-trace and full-backbone frames: the renderer picks
            // its geometry path once, and a mid-trajectory change would be a silent fault.
            guard (r.backbone != nil) == expectsBackbone else { return false }
            guard r.confidence.allSatisfy({ $0.isFinite }) else { return false }
            for v in r.caPositions where !v.x.isFinite || !v.y.isFinite || !v.z.isFinite {
                return false
            }
            if let backbone = r.backbone {
                guard backbone.count == n else { return false }
                for res in backbone {
                    for v in [res.n, res.c, res.o]
                    where !v.x.isFinite || !v.y.isFinite || !v.z.isFinite { return false }
                }
            }
        }
        return true
    }

    /// Whether this trajectory carries full backbones or only CA positions.
    public var hasFullBackbone: Bool { readouts.first?.backbone != nil }
}
