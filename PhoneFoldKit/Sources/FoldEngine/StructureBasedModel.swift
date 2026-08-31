import Foundation
import simd
import FoldCore

/// A CA-level structure-based (Gō) model: folds a chain from extended toward a native state.
///
/// **What this is, and what it is not.** This is a funnelled coarse-grained simulation
/// *towards a structure that is already known*. It is not a structure prediction: the native
/// coordinates define the energy landscape, so the fold it produces is a real dynamical
/// pathway into an answer it was handed. Every frame is computed on the device - nothing here
/// is a precomputed trajectory - but the app must never present it as a prediction.
///
/// The form is Clementi, Nymeyer and Onuchic (2000): harmonic bonds and angles, a two-term
/// dihedral, a 12-10 well on every native contact, and pure repulsion on everything else.
/// Integrated with BAOAB Langevin dynamics.
///
/// Ported from `Tools/go_model_fold.c`, which is the reference implementation and the oracle
/// this is tested against: the C binary's `--forces` mode dumps the force on every particle
/// for a given configuration, and `StructureBasedModelTests` requires this Swift to agree
/// with it. Matching forces is a far stronger check than matching a folded structure, because
/// two different force fields can both fold a small protein.
public struct StructureBasedModel: Sendable {

    public struct Parameters: Sendable {
        /// Harmonic bond stiffness.
        public var bondStiffness: Double = 100
        /// Harmonic angle stiffness.
        public var angleStiffness: Double = 20
        /// Dihedral term, the `sin(dphi) + 1.5 sin(3 dphi)` form.
        public var dihedralStiffness: Double = 1
        /// Depth of a native contact's well.
        public var epsilon: Double = 1
        /// A point substitution to represent, or nil for the wild type.
        public var mutation: Mutation?
        /// Radius of the non-native repulsion.
        public var nonNativeSigma: Double = 4
        /// Two residues are a native contact below this separation, in angstroms.
        public var contactCutoff: Double = 8
        /// How far apart in sequence a pair must be to count at all.
        public var minimumSeparation: Int = 3
        public var timeStep: Double = 0.005
        public var friction: Double = 1

        /// Starting temperature, in units of the contact well depth.
        public var temperature: Double = 1.0
        /// Temperature at the end of the run.
        ///
        /// **Annealed, not isothermal, and this is a deliberate compromise.** A single
        /// temperature near the folding temperature gives a genuine two-state transition -
        /// and genuine reversals and kinetic traps with it. Cooling across the run keeps the
        /// physics and removes the coin flip, at the cost of no longer measuring a folding
        /// rate. PhoneFold shows a fold; it does not measure one.
        ///
        /// **0.10, and the number matters more than the run length.** Measured on ubiquitin
        /// from a coil 16.06 A away in distance-matrix RMSD, at 2,000,000 steps throughout:
        ///
        ///     kT_final 0.55 -> Q 0.967, dRMSD 0.86 A
        ///     kT_final 0.30 -> Q 1.000, dRMSD 0.49 A
        ///     kT_final 0.10 -> Q 1.000, dRMSD 0.23 A
        ///
        /// Cooling further costs nothing - the wall clock is identical - while *running*
        /// longer buys almost nothing: 4,000,000 steps at 0.10 measured 0.26 A, no better than
        /// 2,000,000, and 8,000,000 at 0.05 reached 0.16 A for four times the time. The fold
        /// arrives long before the run ends; what decides whether it settles onto the
        /// reference is how cold it gets, not how long it wanders.
        public var finalTemperature: Double = 0.10

        /// Beyond this separation the non-native repulsion is not computed, in angstroms.
        ///
        /// The term is `(sigma/r)^12` with sigma 4 A, so at 10 A it is **0.000017** - seventeen
        /// parts in a million of the well depth, on a pair that is already only repulsive.
        /// Ignoring it costs nothing measurable and skips most of the work: on ubiquitin only
        /// **6% of non-native pairs unfolded and 9% folded** are within 10 A, out of 2,517.
        /// Zero disables the cutoff and computes every pair, which is what the force test
        /// against the C reference uses.
        public var repulsionCutoff: Double = 10
        /// Extra margin on the neighbour list, so it survives a few hundred steps of motion.
        public var neighbourSkin: Double = 2

        public var steps: Int = 3_000_000
        /// How many frames the run emits, start and end included.
        public var frameCount: Int = 180
        public var seed: UInt64 = 1

        public init() {}
    }

    public let native: [SIMD3<Double>]
    public let parameters: Parameters

