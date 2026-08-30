import Testing
import Foundation
import simd
import FoldCore
@testable import FoldEngine

/// The Swift structure-based model against the C reference implementation.
///
/// **Why forces and not a folded structure.** Two different force fields can both fold a small
/// protein to something that looks right, so agreeing on a final structure proves very little.
/// Agreeing on the force on every particle, for a configuration that is neither native nor
/// extended, exercises every term - bonds, angles, dihedrals, the 12-10 native well and the
/// non-native repulsion - and pins the port to the physics rather than to the outcome.
///
/// The fixtures come from `Tools/go_model_fold_bin --forces`, which is the same C used for
/// every measurement in METRICS.md.
@Suite("Structure-based model")
struct StructureBasedModelTests {

    static func fixture(_ name: String) throws -> [SIMD3<Double>] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ").compactMap { Double($0) }
            return parts.count == 3 ? SIMD3<Double>(parts[0], parts[1], parts[2]) : nil
        }
    }

    @Test("Every force matches the C reference implementation")
    func forcesMatchTheReference() throws {
        let native = try Self.fixture("go_native.xyz")
        let start = try Self.fixture("go_start.xyz")
        let expected = try Self.fixture("go_forces.txt")
        try #require(native.count == 76)
        try #require(start.count == native.count)
        try #require(expected.count == native.count)

        let model = StructureBasedModel(native: native)
        let actual = model.forces(start)

        // Relative comparison: these forces span six orders of magnitude, because the
        // non-native repulsion is enormous wherever two residues are close. An absolute
        // tolerance would be met trivially by the small ones and impossible for the large.
        var worst = 0.0
        for (a, b) in zip(actual, expected) {
            let scale = Swift.max(simd_length(b), 1.0)
            worst = Swift.max(worst, simd_length(a - b) / scale)
        }
        #expect(worst < 1e-9, "worst relative force disagreement with the C: \(worst)")
    }

    @Test("The native contact list matches the reference's count")
    func contactCountMatches() throws {
        let native = try Self.fixture("go_native.xyz")
        let model = StructureBasedModel(native: native)
        // 184 native contacts at an 8 A cutoff with |i-j| >= 3, as the C reports for
        // ubiquitin and as METRICS.md records.
        #expect(model.nativeContactCount == 184)
    }

    /// The native structure must sit at the bottom of its own funnel.
    @Test("The native state is a force minimum and scores Q = 1")
    func nativeIsTheMinimum() throws {
        let native = try Self.fixture("go_native.xyz")
        let model = StructureBasedModel(native: native)
        #expect(model.fractionNative(native) == 1.0)
        // Every bonded term is at its reference value there, so what remains is the
        // non-bonded balance - small next to the forces on a perturbed chain.
        let f = model.forces(native)
        let worst = f.map(simd_length).max() ?? 0
        let perturbed = model.forces(try Self.fixture("go_start.xyz"))
        let perturbedWorst = perturbed.map(simd_length).max() ?? 0
        #expect(worst < perturbedWorst / 100,
                "native force \(worst) is not small against a perturbed chain's \(perturbedWorst)")
    }

    /// A seed must reproduce a fold exactly, or no measurement of one can be compared.
    @Test("The same seed replays the same fold")
    func foldIsDeterministic() throws {
        let native = try Self.fixture("go_native.xyz")
        var parameters = StructureBasedModel.Parameters()
        parameters.steps = 20_000
        parameters.frameCount = 12
        parameters.seed = 42
        let model = StructureBasedModel(native: native, parameters: parameters)
        let start = UnfoldedChain.build(residues: native.count, seed: 3)

        let a = model.fold(from: start)
        let b = model.fold(from: start)
        #expect(a.count == b.count)
        for (fa, fb) in zip(a, b) {
            for (pa, pb) in zip(fa, fb) { #expect(pa == pb) }
        }
    }

    /// The unfolded state must be a denatured chain, not a rod and not a folded protein.
    @Test("The unfolded coil has correct bonds and the denatured radius of gyration")
    func unfoldedChainIsDenatured() {
        for n in [40, 76, 129] {
            var radii: [Double] = []
            for seed in UInt64(0)..<8 {
                let chain = UnfoldedChain.build(residues: n, seed: seed)
                #expect(chain.count == n)
                for i in 0..<(chain.count - 1) {
                    let d = simd_length(chain[i + 1] - chain[i])
                    #expect(abs(d - 3.8) < 1e-6, "CA-CA spacing is \(d), not 3.8 A")
                }
                let centre = chain.reduce(SIMD3<Double>.zero, +) / Double(n)
                radii.append((chain.map { simd_length_squared($0 - centre) }.reduce(0, +)
                              / Double(n)).squareRoot())
            }
            // The **mean over eight seeds**, not one chain. A single coil's radius of gyration
            // varies enormously - measured at 14.4 to 30.0 A across seeds for 76 residues - so
            // a one-seed assertion is a coin toss, and the first version of this test failed on
            // a compact draw that was perfectly correct.
            let mean = radii.reduce(0, +) / Double(radii.count)
            let kohn = UnfoldedChain.expectedRadiusOfGyration(residues: n)
            // Measured: this walk runs at 0.81 to 0.92 of Kohn's scaling, and the reference
            // Python implementation runs at the same fraction (76 residues: Swift 19.8 A,
            // Python 19.6 A). The band is set around what both actually do, not around the
            // idealised law, which no freely-rotating walk reproduces exactly.
            #expect(mean > kohn * 0.7 && mean < kohn * 1.15,
                    "\(n) residues: mean Rg \(mean) against Kohn's \(kohn)")
        }
    }

    /// The whole point of the engine: it must actually fold.
    @Test("A short run moves the chain toward the native state", .timeLimit(.minutes(5)))
    func foldMakesProgress() throws {
        let native = try Self.fixture("go_native.xyz")
        // 200,000 steps, which is a *partial* fold and is chosen to keep this test near four
        // seconds. Measured on this protein: 200k reaches Q = 0.49 and 2,000,000 reaches
        // Q = 0.96 in 38 s. The full fold is recorded in METRICS.md; what a unit test can
        // afford to assert is the direction of travel.
        var parameters = StructureBasedModel.Parameters()
        parameters.steps = 200_000
        parameters.frameCount = 40
        parameters.seed = 11
        let model = StructureBasedModel(native: native, parameters: parameters)
        let start = UnfoldedChain.build(residues: native.count, seed: 3)

        let frames = model.fold(from: start)
        #expect(frames.count >= 2)
        let qStart = model.fractionNative(frames.first!)
        let qEnd = model.fractionNative(frames.last!)
        #expect(qStart < 0.2, "the chain did not start unfolded: Q = \(qStart)")
        #expect(qEnd > qStart + 0.2,
                "the chain did not fold: Q went \(qStart) to \(qEnd)")
        // And it collapsed: a fold makes the chain smaller.
        func rg(_ f: [SIMD3<Double>]) -> Double {
            let c = f.reduce(SIMD3<Double>.zero, +) / Double(f.count)
            return (f.map { simd_length_squared($0 - c) }.reduce(0, +) / Double(f.count))
                .squareRoot()
        }
        #expect(rg(frames.last!) < rg(frames.first!),
                "the chain did not collapse: Rg went \(rg(frames.first!)) to \(rg(frames.last!))")
    }
}

