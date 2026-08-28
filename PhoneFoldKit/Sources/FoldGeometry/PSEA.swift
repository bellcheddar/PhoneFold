import Foundation
import simd
import FoldCore

/// Secondary structure assignment from CA positions alone (P-SEA).
///
/// Labesse, Colloc'h, Pothier & Mornon, CABIOS 1997, 13(3):291-295.
///
/// PLAN.md Phase 1 specifies P-SEA rather than DSSP for a concrete reason: DSSP needs
/// backbone amide and carbonyl geometry to compute hydrogen bonds, and early in a
/// trajectory only the CA positions are trustworthy. Genie 2 goes further and emits nothing
/// but CA, so a CA-only method is not a compromise here, it is the only option.
public enum PSEA {

    /// A distance or angle criterion: a target with a tolerance either side.
    struct Window: Sendable {
        let centre: Float
        let tolerance: Float
        var lower: Float { centre - tolerance }
        var upper: Float { centre + tolerance }
        func contains(_ value: Float) -> Bool { value >= lower && value <= upper }
        /// 1 at the centre, falling to 0 at the edges. Drives the renderer's morph, which
        /// needs structure to grow in rather than snap.
        func score(_ value: Float) -> Float {
            guard tolerance > 0 else { return contains(value) ? 1 : 0 }
            return max(0, 1 - abs(value - centre) / tolerance)
        }
    }

    // Published P-SEA parameters. Distances in angstroms, angles in degrees.
    static let helixD2 = Window(centre: 5.5, tolerance: 0.5)
    static let helixD3 = Window(centre: 5.3, tolerance: 0.5)
    static let helixD4 = Window(centre: 6.4, tolerance: 0.6)
    static let helixTheta = Window(centre: 89, tolerance: 12)
    static let helixAlpha = Window(centre: 50, tolerance: 20)

    static let sheetD2 = Window(centre: 6.7, tolerance: 0.6)
    static let sheetD3 = Window(centre: 9.9, tolerance: 0.9)
    static let sheetD4 = Window(centre: 12.4, tolerance: 1.1)
    static let sheetTheta = Window(centre: 124, tolerance: 14)
    /// The strand dihedral sits near 180 degrees and wraps, so it is tested on the absolute
    /// value against 180 rather than on the signed angle.
    static let sheetAlpha = Window(centre: 180, tolerance: 45)