    // Reference internal coordinates.
    private let bondLength: [Double]
    private let bondAngle: [Double]
    private let dihedralAngle: [Double]
    // Native contacts and their equilibrium separations, and everything else.
    private let nativeI: [Int32], nativeJ: [Int32], nativeSigma: [Double]
    /// Per-contact multiplier on `epsilon`, 1 everywhere in a wild-type fold.
    ///
    /// This is how a substitution is represented: the native structure is kept and the
    /// interactions the substituted residue makes are weakened, which is what structure-based
    /// models have done since Clementi, Nymeyer and Onuchic. The mutant then folds toward the
    /// same target less well rather than toward a different one - which is honest, because
    /// nothing on this device can predict what a mutant's structure would be.
    private let nativeStrength: [Double]
    private let otherI: [Int32], otherJ: [Int32]

    public var residueCount: Int { native.count }
    public var nativeContactCount: Int { nativeI.count }
    /// Alias used by the per-residue breakdown, which iterates the contact list.
    public var contactCount: Int { nativeI.count }

    /// One native contact: the two residues and the separation they sit at natively.
    public func contact(at index: Int) -> (i: Int, j: Int, sigma: Double) {
        (Int(nativeI[index]), Int(nativeJ[index]), nativeSigma[index])
    }

    public init(native: [SIMD3<Double>], parameters: Parameters = .init()) {
        self.native = native
        self.parameters = parameters
        let n = native.count

        var r0 = [Double](), t0 = [Double](), p0 = [Double]()
        for i in 0..<Swift.max(n - 1, 0) { r0.append(simd_length(native[i + 1] - native[i])) }
        for i in 0..<Swift.max(n - 2, 0) {
            t0.append(Self.angle(native, i, i + 1, i + 2))
        }
        for i in 0..<Swift.max(n - 3, 0) {
            p0.append(Self.dihedral(native, i, i + 1, i + 2, i + 3))
        }
        bondLength = r0; bondAngle = t0; dihedralAngle = p0

        var ni = [Int32](), nj = [Int32](), ns = [Double](), oi = [Int32](), oj = [Int32]()
        for i in 0..<n {
            var j = i + parameters.minimumSeparation
            while j < n {
                let d = simd_length(native[j] - native[i])
                if d < parameters.contactCutoff {
                    ni.append(Int32(i)); nj.append(Int32(j)); ns.append(d)
                } else {
                    oi.append(Int32(i)); oj.append(Int32(j))
                }
                j += 1
            }
        }
        nativeI = ni; nativeJ = nj; nativeSigma = ns; otherI = oi; otherJ = oj

        if let mutation = parameters.mutation, mutation.position >= 0, mutation.position < n {
            // Burial from the residue's own contact count, which the map above already has -
            // no surface-area calculation, and the same measure the model itself is built on.
            var contactsAt = 0
            for index in 0..<ni.count
            where Int(ni[index]) == mutation.position || Int(nj[index]) == mutation.position {
                contactsAt += 1
            }
            let retained = mutation.retainedContactStrength(
                burial: Mutation.burial(contactCount: contactsAt))
            nativeStrength = (0..<ni.count).map { index in
                let touches = Int(ni[index]) == mutation.position
                    || Int(nj[index]) == mutation.position
                return touches ? retained : 1
            }
        } else {
            nativeStrength = [Double](repeating: 1, count: ni.count)
        }
    }

    // MARK: - Geometry

    static func angle(_ x: [SIMD3<Double>], _ a: Int, _ b: Int, _ c: Int) -> Double {
        let u = x[a] - x[b], v = x[c] - x[b]
        let cosine = simd_dot(u, v) / (simd_length(u) * simd_length(v))
        return acos(Swift.min(Swift.max(cosine, -1), 1))
    }

    static func dihedral(_ x: [SIMD3<Double>], _ a: Int, _ b: Int, _ c: Int,
                         _ d: Int) -> Double {
        let b1 = x[b] - x[a], b2 = x[c] - x[b], b3 = x[d] - x[c]
        let n1 = simd_cross(b1, b2), n2 = simd_cross(b2, b3)
        let m = simd_cross(n1, b2 / simd_length(b2))
        return atan2(simd_dot(m, n2), simd_dot(n1, n2))
    }

    // MARK: - Forces

