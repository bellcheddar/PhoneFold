import Foundation
import simd
import FoldCore

/// A point substitution, and what it does to a structure-based fold.
///
/// **PhoneFold cannot predict a mutant's structure, and this does not pretend to.** There is no
/// sequence-to-structure model on the device: the engines replay a trajectory, simulate toward
/// a structure that is already known, or sample a backbone from noise. A mutant has no entry in
/// the AlphaFold database and nothing here can fold one from scratch.
///
/// What a structure-based model *can* do, and what this does, is the standard thing: keep the
/// native structure and weaken the interactions the substituted residue makes. That is how
/// Go-model studies of phi-value analysis have represented substitutions for twenty years -
/// Clementi, Nymeyer and Onuchic's own framework, in which a mutation is a perturbation of the
/// native contact energies rather than a new structure.
///
/// **It does not follow that the mutant folds worse, and measurement says it often does not.**
/// On villin HP36, weakening the most buried residue's contacts produced a *higher* final
/// native fraction than the wild type - 1.00 against 0.89 at 200,000 steps - not a lower one. A
/// Go landscape is smooth by construction, and removing some of a residue's contacts can reduce
/// frustration rather than add it. The perturbation changes the trajectory; which direction it
/// changes it in is a property of that protein and that site, not something this model can be
/// assumed to get right.
///
/// So the feature this supports is a **comparison**, not a stability prediction: the duet
/// sonifies *where and by how much two folds diverge*, which is real, rather than "how much
/// worse the mutant is", which would be a claim about free energy that nothing here computes.
///
/// **What this is not.** It is not a prediction of ΔΔG, it is not a claim about the mutant's
/// real structure, and the scale factor below is a proxy rather than a measured energy.
public struct Mutation: Sendable, Hashable, CustomStringConvertible {

    /// Zero-based position in the chain.
    public let position: Int
    public let from: AminoAcid
    public let to: AminoAcid

    public init(position: Int, from: AminoAcid, to: AminoAcid) {
        self.position = position
        self.from = from
        self.to = to
    }

    /// The usual one-based notation: `A53T`.
    public var description: String {
        "\(from.code)\(position + 1)\(to.code)"
    }

    /// Parse `A53T` against a sequence, checking the wild-type residue matches.
    ///
    /// The check is the point: a mutation written against the wrong numbering, or against a
    /// different isoform, silently perturbs the wrong residue - and the piece would still play,
    /// which is the worst kind of wrong.
    public static func parse(_ text: String, in sequence: [AminoAcid]) throws -> Mutation {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let first = trimmed.first, let last = trimmed.last, trimmed.count >= 3 else {
            throw Failure.unreadable(text)
        }
        let middle = trimmed.dropFirst().dropLast()
        guard let oneBased = Int(middle), oneBased >= 1 else { throw Failure.unreadable(text) }
        let position = oneBased - 1
        guard position < sequence.count else {
            throw Failure.outOfRange(position: oneBased, length: sequence.count)
        }
        let wild = AminoAcid(code: first)
        guard sequence[position] == wild else {
            throw Failure.wrongWildType(position: oneBased, expected: wild,
                                        found: sequence[position])
        }
        let mutant = AminoAcid(code: last)
        guard mutant != .unknown || last == "X" else { throw Failure.unreadable(text) }
        return Mutation(position: position, from: wild, to: mutant)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case outOfRange(position: Int, length: Int)
        case wrongWildType(position: Int, expected: AminoAcid, found: AminoAcid)

        public var description: String {
            switch self {
            case .unreadable(let text):
                "\"\(text)\" is not a substitution. Write it as A53T."
            case .outOfRange(let position, let length):
                "Residue \(position) is past the end of a \(length)-residue chain."
            case .wrongWildType(let position, let expected, let found):
                "Residue \(position) is \(found.threeLetterCode), not \(expected.threeLetterCode)"
                    + " - check the numbering or the isoform."
            }
        }
    }

    /// The sequence with the substitution made.
    public func applied(to sequence: [AminoAcid]) -> [AminoAcid] {
        guard position >= 0, position < sequence.count else { return sequence }
        var mutated = sequence
        mutated[position] = to
        return mutated
    }

    // MARK: - What it does to the fold

    /// How much of its native contact energy the substituted residue keeps, 0 to 1.
    ///
    /// **A proxy, and named as one.** The quantity that matters is how much of the residue's
    /// stabilising interaction survives the substitution, and the thing available on the device
    /// is the Kyte-Doolittle hydropathy each residue already carries. A buried hydrophobic
    /// replaced by a polar residue loses most of what it was contributing; a conservative
    /// substitution loses very little; and a substitution at an exposed position barely matters
    /// however large the change, which is why burial scales the whole thing.
    ///
    /// Glycine and proline are treated as more disruptive than their hydropathy suggests,
    /// because what they do to a backbone is not about burial at all: glycine adds
    /// conformational freedom and proline removes it, and both are common ways to break a
    /// helix. That is a rule of thumb, stated as one.
    public func retainedContactStrength(burial: Double) -> Double {
        let hydropathyLoss = Double(abs(from.hydropathy - to.hydropathy)) / 9.0   // 4.5 to -4.5
        var disruption = hydropathyLoss
        if to == .glycine || to == .proline || from == .glycine || from == .proline {
            disruption = Swift.max(disruption, 0.55)
        }
        let exposed = Swift.min(Swift.max(burial, 0), 1)
        return Swift.min(Swift.max(1 - disruption * exposed, 0.05), 1)
    }

    /// How buried a residue is, from its native contact count.
    ///
    /// Contact number is the standard cheap measure of burial, and the structure-based model
    /// already has the native contact map - so this costs nothing and needs no surface-area
    /// calculation. Normalised against a fully buried residue in a globular protein, which
    /// makes about a dozen contacts within the model's cutoff.
    public static func burial(contactCount: Int, fullyBuried: Int = 12) -> Double {
        Swift.min(Double(contactCount) / Double(Swift.max(fullyBuried, 1)), 1)
    }
}
