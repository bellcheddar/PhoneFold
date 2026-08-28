import Foundation

/// The twenty standard amino acids, plus `unknown` for anything a sequence throws at us
/// that we cannot resolve (`X`, `B`, `Z`, `J`, and any non-standard code).
///
/// The raw value is the one-letter code, which is what the ESM-2 tokeniser and every FASTA
/// file speak. Everything else hangs off that.
public enum AminoAcid: Character, CaseIterable, Sendable, Hashable {
    case alanine = "A", cysteine = "C", asparticAcid = "D", glutamicAcid = "E"
    case phenylalanine = "F", glycine = "G", histidine = "H", isoleucine = "I"
    case lysine = "K", leucine = "L", methionine = "M", asparagine = "N"
    case proline = "P", glutamine = "Q", arginine = "R", serine = "S"
    case threonine = "T", valine = "V", tryptophan = "W", tyrosine = "Y"
    case unknown = "X"

    /// The one-letter code.
    public var code: Character { rawValue }

    /// Case-insensitive lookup. Any unrecognised code resolves to `.unknown` rather than
    /// failing, because a sequence with a `B` in it should still fold.
    public init(code: Character) {
        let upper = Character(String(code).uppercased())
        self = AminoAcid(rawValue: upper) ?? .unknown
    }

    /// The three-letter code, for mmCIF export and residue labels.
    public var threeLetterCode: String {
        switch self {
        case .alanine: "ALA"; case .cysteine: "CYS"; case .asparticAcid: "ASP"
        case .glutamicAcid: "GLU"; case .phenylalanine: "PHE"; case .glycine: "GLY"
        case .histidine: "HIS"; case .isoleucine: "ILE"; case .lysine: "LYS"
        case .leucine: "LEU"; case .methionine: "MET"; case .asparagine: "ASN"
        case .proline: "PRO"; case .glutamine: "GLN"; case .arginine: "ARG"
        case .serine: "SER"; case .threonine: "THR"; case .valine: "VAL"
        case .tryptophan: "TRP"; case .tyrosine: "TYR"; case .unknown: "UNK"
        }
    }

    public var name: String {
        switch self {
        case .alanine: "alanine"; case .cysteine: "cysteine"; case .asparticAcid: "aspartic acid"
        case .glutamicAcid: "glutamic acid"; case .phenylalanine: "phenylalanine"
        case .glycine: "glycine"; case .histidine: "histidine"; case .isoleucine: "isoleucine"
        case .lysine: "lysine"; case .leucine: "leucine"; case .methionine: "methionine"
        case .asparagine: "asparagine"; case .proline: "proline"; case .glutamine: "glutamine"
        case .arginine: "arginine"; case .serine: "serine"; case .threonine: "threonine"
        case .valine: "valine"; case .tryptophan: "tryptophan"; case .tyrosine: "tyrosine"
        case .unknown: "unknown"
        }
    }

    /// Kyte-Doolittle hydropathy index (J. Mol. Biol. 1982, 157(1):105-132).
    ///
    /// Drives the hydrophobicity colour mode in Phase 2 and, more importantly, the
    /// classification of contact events in Phase 3: a long-range contact between two
    /// hydrophobic residues is core formation, and that is the musically interesting one.
    public var hydropathy: Float {
        switch self {
        case .isoleucine: 4.5; case .valine: 4.2; case .leucine: 3.8
        case .phenylalanine: 2.8; case .cysteine: 2.5; case .methionine: 1.9
        case .alanine: 1.8; case .glycine: -0.4; case .threonine: -0.7
        case .serine: -0.8; case .tryptophan: -0.9; case .tyrosine: -1.3
        case .proline: -1.6; case .histidine: -3.2; case .glutamicAcid: -3.5
        case .glutamine: -3.5; case .asparticAcid: -3.5; case .asparagine: -3.5
        case .lysine: -3.9; case .arginine: -4.5
        case .unknown: 0.0
        }
    }

    /// True where the Kyte-Doolittle index is positive. The threshold is deliberately zero
    /// rather than a windowed average: this is a per-residue property used for event
    /// classification, not a transmembrane-helix predictor.
    public var isHydrophobic: Bool { hydropathy > 0 }

    /// Formal charge at physiological pH. Histidine is treated as neutral, which is the
    /// usual convention at pH 7.4 given its pKa near 6.
    public var charge: Int {
        switch self {
        case .arginine, .lysine: 1
        case .asparticAcid, .glutamicAcid: -1
        default: 0
        }
    }

    /// The four residues the Fantasy style profile uses as octave-shift triggers
    /// (Tay et al., Heliyon 2021, 7(9):e07933): R and K shift up, D and E shift down.
    public var isCharged: Bool { charge != 0 }
}
