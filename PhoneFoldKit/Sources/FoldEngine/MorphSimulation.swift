import Foundation
import simd
import FoldCore

/// A geometric morph from an unfolded coil into a known native structure.
///
/// **This is not folding, and the app must say so.** There is no energy, no dynamics and no
/// physics: it is an interpolation between two conformations, and its only virtues are that it
/// is instant and that its gradient is perfectly smooth. It is here as the honest baseline the
/// other two engines are judged against - if a real simulation does not look better than this,
/// the simulation is not earning its cost.
///
/// **Interpolated in torsion space, and what that does and does not fix.** Measured on
/// ubiquitin over 200 frames:
///
///     bond lengths      torsion 3.68-3.89 A    cartesian 0.55-3.89 A
///     closest approach  torsion 0.28 A         cartesian 0.34 A
///
/// So torsion space keeps the chain a chain - every CA-CA bond stays at a real distance, where
/// a Cartesian morph pulls the backbone through itself and its bonds collapse to a third of an
/// angstrom. What it does **not** do is prevent clashes: 0.28 A against 0.34 A is no
/// improvement at all, because interpolating torsions constrains the bonded geometry and says
/// nothing about whether two distant parts of the chain pass through each other. An earlier
/// version of this comment claimed torsion space fixed the clashing; it does not, and the
/// tests now measure both quantities so the claim cannot drift again.
///
/// A morph is therefore never physically valid. It is smooth and it is instant, and it is
/// labelled as an interpolation wherever it appears.
public struct MorphSimulation: Sendable {

    public struct Parameters: Sendable {
        public var frameCount: Int = 180
        /// Seed for the starting coil.
        public var seed: UInt64 = 1
        public init() {}
    }

    public let native: [SIMD3<Double>]
    public let parameters: Parameters

    public init(native: [SIMD3<Double>], parameters: Parameters = .init()) {
        self.native = native
        self.parameters = parameters
    }

    /// The backbone's internal coordinates: bond lengths, angles and dihedrals.
    static func internalCoordinates(_ x: [SIMD3<Double>])
        -> (bonds: [Double], angles: [Double], dihedrals: [Double]) {
        var bonds: [Double] = [], angles: [Double] = [], dihedrals: [Double] = []
        for i in 0..<Swift.max(x.count - 1, 0) { bonds.append(simd_length(x[i + 1] - x[i])) }
        for i in 0..<Swift.max(x.count - 2, 0) {
            angles.append(StructureBasedModel.angle(x, i, i + 1, i + 2))
        }
        for i in 0..<Swift.max(x.count - 3, 0) {
            dihedrals.append(StructureBasedModel.dihedral(x, i, i + 1, i + 2, i + 3))
        }
        return (bonds, angles, dihedrals)
    }

    /// Shortest-way interpolation between two angles.
    ///
    /// A dihedral lives on a circle, so interpolating -179 degrees to +179 degrees linearly
    /// spins the chain the long way round - 358 degrees of rotation to travel two. Every
    /// torsion in the chain doing that at once is a blur, not a morph.
    static func interpolateAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return a + delta * t
    }

    /// Rebuild a chain from its internal coordinates.
    static func build(bonds: [Double], angles: [Double], dihedrals: [Double],
                      origin: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let n = bonds.count + 1
        guard n >= 3, origin.count >= 3 else { return origin }
        var x = [SIMD3<Double>](repeating: .zero, count: n)
        // The first three atoms fix the chain's position and orientation, and they must still
        // obey the interpolated bond lengths and angle. Taking them straight from `origin` -
        // which is a linear interpolation of positions - was measured to shorten the first two
        // bonds well below 3 A, because a straight line between two conformations is shorter
        // than the arc the chain has to travel.
        x[0] = origin[0]
        let d01 = simd_length(origin[1] - origin[0]) > 1e-9
            ? simd_normalize(origin[1] - origin[0]) : SIMD3<Double>(1, 0, 0)
        x[1] = x[0] + d01 * bonds[0]
        // The third atom at the interpolated angle, in the plane the interpolation suggests.
        let v = origin[2] - origin[1]
        var perp = v - d01 * simd_dot(v, d01)
        perp = simd_length(perp) > 1e-9 ? simd_normalize(perp)
                                        : simd_normalize(UnfoldedChain.perpendicular(to: d01))
        x[2] = x[1] + bonds[1] * (-cos(angles[0]) * d01 + sin(angles[0]) * perp)
        for k in 3..<n {
            x[k] = UnfoldedChain.place(x[k - 3], x[k - 2], x[k - 1],
                                       bond: bonds[k - 1],
                                       theta: angles[k - 2],
                                       phi: dihedrals[k - 3])
        }
        return x
    }

    /// The morph, from an unfolded coil to the native structure.
    public func run(from start: [SIMD3<Double>]) -> [[SIMD3<Double>]] {
        let n = native.count
        guard start.count == n, n >= 4 else { return [] }
        let a = Self.internalCoordinates(start)
        let b = Self.internalCoordinates(native)
        let frames = Swift.max(parameters.frameCount, 2)

        // The first three atoms travel in a straight line, which is a rigid motion of the
        // whole molecule rather than a distortion of it.
        var out: [[SIMD3<Double>]] = []
        out.reserveCapacity(frames)
        for f in 0..<frames {
            let raw = Double(f) / Double(frames - 1)
            // Smoothstep, so the morph eases out of the coil and into the native rather than
            // starting and stopping abruptly.
            let t = raw * raw * (3 - 2 * raw)
            let bonds = zip(a.bonds, b.bonds).map { $0 + ($1 - $0) * t }
            let angles = zip(a.angles, b.angles).map { Self.interpolateAngle($0, $1, t) }
            let dihedrals = zip(a.dihedrals, b.dihedrals).map { Self.interpolateAngle($0, $1, t) }
            let origin = (0..<3).map { start[$0] + (native[$0] - start[$0]) * t }
            out.append(Self.build(bonds: bonds, angles: angles, dihedrals: dihedrals,
                                  origin: origin))
        }
        return out
    }

    /// The closest any two non-bonded alpha carbons come, over a whole trajectory.
    ///
    /// Kept as something the app can measure rather than something a comment claims - which is
    /// how the "torsion space fixes clashes" mistake was caught.
    public static func closestNonBondedApproach(_ frames: [[SIMD3<Double>]],
                                                separation: Int = 3) -> Double {
        var closest = Double.greatestFiniteMagnitude
        for frame in frames {
            for i in 0..<frame.count {
                var j = i + separation
                while j < frame.count {
                    closest = Swift.min(closest, simd_length(frame[j] - frame[i]))
                    j += 1
                }
            }
        }
        return closest == .greatestFiniteMagnitude ? 0 : closest
    }
}
