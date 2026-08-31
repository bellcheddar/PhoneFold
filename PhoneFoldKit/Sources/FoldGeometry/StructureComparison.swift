import Foundation
import simd
import FoldCore

/// A predicted structure against an experimental one: superposed, with the deviation per residue.
///
/// PLAN.md Phase 5a: "compare a prediction against an experimental structure (superpose, show
/// RMSD per residue) - the one analytical concession, because on a Mac it is expected."
///
/// **Residues are matched by number, never by position in the array.** This is the whole
/// correctness question. A prediction covers the construct; a crystal structure is missing the
/// disordered loop and the affinity tag, and often starts at residue 3. Zipping the two arrays
/// compares residue 1 against residue 3 and every residue after it against the wrong partner,
/// and the result is a large RMSD that looks like a bad prediction rather than like a bug. The
/// numbers are the only thing the two files genuinely share.
public struct StructureComparison: Sendable {

    public struct ResidueDeviation: Sendable, Equatable {
        public let number: Int
        public let name: String
        /// Distance in angstroms between the two alpha carbons after superposition.
        public let deviation: Float
        /// The experimental file's B-factor, for spotting that a large deviation sits where
        /// the crystal structure was itself poorly ordered.
        public let referenceBFactor: Float
    }

    public struct Result: Sendable {
        public let rmsd: Float
        public let deviations: [ResidueDeviation]
        /// Residue numbers present in the prediction but not the reference, and the reverse.
        public let onlyInMobile: [Int]
        public let onlyInReference: [Int]
        public let chain: String
        /// Fraction of matched residues whose names agree between the two files, 0 to 1.
        ///
        /// **The check that catches a numbering convention.** Matching by number handles a
        /// crystal structure missing its disordered ends. It does not handle two files that
        /// both number from 1 and mean different things by it - and that is the common case,
        /// because a UniProt entry includes the signal peptide and a crystal structure of the
        /// mature protein does not. Measured on hen lysozyme: AlphaFold P00698 against 1LYZ
        /// matched all 129 residues by number and returned 18.11 Å, which is not a bad
        /// prediction, it is the same structure compared to itself eighteen residues out of
        /// register. The residue names disagree, and that is cheap to see.
        public let sequenceIdentity: Double
        /// The shift that would make the two numberings agree, if one obviously would.
        public let suggestedOffset: Int?

        public var matched: Int { deviations.count }

        /// Whether the two numberings appear to describe the same residues.
        ///
        /// Nine tenths rather than all of it: a genuine comparison can span a point mutant or
        /// a selenomethionine derivative without being a different protein.
        public var numberingAgrees: Bool { sequenceIdentity >= 0.9 }

        /// The residues furthest from the experimental structure, worst first.
        public func worst(_ limit: Int = 10) -> [ResidueDeviation] {
            Array(deviations.sorted { $0.deviation > $1.deviation }.prefix(limit))
        }

        /// A one-line summary that does not overstate what was compared.
        ///
        /// The matched count is part of the headline rather than a footnote: an RMSD of 0.8 A
        /// over 12 residues of a 300-residue protein is not a good agreement, and quoting the
        /// number alone invites exactly that reading.
        public var summary: String {
            guard numberingAgrees else { return misregistrationWarning }
            let unmatched = onlyInMobile.count + onlyInReference.count
            var text = String(format: "%.2f Å over %d residues", rmsd, matched)
            if !chain.isEmpty { text += " of chain \(chain)" }
            if unmatched > 0 { text += ", \(unmatched) unmatched" }
            return text
        }

        /// What to say instead of a number, when the number would be meaningless.
        public var misregistrationWarning: String {
            var text = String(
                format: "The two files do not use the same numbering: only %.0f%% of the "
                    + "%d matched residues have the same name, so this would be comparing "
                    + "different residues to each other.",
                sequenceIdentity * 100, matched)
            if let suggestedOffset {
                text += " Shifting the prediction by \(suggestedOffset) residues lines them up"
                    + " - a UniProt entry includes the signal peptide and a structure of the"
                    + " mature protein does not."
            }
            return text
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noCommonResidues(mobile: Int, reference: Int)
        case tooFewToSuperpose(Int)
        case superpositionFailed

        public var description: String {
            switch self {
            case .noCommonResidues(let mobile, let reference):
                "No residue numbers are shared: one file has \(mobile) residues and the other "
                    + "\(reference), and none of them line up. They are probably different "
                    + "proteins, or one is numbered from 1 and the other from its construct."
            case .tooFewToSuperpose(let count):
                "\(count) residues in common is not enough to superpose; three is the minimum."
            case .superpositionFailed:
                "The superposition did not converge."
            }
        }
    }