    /// The force on every particle for one configuration.
    ///
    /// Written as one function over flat arrays rather than composed out of per-term helpers:
    /// this runs several million times in a fold and every allocation in it would be paid for
    /// n squared times.
    /// - Parameter nonNativePairs: a flat `[i, j, i, j, ...]` neighbour list to use for the
    ///   repulsion instead of every non-native pair. `nil` computes them all, which is what
    ///   the comparison against the C reference needs.
    public func forces(_ x: [SIMD3<Double>],
                       nonNativePairs: [Int32]? = nil) -> [SIMD3<Double>] {
        let n = x.count
        var f = [SIMD3<Double>](repeating: .zero, count: n)
        let p = parameters

        // Bonds.
        for i in 0..<(n - 1) {
            let d = x[i + 1] - x[i]
            let r = simd_length(d)
            let c = 2 * p.bondStiffness * (r - bondLength[i]) / r
            f[i] += d * c
            f[i + 1] -= d * c
        }

        // Angles.
        for i in 0..<Swift.max(n - 2, 0) {
            let a = i, b = i + 1, c = i + 2
            let u = x[a] - x[b], v = x[c] - x[b]
            let lu = simd_length(u), lv = simd_length(v)
            var cs = simd_dot(u, v) / (lu * lv)
            cs = Swift.min(Swift.max(cs, -1), 1)
            let theta = acos(cs)
            let sn = (1 - cs * cs > 1e-12) ? (1 - cs * cs).squareRoot() : 1e-6
            let dE = 2 * p.angleStiffness * (theta - bondAngle[i])
            let dca = v / (lu * lv) - u * (cs / (lu * lu))
            let dcc = u / (lu * lv) - v * (cs / (lv * lv))
            let k = -dE / sn
            let fa = dca * -k, fc = dcc * -k
            f[a] += fa
            f[c] += fc
            f[b] -= fa + fc
        }

        // Dihedrals.
        for i in 0..<Swift.max(n - 3, 0) {
            let a = i, b = i + 1, c = i + 2, d = i + 3
            let b1 = x[b] - x[a], b2 = x[c] - x[b], b3 = x[d] - x[c]
            let n1 = simd_cross(b1, b2), n2 = simd_cross(b2, b3)
            let n1sq = simd_dot(n1, n1), n2sq = simd_dot(n2, n2)
            let lb2 = simd_length(b2)
            let m = simd_cross(n1, b2 / lb2)
            let phi = atan2(simd_dot(m, n2), simd_dot(n1, n2))
            let dp = phi - dihedralAngle[i]
            let dE = p.dihedralStiffness * (sin(dp) + 1.5 * sin(3 * dp))
            let da = n1 * (lb2 / n1sq)
            let dd = n2 * (-lb2 / n2sq)
            let pp = simd_dot(b1, b2) / (lb2 * lb2), qq = simd_dot(b3, b2) / (lb2 * lb2)
            let db = da * (-1 - pp) + dd * qq
            let dc = da * pp + dd * (-1 - qq)
            let k = -dE
            f[a] += da * k
            f[b] += db * k
            f[c] += dc * k
            f[d] += dd * k
        }

        // Native contacts: a 12-10 well at the native separation.
        for index in 0..<nativeI.count {
            let i = Int(nativeI[index]), j = Int(nativeJ[index])
            let dv = x[j] - x[i]
            let r2 = simd_dot(dv, dv)
            let s2 = nativeSigma[index] * nativeSigma[index] / r2
            let s10 = s2 * s2 * s2 * s2 * s2, s12 = s10 * s2
            let g = dv * -(p.epsilon * nativeStrength[index] * 60 * (s10 - s12) / r2)
            f[i] -= g
            f[j] += g
        }

        // Everything else: repulsion only, which is what makes the funnel a funnel.
        func repel(_ i: Int, _ j: Int) {
            let dv = x[j] - x[i]
            let r2 = simd_dot(dv, dv)
            let s2 = p.nonNativeSigma * p.nonNativeSigma / r2
            let s12 = s2 * s2 * s2 * s2 * s2 * s2
            let g = dv * (12 * p.epsilon * s12 / r2)
            f[i] -= g
            f[j] += g
        }
        if let pairs = nonNativePairs {
            var index = 0
            while index + 1 < pairs.count {
                repel(Int(pairs[index]), Int(pairs[index + 1]))
                index += 2
            }
        } else {
            for index in 0..<otherI.count { repel(Int(otherI[index]), Int(otherJ[index])) }
        }
        return f
    }

    /// Non-native pairs currently within the cutoff plus the skin.
    ///
    /// A Verlet list: built with a margin so it stays valid while the chain moves, and rebuilt
    /// only when some atom has travelled far enough that a pair could have entered the cutoff
    /// unseen. Rebuilding every step would cost the O(n^2) sweep this exists to avoid.
    func neighbourList(_ x: [SIMD3<Double>]) -> [Int32] {
        let reach = parameters.repulsionCutoff + parameters.neighbourSkin
        guard parameters.repulsionCutoff > 0 else { return [] }
        var pairs: [Int32] = []
        pairs.reserveCapacity(otherI.count / 4)
        for index in 0..<otherI.count {
            let i = Int(otherI[index]), j = Int(otherJ[index])
            if simd_length(x[j] - x[i]) < reach {
                pairs.append(otherI[index]); pairs.append(otherJ[index])
            }
        }
        return pairs
    }

