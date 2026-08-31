import Foundation
import simd

/// Which residue somebody just pinched.
///
/// PLAN.md Phase 5c: "look-and-pinch on a residue to pin a label and solo its note."
///
/// **One collision box for the protein, not one per residue.** The obvious reading of "pinch on
/// a residue" is an input target per residue, which for a 300-residue protein is 300 entities
/// with 300 collision shapes rebuilt as the fold changes shape sixty times a second. The pinch
/// already arrives with a point in space; turning that point into a residue is a search over a
/// few hundred coordinates, which costs nothing and is a pure function - so it lives here,
/// where it can be tested, rather than in a hit-test nobody can inspect.
public enum ResiduePicking {

    /// How close a pinch has to land, in angstroms, to count as being *on* a residue.
    ///
    /// Six: the tube is drawn about 2 A in radius and a pinch is not precise, so a couple of
    /// angstroms of slack on either side is generous without reaching across the gap between
    /// one strand and the next, which in a beta sheet is about 4.8 A between neighbouring
    /// chains. Larger and a pinch aimed at empty space between two strands silently picks one.
    public static let defaultTolerance: Float = 6

    /// The residue nearest `point`, or nil if the pinch landed on nothing.
    ///
    /// `point` is in the protein's own space - angstroms, unscaled, unrotated - because that is
    /// the space the coordinates are in and the caller has an entity transform to convert
    /// through. Converting the coordinates into the world instead would mean transforming a few
    /// hundred points per pinch rather than one.
    ///
    /// **Nil rather than a nearest-anything.** A pinch that lands in the hollow of a protein is
    /// a pinch at nothing, and answering it with whichever residue happens to be least far away
    /// pins a label to a place the hand was not pointing.
    public static func residue(at point: SIMD3<Float>,
                               in caPositions: [SIMD3<Float>],
                               tolerance: Float = defaultTolerance) -> Int? {
        guard !caPositions.isEmpty, tolerance > 0 else { return nil }
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        var best = -1
        var bestDistanceSquared = tolerance * tolerance
        for (index, position) in caPositions.enumerated() {
            let delta = position - point
            let distanceSquared = simd_length_squared(delta)
            // Strictly closer, so the earliest residue wins a tie. A tie is not a coincidence
            // here: a symmetric structure can put two residues equidistant from a pinch, and
            // an answer that depended on iteration order would flicker between them.
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                best = index
            }
        }
        return best >= 0 ? best : nil
    }
}