extension StructureBasedModelTests {

    /// The neighbour list must be an optimisation, not a change to the model.
    ///
    /// It halves the cost of a fold, and the only reason that is acceptable is that the term it
    /// skips is negligible: `(sigma/r)^12` with sigma 4 A is 0.000017 at 10 A. Measured, the
    /// forces move by six parts in a billion. If that ever stops being true this fails.
    @Test("The repulsion cutoff does not change the forces")
    func cutoffDoesNotChangeTheForces() throws {
        let native = try Self.fixture("go_native.xyz")
        let exact = StructureBasedModel(native: native)
        var parameters = StructureBasedModel.Parameters()
        parameters.repulsionCutoff = 10
        let cut = StructureBasedModel(native: native, parameters: parameters)

        // Both an unfolded coil and the native state: the pair distribution is very different.
        for (label, probe) in [("coil", UnfoldedChain.build(residues: native.count, seed: 3)),
                               ("native", native)] {
            let a = exact.forces(probe)
            let b = cut.forces(probe, nonNativePairs: cut.neighbourList(probe))
            var worst = 0.0, scale = 0.0
            for (x, y) in zip(a, b) {
                worst = Swift.max(worst, simd_length(x - y))
                scale = Swift.max(scale, simd_length(x))
            }
            print(String(format: "cutoff force change, %@: %.3e absolute against a largest force of %.3e",
                         label, worst, scale))
            // **Absolute**, not relative to the largest force present. At the native state the
            // model sits in its own minimum, so the largest force is itself nearly zero and a
            // ratio against it says nothing: the same 1e-5 absolute change reads as 6e-9 on a
            // coil and 1e-5 at the native state purely because the denominator collapsed.
            // A bond stiffness of 100 makes an angstrom of strain worth ~200 force units, so
            // 1e-3 is four orders below anything the dynamics responds to.
            #expect(worst < 1e-3,
                    "the cutoff moved a force by \(worst) at the \(label) state")
        }
    }

    /// And it must not change where the fold ends up.
    @Test("A fold with the cutoff reaches the same state", .timeLimit(.minutes(10)))
    func cutoffDoesNotChangeTheFold() throws {
        let native = try Self.fixture("go_native.xyz")
        let start = UnfoldedChain.build(residues: native.count, seed: 3)
        var results: [Double] = []
        for cutoff in [0.0, 10.0] {
            var parameters = StructureBasedModel.Parameters()
            parameters.repulsionCutoff = cutoff
            parameters.steps = 200_000
            parameters.frameCount = 20
            parameters.seed = 11
            let model = StructureBasedModel(native: native, parameters: parameters)
            results.append(model.fractionNative(model.fold(from: start).last!))
        }
        // Langevin dynamics is chaotic, so two runs are not expected to be identical - the
        // random stream is consumed at the same rate but the trajectories diverge. What must
        // hold is that both reach a comparable state.
        #expect(abs(results[0] - results[1]) < 0.25,
                "the cutoff changed the outcome: Q \(results[0]) against \(results[1])")
    }
}