    /// Fraction of native contacts formed, the reaction coordinate this model is read by.
    public func fractionNative(_ x: [SIMD3<Double>], tolerance: Double = 1.2) -> Double {
        guard !nativeI.isEmpty else { return 0 }
        var formed = 0
        for index in 0..<nativeI.count {
            let d = simd_length(x[Int(nativeJ[index])] - x[Int(nativeI[index])])
            if d < nativeSigma[index] * tolerance { formed += 1 }
        }
        return Double(formed) / Double(nativeI.count)
    }

    // MARK: - Integration

    /// Run the fold, returning `parameters.frameCount` configurations from start to end.
    ///
    /// `shouldContinue` is polled once per emitted frame so a cancelled playback stops the
    /// simulation rather than running it out.
    public func fold(from start: [SIMD3<Double>],
                     progress: (@Sendable (Double) -> Void)? = nil,
                     shouldContinue: (@Sendable () -> Bool)? = nil) -> [[SIMD3<Double>]] {
        let p = parameters
        let n = start.count
        guard n == native.count, n > 3 else { return [] }

        var x = start
        var v = [SIMD3<Double>](repeating: .zero, count: n)
        var rng = SplitMix64(seed: p.seed)

        for i in 0..<n {
            let s = p.temperature.squareRoot()
            v[i] = SIMD3<Double>(rng.gaussian() * s, rng.gaussian() * s, rng.gaussian() * s)
        }
        // The neighbour list and the reference positions it was built from.
        let useList = p.repulsionCutoff > 0
        var neighbours = useList ? neighbourList(x) : []
        var listReference = x
        // Rebuild when any atom has moved half the skin: two atoms approaching from opposite
        // directions can then close the skin between them and no closer.
        let rebuildThreshold = p.neighbourSkin / 2

        var f = forces(x, nonNativePairs: useList ? neighbours : nil)

        let stride = Swift.max(p.steps / Swift.max(p.frameCount - 1, 1), 1)
        var frames: [[SIMD3<Double>]] = [x]
        frames.reserveCapacity(p.frameCount)

        let a = exp(-p.friction * p.timeStep)
        let halfStep = 0.5 * p.timeStep

        for step in 0..<p.steps {
            let t = Double(step) / Double(p.steps)
            let kT = p.temperature + (p.finalTemperature - p.temperature) * t
            let b = (kT * (1 - a * a)).squareRoot()

            for i in 0..<n { v[i] += f[i] * halfStep }
            for i in 0..<n { x[i] += v[i] * halfStep }
            for i in 0..<n {
                v[i] = SIMD3<Double>(a * v[i].x + b * rng.gaussian(),
                                     a * v[i].y + b * rng.gaussian(),
                                     a * v[i].z + b * rng.gaussian())
            }
            for i in 0..<n { x[i] += v[i] * halfStep }
            if useList {
                var worst = 0.0
                for i in 0..<n {
                    worst = Swift.max(worst, simd_length(x[i] - listReference[i]))
                    if worst > rebuildThreshold { break }
                }
                if worst > rebuildThreshold {
                    neighbours = neighbourList(x)
                    listReference = x
                }
            }
            f = forces(x, nonNativePairs: useList ? neighbours : nil)
            for i in 0..<n { v[i] += f[i] * halfStep }

            if (step + 1) % stride == 0, frames.count < p.frameCount {
                frames.append(x)
                progress?(Double(frames.count) / Double(p.frameCount))
                if let shouldContinue, !shouldContinue() { break }
            }
        }
        // The last frame is the fold's answer; emit it whatever the stride arithmetic did.
        if frames.count < p.frameCount || frames.last! != x { frames.append(x) }
        return frames
    }
}

/// A small, deterministic generator, so a seed reproduces a fold exactly.
///
/// Deliberately not `SystemRandomNumberGenerator`: a fold that cannot be replayed cannot be
/// compared against a previous run, and every measurement in METRICS.md depends on being able
/// to re-run one.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    /// Kept so a Box-Muller pair is not thrown away.
    private var spare: Double?

    init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
        for _ in 0..<16 { _ = next() }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Box-Muller, keeping the second of each pair.
    mutating func gaussian() -> Double {
        if let spare { self.spare = nil; return spare }
        var u1 = uniform()
        if u1 < 1e-300 { u1 = 1e-300 }
        let u2 = uniform()
        let r = (-2 * log(u1)).squareRoot()
        let theta = 2 * Double.pi * u2
        spare = r * sin(theta)
        return r * cos(theta)
    }
}
