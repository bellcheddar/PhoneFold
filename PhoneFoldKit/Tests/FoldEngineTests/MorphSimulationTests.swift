import Testing
import Foundation
import simd
@testable import FoldEngine

@Suite("Morph")
struct MorphSimulationTests {

    static func native() throws -> [SIMD3<Double>] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/go_native.xyz")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: " ").compactMap { Double($0) }
            return p.count == 3 ? SIMD3<Double>(p[0], p[1], p[2]) : nil
        }
    }

    /// What torsion space actually buys, measured rather than assumed.
    ///
    /// **Not fewer clashes.** Measured on ubiquitin: the closest non-bonded approach is 0.28 A
    /// in torsion space against 0.34 A in Cartesian - torsion is no better, and slightly worse.
    /// Interpolating torsions preserves the chain's bonded geometry and says nothing whatever
    /// about whether two distant parts of the chain pass through each other. The first version
    /// of this file claimed torsion space fixed the clashing and that claim was wrong.
    ///
    /// **What it buys is bond geometry.** A Cartesian morph pulls the chain through itself and
    /// its bonds collapse on the way; a torsion morph keeps every bond at a real CA-CA
    /// distance throughout. That is the difference between a chain moving and a chain melting.
    @Test("A torsion morph keeps its bonds; a Cartesian one does not")
    func torsionKeepsBondGeometry() throws {
        let native = try Self.native()
        let start = UnfoldedChain.build(residues: native.count, seed: 3)
        var parameters = MorphSimulation.Parameters()
        parameters.frameCount = 200

        let torsion = MorphSimulation(native: native, parameters: parameters).run(from: start)
        let cartesian: [[SIMD3<Double>]] = (0..<200).map { f in
            let t = Double(f) / 199
            return zip(start, native).map { $0 + ($1 - $0) * t }
        }
        func worstBond(_ frames: [[SIMD3<Double>]]) -> (shortest: Double, longest: Double) {
            var shortest = Double.greatestFiniteMagnitude, longest = 0.0
            for frame in frames {
                for i in 0..<(frame.count - 1) {
                    let d = simd_length(frame[i + 1] - frame[i])
                    shortest = Swift.min(shortest, d); longest = Swift.max(longest, d)
                }
            }
            return (shortest, longest)
        }
        let t = worstBond(torsion), c = worstBond(cartesian)
        print(String(format: "bonds: torsion %.2f-%.2f A, cartesian %.2f-%.2f A",
                     t.shortest, t.longest, c.shortest, c.longest))
        print(String(format: "closest non-bonded approach: torsion %.2f A, cartesian %.2f A",
                     MorphSimulation.closestNonBondedApproach(torsion),
                     MorphSimulation.closestNonBondedApproach(cartesian)))
        // A CA-CA bond is 3.8 A. Torsion must hold that throughout.
        #expect(t.shortest > 3.4 && t.longest < 4.2,
                "torsion morph bonds ran \(t.shortest) to \(t.longest) A")
        // And Cartesian must visibly not, or this comparison is not saying anything.
        #expect(c.shortest < t.shortest,
                "cartesian bonds \(c.shortest) were no worse than torsion's \(t.shortest)")
    }

    @Test("The morph starts unfolded and ends on the native structure")
    func morphReachesTheNative() throws {
        let native = try Self.native()
        let start = UnfoldedChain.build(residues: native.count, seed: 3)
        let frames = MorphSimulation(native: native).run(from: start)
        #expect(frames.count == 180)
        // The last frame must BE the native structure, not merely near it: this engine is
        // defined by its destination.
        var worst = 0.0
        for (a, b) in zip(frames.last!, native) { worst = Swift.max(worst, simd_length(a - b)) }
        #expect(worst < 0.05, "the morph ended \(worst) A from the native structure")
        // And it must genuinely start somewhere else.
        var start_worst = 0.0
        for (a, b) in zip(frames.first!, native) {
            start_worst = Swift.max(start_worst, simd_length(a - b))
        }
        #expect(start_worst > 10, "the morph began \(start_worst) A from native - not unfolded")
    }

    @Test("A dihedral takes the short way round the circle")
    func anglesInterpolateTheShortWay() {
        // -179 to +179 degrees is two degrees apart, not 358.
        let a = -179.0 * .pi / 180, b = 179.0 * .pi / 180
        let mid = MorphSimulation.interpolateAngle(a, b, 0.5)
        // Halfway should be at +/-180, not at 0.
        #expect(abs(abs(mid) - .pi) < 1e-9, "midpoint went the long way: \(mid)")
    }
}

extension MorphSimulationTests {

    /// Reading a chain's internal coordinates and building it back must return the chain.
    ///
    /// The test that was missing. `UnfoldedChain.place` produced the *negative* of the dihedral
    /// that `StructureBasedModel.dihedral` measures, and nothing noticed for as long as the
    /// only caller was the random coil - where the dihedral is drawn uniformly around the
    /// circle, so a sign flip produces an equally valid coil. The morph reads real dihedrals
    /// and replays them, and came out 34.7 A from its own destination.
    @Test("Internal coordinates round-trip back to the same chain")
    func internalCoordinatesRoundTrip() throws {
        for chain in [try Self.native(), UnfoldedChain.build(residues: 60, seed: 9)] {
            let ic = MorphSimulation.internalCoordinates(chain)
            let rebuilt = MorphSimulation.build(bonds: ic.bonds, angles: ic.angles,
                                                dihedrals: ic.dihedrals, origin: chain)
            #expect(rebuilt.count == chain.count)
            var worst = 0.0
            for (a, b) in zip(rebuilt, chain) { worst = Swift.max(worst, simd_length(a - b)) }
            #expect(worst < 1e-6,
                    "rebuilding from internal coordinates moved an atom by \(worst) A")
        }
    }
}
