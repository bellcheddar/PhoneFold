import Foundation
import simd

/// The unfolded state a fold starts from: a self-avoiding random coil.
///
/// **Not a straight extended chain**, which is what "unfolded" is often drawn as and is not
/// what a denatured protein is. Backbone angles are drawn across the range a CA trace actually
/// occupies and dihedrals uniformly around the circle, with rejection against a hard-sphere
/// clash - the freely-rotating self-avoiding walk that is the standard model of a denatured
/// chain. Its radius of gyration then lands on the experimental scaling for denatured proteins,
/// `Rg = 2.54 * N^0.522` (Kohn et al., PNAS 101:12491, 2004), which `UnfoldedChainTests`
/// checks rather than assumes.
///
/// Ported from `random_coil` in `Tools/go_model_fold.py`, which is what produced every
/// starting structure behind the measurements in METRICS.md.
public enum UnfoldedChain {

    /// Kohn's scaling for the radius of gyration of a denatured chain, in angstroms.
    public static func expectedRadiusOfGyration(residues: Int) -> Double {
        2.54 * pow(Double(residues), 0.522)
    }

    /// The next alpha carbon from the previous three, at a given bond angle and dihedral.
    ///
    /// Natural extension reference frame: build an orthonormal frame on the last two bonds and
    /// place the new atom in it. Doing this by rotating vectors instead accumulates error over
    /// a few hundred residues and quietly stops producing the bond length it was asked for.
    ///
    /// **`phi` is in the same convention as `StructureBasedModel.dihedral`**, so that reading a
    /// chain's dihedrals and placing them back reproduces the chain. The construction below
    /// naturally yields the *negative* of that convention - work the cross products through and
    /// the measured dihedral comes out as `atan2(-sin phi, cos phi)` - so the sine term is
    /// negated here. Nothing noticed while the only caller was the random coil, where `phi` is
    /// drawn uniformly around the circle and a sign flip is invisible; the morph, which reads
    /// real dihedrals and replays them, noticed immediately.
    static func place(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                      bond: Double, theta: Double, phi: Double) -> SIMD3<Double> {
        let b1 = c - b, b2 = b - a
        let e1 = simd_normalize(b1)
        var n1 = simd_cross(b2, b1)
        let length = simd_length(n1)
        // Three collinear points leave the dihedral undefined; any perpendicular will do.
        n1 = length > 1e-9 ? n1 / length : simd_normalize(perpendicular(to: e1))
        let e2 = simd_cross(n1, e1)
        return c + bond * (-cos(theta) * e1 + sin(theta) * (cos(phi) * e2 - sin(phi) * n1))
    }

    static func perpendicular(to v: SIMD3<Double>) -> SIMD3<Double> {
        abs(v.x) < 0.9 ? simd_cross(v, SIMD3<Double>(1, 0, 0))
                       : simd_cross(v, SIMD3<Double>(0, 1, 0))
    }

    /// Build a coil of `residues` alpha carbons.
    ///
    /// - Parameters:
    ///   - clash: hard-sphere radius rejected against, in angstroms.
    ///   - attempts: tries per residue before backing up two residues and trying again.
    ///
    /// **Backtracking is not optional.** A self-avoiding walk paints itself into corners, and
    /// the first version of this accepted a clashing candidate rather than backing up. That
    /// produced a chain that was *far too compact* to be a denatured state - measured at
    /// Rg 14.4 A for 76 residues against Kohn's 24.4 - because every corner it walked into
    /// collapsed the chain onto itself instead of being rejected. Backing up two residues is
    /// what the reference implementation does and what the scaling law requires.
    public static func build(residues n: Int, seed: UInt64 = 1, bond: Double = 3.8,
                             angleRange: ClosedRange<Double> = 85...145,
                             clash: Double = 4.0, attempts: Int = 200) -> [SIMD3<Double>] {
        guard n > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        var x = [SIMD3<Double>](repeating: .zero, count: n)
        if n > 1 { x[1] = SIMD3<Double>(bond, 0, 0) }
        if n > 2 {
            let t = degreesToRadians(rng.uniform(in: angleRange))
            x[2] = x[1] + bond * SIMD3<Double>(-cos(t), sin(t), 0)
        }
        var k = 3
        var stuck = 0
        while k < n {
            var placed = false
            for _ in 0..<attempts {
                let theta = degreesToRadians(rng.uniform(in: angleRange))
                let phi = rng.uniform(in: -Double.pi ... Double.pi)
                let candidate = place(x[k - 3], x[k - 2], x[k - 1], bond: bond,
                                      theta: theta, phi: phi)
                var clear = true
                for i in 0..<Swift.max(k - 2, 0) where simd_length(x[i] - candidate) <= clash {
                    clear = false
                    break
                }
                if clear {
                    x[k] = candidate
                    placed = true
                    break
                }
            }
            if placed {
                k += 1
                stuck = 0
            } else {
                // Back up rather than accept a clash. See the note on `attempts`.
                k = Swift.max(3, k - 2)
                stuck += 1
                // A walk that cannot escape after this many backtracks is not going to; take
                // the chain as it stands rather than hanging the app on a rare seed.
                if stuck > 200 { break }
            }
        }
        return x
    }

    static func degreesToRadians(_ d: Double) -> Double { d * .pi / 180 }
}

extension SplitMix64 {
    mutating func uniform(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + uniform() * (range.upperBound - range.lowerBound)
    }
}