    /// Assign three-state secondary structure to a CA trace.
    ///
    /// Faithful to the published algorithm, which is more than a per-residue threshold test:
    ///
    /// 1. A **strict** and a **relaxed** criterion are evaluated per residue.
    /// 2. A helix needs **5 consecutive** strict residues to seed; a strand needs **4**, or
    ///    **3** if that short run also makes at least 5 inter-strand CA contacts between
    ///    4.2 and 5.2 A. That contact test is what distinguishes a real beta strand, which
    ///    pairs with another strand, from an incidentally extended stretch of coil.
    /// 3. Seeded regions are then **extended by one residue** at each end, if that residue
    ///    meets the relaxed criterion.
    ///
    /// Note that `d2` plays no part in the helix test. It is quoted in the paper's table but
    /// is not used in the algorithm, and requiring it costs real helices.
    ///
    /// Residues too close to a terminus for the window are coil with zero confidence, which
    /// is honest: there is no evidence either way.
    public static func assign(caPositions ca: [SIMD3<Float>]) -> [SSAssignment] {
        let n = ca.count
        guard n > 5 else { return [SSAssignment](repeating: .unassigned, count: n) }

        // Index convention, matching the paper: measurements at i span the window i-1 ... i+3.
        var d2 = [Float](repeating: .nan, count: n)
        var d3 = [Float](repeating: .nan, count: n)
        var d4 = [Float](repeating: .nan, count: n)
        var theta = [Float](repeating: .nan, count: n)
        var alpha = [Float](repeating: .nan, count: n)

        for i in 1..<(n - 1) {
            d2[i] = simd_distance(ca[i - 1], ca[i + 1])
            theta[i] = angle(ca[i - 1], ca[i], ca[i + 1])
        }
        for i in 1..<(n - 2) {
            d3[i] = simd_distance(ca[i - 1], ca[i + 2])
            alpha[i] = dihedral(ca[i - 1], ca[i], ca[i + 1], ca[i + 2])
        }
        for i in 1..<(n - 3) {
            d4[i] = simd_distance(ca[i - 1], ca[i + 3])
        }

        func inRange(_ v: Float, _ w: Window) -> Bool { v.isFinite && w.contains(v) }

        var strictHelix = [Bool](repeating: false, count: n)
        var relaxedHelix = [Bool](repeating: false, count: n)
        var strictSheet = [Bool](repeating: false, count: n)
        var relaxedSheet = [Bool](repeating: false, count: n)

        for i in 0..<n {
            relaxedHelix[i] = inRange(d3[i], helixD3) || inRange(theta[i], helixTheta)
            strictHelix[i] = (inRange(d3[i], helixD3) && inRange(d4[i], helixD4))
                || (inRange(theta[i], helixTheta) && inRange(alpha[i], helixAlpha))

            relaxedSheet[i] = inRange(d3[i], sheetD3)
            let byDistance = inRange(d2[i], sheetD2) && inRange(d3[i], sheetD3)
                && inRange(d4[i], sheetD4)
            // The strand dihedral straddles +/-180 degrees, so it is two intervals.
            let dihedralOK = alpha[i].isFinite
                && ((alpha[i] >= -180 && alpha[i] <= -125) || (alpha[i] >= 145 && alpha[i] <= 180))
            let byAngle = inRange(theta[i], sheetTheta) && dihedralOK
            strictSheet[i] = byDistance || byAngle
        }

        var helixMask = maskConsecutive(strictHelix, 5)
        helixMask = extendRegions(helixMask, allowing: relaxedHelix)

        let longStrands = maskConsecutive(strictSheet, 4)
        let shortStrands = maskRegionsWithContacts(
            maskConsecutive(strictSheet, 3), ca: ca,
            minimumContacts: 5, minimumDistance: 4.2, maximumDistance: 5.2)
        var sheetMask = zip(longStrands, shortStrands).map { $0 || $1 }
        sheetMask = extendRegions(sheetMask, allowing: relaxedSheet)

        return (0..<n).map { i in
            if helixMask[i] {
                return SSAssignment(structure: .helix,
                                    confidence: confidence(i, strict: strictHelix,
                                                           d: [d3[i], d4[i]],
                                                           w: [helixD3, helixD4]))
            }
            if sheetMask[i] {
                return SSAssignment(structure: .sheet,
                                    confidence: confidence(i, strict: strictSheet,
                                                           d: [d2[i], d3[i], d4[i]],
                                                           w: [sheetD2, sheetD3, sheetD4]))
            }
            return .unassigned
        }
    }

    /// Per-residue confidence for the renderer's morph: high where the residue itself meets
    /// the strict criterion and its measurements sit centrally in their windows, lower where
    /// it was only picked up by seeding or extension.
    static func confidence(_ i: Int, strict: [Bool], d: [Float], w: [Window]) -> Float {
        guard strict[i] else { return 0.35 }
        var lowest: Float = 1
        for (value, window) in zip(d, w) where value.isFinite {
            lowest = min(lowest, window.score(value))
        }
        return max(0.4, min(1, 0.4 + 0.6 * lowest))
    }

    /// True for every element of any run of at least `count` consecutive true values.
    static func maskConsecutive(_ mask: [Bool], _ count: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        guard count > 0, mask.count >= count else { return out }
        var run = 0
        for i in mask.indices {
            run = mask[i] ? run + 1 : 0
            if run >= count {
                for k in (i - run + 1)...i { out[k] = true }
            }
        }
        return out
    }

    /// Grow each true region by at most one element on each side, where `allowing` permits.
    static func extendRegions(_ base: [Bool], allowing permitted: [Bool]) -> [Bool] {
        var out = base
        for i in base.indices where base[i] {
            if i > 0, !base[i - 1], permitted[i - 1] { out[i - 1] = true }
            if i < base.count - 1, !base[i + 1], permitted[i + 1] { out[i + 1] = true }
        }
        return out
    }

