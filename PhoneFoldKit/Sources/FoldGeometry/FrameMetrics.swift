import Foundation
import simd
import FoldCore

/// Per-frame scalar descriptors of a structure.
///
/// These are the numbers the score and the readouts consume: radius of gyration drives tempo
/// and register, confidence drives the filter, and contact order says how much of the
/// structure is long-range, which is what makes a fold sound resolved rather than merely
/// compact.
public struct FrameMetrics: Sendable, Equatable {
    /// Radius of gyration in angstroms.
    public let radiusOfGyration: Float
    /// Relative contact order: mean sequence separation of contacts, divided by chain length.
    /// Low for a helical bundle, high for a knotted or beta-rich fold.
    public let contactOrder: Float
    /// Number of contacts currently satisfied.
    public let contactCount: Int
    /// Fraction of hydrophobic residues whose neighbour count puts them in the core.
    public let buriedHydrophobicFraction: Float
    public let meanConfidence: Float
    public let minimumConfidence: Float

    /// How compact the structure is relative to a folded protein of the same length.
    ///
    /// A compact globular chain has a radius of gyration near `2.2 * N^0.38` angstroms; the
    /// formula was checked against experimental ubiquitin, which it predicts as 11.4 A
    /// against a measured 11.49 A. Around 1 is folded, well above 1 is extended. This is the
    /// cheap, model-free compactness test the generator uses to reject bad samples.
    public let compactness: Float

    public static func expectedRadiusOfGyration(residueCount n: Int) -> Float {
        guard n > 1 else { return 0 }
        return 2.2 * pow(Float(n), 0.38)
    }
}

public enum Metrics {

    /// Neighbour count within this radius above which a residue counts as buried.
    public static let burialRadius: Float = 10.0
    public static let burialNeighbourThreshold = 16

    public static func radiusOfGyration(_ ca: [SIMD3<Float>]) -> Float {
        guard !ca.isEmpty else { return 0 }
        var centre = SIMD3<Float>.zero
        for p in ca { centre += p }
        centre /= Float(ca.count)
        var sum: Float = 0
        for p in ca { sum += simd_length_squared(p - centre) }
        return (sum / Float(ca.count)).squareRoot()
    }

    /// Relative contact order (Plaxco, Simons & Baker, J. Mol. Biol. 1998, 277:985).
    ///
    /// Zero when there are no contacts, which is correct rather than undefined: a fully
    /// extended chain has no contact order.
    public static func relativeContactOrder(_ contacts: [(Int, Int)], residueCount n: Int)
        -> Float {
        guard !contacts.isEmpty, n > 0 else { return 0 }
        var total = 0
        for (i, j) in contacts { total += abs(j - i) }
        return Float(total) / (Float(contacts.count) * Float(n))
    }

    /// Fraction of hydrophobic residues that are buried, by neighbour count.
    ///
    /// A crude proxy for solvent accessibility, and deliberately so: a proper calculation
    /// needs side chains, and there are none here. It moves in the right direction as a core
    /// packs, which is what the score needs.
    public static func buriedHydrophobicFraction(_ ca: [SIMD3<Float>],
                                                 residues: [AminoAcid]) -> Float {
        let hydrophobic = residues.indices.filter { residues[$0].isHydrophobic }
        guard !hydrophobic.isEmpty, ca.count == residues.count else { return 0 }
        var buried = 0
        for i in hydrophobic {
            var neighbours = 0
            for j in ca.indices where j != i && simd_distance(ca[i], ca[j]) <= burialRadius {
                neighbours += 1
            }
            if neighbours >= burialNeighbourThreshold { buried += 1 }
        }
        return Float(buried) / Float(hydrophobic.count)
    }

    public static func compute(caPositions ca: [SIMD3<Float>],
                               residues: [AminoAcid],
                               confidence: [Float],
                               contactCutoff: Float = 8.0,
                               minimumSeparation: Int = 3) -> FrameMetrics {
        let contacts = ContactTracker.contactMap(caPositions: ca, cutoff: contactCutoff,
                                                 minimumSeparation: minimumSeparation)
        let rg = radiusOfGyration(ca)
        let expected = FrameMetrics.expectedRadiusOfGyration(residueCount: ca.count)
        let finite = confidence.filter { $0.isFinite }
        return FrameMetrics(
            radiusOfGyration: rg,
            contactOrder: relativeContactOrder(contacts, residueCount: ca.count),
            contactCount: contacts.count,
            buriedHydrophobicFraction: buriedHydrophobicFraction(ca, residues: residues),
            meanConfidence: finite.isEmpty ? 0 : finite.reduce(0, +) / Float(finite.count),
            minimumConfidence: finite.min() ?? 0,
            compactness: expected > 0 ? rg / expected : 0)
    }
}
