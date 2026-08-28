import Testing
import Foundation
import simd
@testable import FoldGeometry
import FoldCore

@Suite("Kabsch superposition")
struct SuperpositionTests {

    /// A deterministic, protein-like point set: an ideal alpha helix.
    static func helix(_ n: Int) -> [SIMD3<Float>] {
        (0..<n).map { k in
            let theta = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(theta), 2.3 * sin(theta), Float(k) * 1.5)
        }
    }

    static func rotationMatrix(axis: SIMD3<Float>, angle: Float) -> simd_float3x3 {
        let a = simd_normalize(axis)
        let q = simd_quatf(angle: angle, axis: a)
        return simd_float3x3(q)
    }

    @Test("identical point sets give the identity and zero RMSD")
    func identity() throws {
        let p = Self.helix(30)
        let fit = try #require(Kabsch.superpose(mobile: p, onto: p))
        #expect(fit.rmsd < 1e-4)
        for point in p {
            #expect(simd_distance(fit.apply(point), point) < 1e-3)
        }
    }

    @Test("a pure translation is removed exactly")
    func translation() throws {
        let p = Self.helix(40)
        let offset = SIMD3<Float>(123.5, -47.25, 8.75)
        let q = p.map { $0 + offset }
        let fit = try #require(Kabsch.superpose(mobile: p, onto: q))
        #expect(fit.rmsd < 1e-3)
        for (a, b) in zip(fit.apply(p), q) {
            #expect(simd_distance(a, b) < 1e-2)
        }
    }

    /// The core property: a known rotation applied to a structure must be recovered.
    @Test("a known rotation is recovered", arguments: [
        (SIMD3<Float>(0, 0, 1), Float.pi / 4),
        (SIMD3<Float>(1, 0, 0), Float.pi / 3),
        (SIMD3<Float>(1, 1, 1), Float.pi * 0.9),
        (SIMD3<Float>(-2, 0.5, 3), Float.pi / 7),
    ])
    func knownRotation(axis: SIMD3<Float>, angle: Float) throws {
        let p = Self.helix(50)
        let r = Self.rotationMatrix(axis: axis, angle: angle)
        let offset = SIMD3<Float>(10, -5, 3)
        let q = p.map { r * $0 + offset }

        let fit = try #require(Kabsch.superpose(mobile: p, onto: q))
        #expect(fit.rmsd < 1e-3, "should superpose exactly, got \(fit.rmsd)")
        for (a, b) in zip(fit.apply(p), q) {
            #expect(simd_distance(a, b) < 1e-2)
        }
    }

    /// The failure mode Horn's method exists to avoid. A mirrored structure is NOT
    /// superposable by a rotation, so the fit must be poor. If this ever passes with a low
    /// RMSD, the implementation is producing an improper rotation and silently mirroring
    /// the molecule, which looks almost right and is completely wrong.
    @Test("a mirrored structure is not superposed by a proper rotation")
    func refusesReflection() throws {
        let p = Self.helix(50)
        let mirrored = p.map { SIMD3<Float>($0.x, $0.y, -$0.z) }   // reflect through z
        let fit = try #require(Kabsch.superpose(mobile: p, onto: mirrored))
        #expect(fit.rmsd > 1.0, "a reflection should not fit, got RMSD \(fit.rmsd)")
        #expect(simd_determinant(fit.rotation) > 0.99,
                "rotation must be proper, determinant is \(simd_determinant(fit.rotation))")
    }

    @Test("the rotation is always proper for random inputs")
    func alwaysProper() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let n = 20
            let a = (0..<n).map { _ in
                SIMD3<Float>(Float.random(in: -30...30, using: &generator),
                             Float.random(in: -30...30, using: &generator),
                             Float.random(in: -30...30, using: &generator))
            }
            let b = (0..<n).map { _ in
                SIMD3<Float>(Float.random(in: -30...30, using: &generator),
                             Float.random(in: -30...30, using: &generator),
                             Float.random(in: -30...30, using: &generator))
            }
            let fit = try #require(Kabsch.superpose(mobile: a, onto: b))
            let determinant = simd_determinant(fit.rotation)
            #expect(abs(determinant - 1) < 1e-3, "determinant \(determinant)")
            #expect(fit.rmsd.isFinite)
        }
    }

    @Test("RMSD matches a directly computed value after superposition")
    func rmsdMatchesDirect() throws {
        let p = Self.helix(60)
        // Displace every third point by a known amount, so the RMSD is predictable.
        var q = p
        for k in stride(from: 0, to: q.count, by: 3) { q[k].x += 1.0 }
        let fit = try #require(Kabsch.superpose(mobile: p, onto: q))

        let moved = fit.apply(p)
        var total: Float = 0
        for (a, b) in zip(moved, q) { total += simd_length_squared(a - b) }
        let direct = (total / Float(p.count)).squareRoot()
        #expect(abs(fit.rmsd - direct) < 1e-3,
                "closed-form RMSD \(fit.rmsd) vs direct \(direct)")
    }

    @Test("bad input returns nil instead of trapping", arguments: [0, 1, 2])
    func rejectsTooFewPoints(count: Int) {
        let p = Self.helix(count)
        #expect(Kabsch.superpose(mobile: p, onto: p) == nil)
    }

    @Test("mismatched counts return nil")
    func rejectsMismatch() {
        #expect(Kabsch.superpose(mobile: Self.helix(10), onto: Self.helix(11)) == nil)
    }

    /// Superposing consecutive frames of a real trajectory is what stops the molecule
    /// tumbling. On a real fold the frame-to-frame RMSD should be small and finite.
    @Test("consecutive frames of a real trajectory superpose sensibly")
    func realTrajectory() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/ubiquitin.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        #expect(bundle.readouts.count > 1)

        var previous = bundle.readouts[0].caPositions
        var worst: Float = 0
        var superposedCount = 0
        for readout in bundle.readouts.dropFirst() {
            let fit = try #require(Kabsch.superpose(mobile: readout.caPositions,
                                                    onto: previous))
            #expect(fit.rmsd.isFinite)
            #expect(simd_determinant(fit.rotation) > 0.99)
            worst = max(worst, fit.rmsd)
            superposedCount += 1
            previous = fit.apply(readout.caPositions)
        }
        #expect(superposedCount == bundle.readouts.count - 1)
        // ESMFold's readouts barely move, which is the finding recorded in BLOCKERS.md.
        // The point here is that every frame superposes with a proper rotation and a finite
        // RMSD, not that the number is large.
        #expect(worst < 25, "frame-to-frame RMSD should be bounded, worst was \(worst)")
    }
}