    /// Keep only those candidate regions that make enough CA contacts in a distance shell.
    ///
    /// A beta strand pairs with another strand. The 4.2 to 5.2 A shell deliberately excludes
    /// the 3.8 A bond to a neighbour and the ~6.7 A span to i+2, so what it counts is
    /// contact between strands rather than along one.
    static func maskRegionsWithContacts(_ candidates: [Bool], ca: [SIMD3<Float>],
                                        minimumContacts: Int,
                                        minimumDistance: Float,
                                        maximumDistance: Float) -> [Bool] {
        var out = [Bool](repeating: false, count: candidates.count)
        var i = 0
        while i < candidates.count {
            guard candidates[i] else { i += 1; continue }
            var end = i
            while end + 1 < candidates.count, candidates[end + 1] { end += 1 }

            var contacts = 0
            for a in i...end {
                for b in ca.indices where abs(b - a) > 2 {
                    let d = simd_distance(ca[a], ca[b])
                    if d >= minimumDistance && d <= maximumDistance { contacts += 1 }
                }
            }
            if contacts >= minimumContacts {
                for k in i...end { out[k] = true }
            }
            i = end + 1
        }
        return out
    }

    // MARK: - Geometry

    /// Angle at `b`, in degrees.
    @inlinable
    public static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                             _ c: SIMD3<Float>) -> Float {
        let u = a - b, v = c - b
        let lengths = simd_length(u) * simd_length(v)
        guard lengths > 1e-6 else { return 0 }
        return acos(min(max(simd_dot(u, v) / lengths, -1), 1)) * 180 / .pi
    }

    /// Dihedral about the b-c bond, in degrees, in -180...180.
    @inlinable
    public static func dihedral(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                _ c: SIMD3<Float>, _ d: SIMD3<Float>) -> Float {
        let b1 = b - a, b2 = c - b, b3 = d - c
        let n1 = simd_cross(b1, b2)
        let n2 = simd_cross(b2, b3)
        let m = simd_cross(n1, simd_normalize(b2))
        let x = simd_dot(n1, n2)
        let y = simd_dot(m, n2)
        guard x.isFinite, y.isFinite else { return 0 }
        // Negated: this is the IUPAC sign convention, in which a right-handed alpha helix
        // has a CA virtual dihedral near +50 degrees. Without the minus it reads -50, the
        // P-SEA helix criterion of 50 +/- 20 never fires, and helix detection falls back to
        // distances alone. On myoglobin that was 2 residues passing the angle test out of
        // 153, and 118 of them are helix.
        return -atan2(y, x) * 180 / .pi
    }
}

/// Temporal smoothing of secondary structure across a trajectory.
///
/// A per-frame assignment flickers: one frame's helix becomes the next frame's coil and the
/// renderer strobes. PLAN.md asks for roughly three frames of hysteresis. A residue must be
/// assigned the same new state for `window` consecutive frames before it changes.
public struct SSHysteresis: Sendable {
    public let window: Int
    private var current: [SSAssignment]
    private var candidate: [SecondaryStructure]
    private var streak: [Int]

    public init(window: Int = 3, residueCount: Int) {
        self.window = max(1, window)
        self.current = [SSAssignment](repeating: .unassigned, count: residueCount)
        self.candidate = [SecondaryStructure](repeating: .coil, count: residueCount)
        self.streak = [Int](repeating: 0, count: residueCount)
    }

    /// Feed one frame's raw assignment and get the smoothed one.
    ///
    /// Confidence follows the incoming frame immediately even when the state is held, so the
    /// renderer's morph stays live while the discrete state stays stable.
    public mutating func smooth(_ raw: [SSAssignment]) -> [SSAssignment] {
        guard raw.count == current.count else {
            current = raw
            candidate = raw.map(\.structure)
            streak = [Int](repeating: window, count: raw.count)
            return raw
        }
        for i in raw.indices {
            let incoming = raw[i].structure
            if incoming == current[i].structure {
                streak[i] = 0
                current[i] = SSAssignment(structure: current[i].structure,
                                          confidence: raw[i].confidence)
                continue
            }
            if incoming == candidate[i] {
                streak[i] += 1
            } else {
                candidate[i] = incoming
                streak[i] = 1
            }
            if streak[i] >= window {
                current[i] = raw[i]
                streak[i] = 0
            } else {
                current[i] = SSAssignment(structure: current[i].structure,
                                          confidence: raw[i].confidence)
            }
        }
        return current
    }
}