    /// Compare two structures, matching residues by number within one chain.
    ///
    /// - Parameters:
    ///   - mobile: the prediction, which is moved onto the reference.
    ///   - reference: the experimental structure, which stays put.
    ///   - chain: which chain to compare. Nil takes the first chain the reference has, because
    ///     a prediction is usually one chain and a crystal structure often is not.
    ///   - offset: added to the prediction's residue numbers before matching, for the case
    ///     the check below detects: two files that both number from 1 and mean different
    ///     things by it.
    public static func compare(mobile: StructureFile, reference: StructureFile,
                               chain: String? = nil, offset: Int = 0) throws -> Result {
        let referenceChain = chain ?? reference.chains.first ?? ""
        let referenceResidues = referenceChain.isEmpty
            ? reference.residues : reference.residues(inChain: referenceChain)

        // The prediction's chain letter need not match the reference's, and usually does not:
        // AlphaFold calls everything A. So the mobile side is taken whole unless a chain was
        // named explicitly.
        let mobileResidues = chain.map { mobile.residues(inChain: $0) } ?? mobile.residues

        var referenceByNumber: [Int: StructureFile.Residue] = [:]
        for residue in referenceResidues { referenceByNumber[residue.number] = residue }
        var mobileByNumber: [Int: StructureFile.Residue] = [:]
        for residue in mobileResidues { mobileByNumber[residue.number - offset] = residue }

        let common = Set(referenceByNumber.keys).intersection(mobileByNumber.keys).sorted()
        guard !common.isEmpty else {
            throw Failure.noCommonResidues(mobile: mobileResidues.count,
                                           reference: referenceResidues.count)
        }
        guard common.count >= 3 else { throw Failure.tooFewToSuperpose(common.count) }

        let mobilePoints = common.map { mobileByNumber[$0]!.ca }
        let referencePoints = common.map { referenceByNumber[$0]!.ca }
        guard let superposition = Kabsch.superpose(mobile: mobilePoints,
                                                      onto: referencePoints) else {
            throw Failure.superpositionFailed
        }

        // The per-residue deviation is measured **after** applying the superposition, not from
        // the raw coordinates: the whole point is how different the shapes are, not where the
        // two files happen to sit in space.
        let moved = superposition.apply(mobilePoints)
        var deviations: [ResidueDeviation] = []
        for (index, number) in common.enumerated() {
            let residue = referenceByNumber[number]!
            deviations.append(ResidueDeviation(
                number: number,
                name: residue.name,
                deviation: simd_distance(moved[index], referencePoints[index]),
                referenceBFactor: residue.bFactor))
        }

        let agreeing = common.count { mobileByNumber[$0]!.name == referenceByNumber[$0]!.name }
        let identity = Double(agreeing) / Double(common.count)

        return Result(rmsd: superposition.rmsd,
                      deviations: deviations,
                      // Reported in the prediction's **own** numbering, not the shifted keys:
                      // "only in the prediction: -17 to 0" is a description of this function's
                      // internals, not of the file the user is holding.
                      onlyInMobile: Set(mobileByNumber.keys).subtracting(common)
                          .map { $0 + offset }.sorted(),
                      onlyInReference: Set(referenceByNumber.keys).subtracting(common).sorted(),
                      chain: referenceChain,
                      sequenceIdentity: identity,
                      suggestedOffset: identity >= 0.9 ? nil
                          : bestOffset(mobile: mobileByNumber, reference: referenceByNumber))
    }

    /// The shift that makes the most residue names agree, if one clearly does.
    ///
    /// Turning "these do not line up" into "these line up if you shift by 18" is most of the
    /// value: the first sends someone to work out why, the second tells them.
    ///
    /// Names only, never coordinates. A search over superpositions would be a structure
    /// alignment, which is a different program and explicitly not what PLAN asks for here.
    static func bestOffset(mobile: [Int: StructureFile.Residue],
                           reference: [Int: StructureFile.Residue],
                           range: ClosedRange<Int> = -200...200) -> Int? {
        var best: (offset: Int, agreeing: Int)?
        for offset in range where offset != 0 {
            var agreeing = 0
            var overlap = 0
            for (number, residue) in reference {
                guard let shifted = mobile[number + offset] else { continue }
                overlap += 1
                if shifted.name == residue.name { agreeing += 1 }
            }
            // At least twenty residues of overlap, or a short accidental run wins.
            guard overlap >= 20, Double(agreeing) / Double(overlap) >= 0.9 else { continue }
            if best == nil || agreeing > best!.agreeing { best = (offset, agreeing) }
        }
        return best?.offset
    }
}