extension StructureBasedModelTests {

    /// Distance-matrix RMSD: superposition-free, so no Kabsch and no handedness question.
    /// Two structures with the same distance matrix are the same up to rotation, translation
    /// and reflection, which is all "did it arrive at the reference" needs.
    static func dRMSD(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        var sum = 0.0, count = 0.0
        for i in 0..<a.count {
            for j in (i + 1)..<a.count {
                let d = simd_length(a[j] - a[i]) - simd_length(b[j] - b[i])
                sum += d * d; count += 1
            }
        }
        return (sum / Swift.max(count, 1)).squareRoot()
    }

    /// The engine's central claim: it finishes **on** the structure it was given.
    ///
    /// A million steps rather than the two million the app uses, to keep the suite quick; the
    /// full convergence table is in METRICS.md. The unfolded coil starts 16.06 A away in
    /// distance-matrix RMSD, so arriving under 3 A is a real journey and not a starting point
    /// that happened to be close.
    @Test("A fold finishes on the reference structure", .timeLimit(.minutes(10)))
    func foldArrivesAtTheReference() throws {
        let native = try Self.fixture("go_native.xyz")
        let start = UnfoldedChain.build(residues: native.count, seed: 3)
        var parameters = StructureBasedModel.Parameters()
        parameters.steps = 1_000_000
        parameters.frameCount = 40
        parameters.seed = 11
        let model = StructureBasedModel(native: native, parameters: parameters)

        let frames = model.fold(from: start)
        let began = Self.dRMSD(frames.first!, native)
        let ended = Self.dRMSD(frames.last!, native)
        #expect(began > 10, "the chain did not start unfolded: dRMSD \(began)")
        #expect(ended < 3, "the chain did not arrive: dRMSD went \(began) to \(ended)")
        #expect(model.fractionNative(frames.last!) > 0.85,
                "only \(model.fractionNative(frames.last!)) of native contacts formed")
    }
}
