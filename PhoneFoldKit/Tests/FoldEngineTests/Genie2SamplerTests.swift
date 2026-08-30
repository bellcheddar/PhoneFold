import Testing
import Foundation
import simd
import CoreML
@testable import FoldEngine

/// The Genie 2 sampler against the real exported model.
///
/// Compiles `Models/Genie2Step_L64.mlpackage` from the repository and runs it, so this covers
/// the parts a schedule test cannot: that the multi-array plumbing writes where Core ML expects
/// to read, and that the reverse process produces a chain rather than noise.
/// The two full sampler runs are **release only**. They spend their time inside Core ML
/// running a compiled model, which behaves identically whichever way the surrounding Swift was
/// optimised, so running them in both builds doubles a nine-minute gate to learn nothing. The
/// multi-array round trip, which is the part that is actually Swift, runs in both.
@Suite("Genie 2 sampler")
struct Genie2SamplerTests {

    /// Whether the slow end-to-end runs should execute in this build.
    static var runsFullSampler: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    static var modelURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Models/Genie2Step_L64.mlpackage")
    }

    static func sampler() async throws -> Genie2Sampler? {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        let compiled = try await MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        // CPU and GPU only: the ANE would not compile this graph, measured in Phase 0.
        configuration.computeUnits = .cpuAndGPU
        return Genie2Sampler(model: try MLModel(contentsOf: compiled,
                                               configuration: configuration))
    }

    /// Round-tripping through a multi-array must return what went in.
    ///
    /// This is the check that catches the stride mistake: Core ML pads rows, so indexing by
    /// `index * width` reads the first element correctly and drifts after it - which produces
    /// a plausible-looking structure built from the wrong numbers rather than an error.
    @Test("Multi-array writes and reads agree, whatever the strides")
    func multiArrayRoundTrips() throws {
        let n = Genie2Sampler.residues
        let array = try MLMultiArray(shape: [1, NSNumber(value: n), 3], dataType: .float32)
        let original = (0..<n).map { SIMD3<Double>(Double($0), Double($0) * 2, Double($0) * 3) }
        Genie2Sampler.fill(array, residues: n, columns: 3) { residue, column in
            Float(original[residue][column])
        }
        let read = Genie2Sampler.read(array, residues: n)
        #expect(read.count == n)
        for (a, b) in zip(read, original) {
            #expect(simd_distance(a, b) < 1e-6, "round trip changed \(b) into \(a)")
        }
    }

    @Test("The model runs and its reverse process produces a chain",
          .timeLimit(.minutes(30)))
    func samplerProducesAChain() async throws {
        guard Self.runsFullSampler else { return }
        guard let sampler = try await Self.sampler() else {
            // The model is bundled in the repository; if it is missing this is not a silent
            // pass, it is a skip with a reason.
            Issue.record("Models/Genie2Step_L64.mlpackage is absent - sampler not exercised")
            return
        }
        let frames = try sampler.sample(seed: 5, frameCount: 24)
        #expect(frames.count >= 2)
        #expect(frames.allSatisfy { $0.count == Genie2Sampler.residues })
        for frame in frames {
            for p in frame { #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite) }
        }
        // It must end as a compact chain, not as the noise it started from.
        func rg(_ f: [SIMD3<Double>]) -> Double {
            let c = f.reduce(SIMD3<Double>.zero, +) / Double(f.count)
            return (f.map { simd_length_squared($0 - c) }.reduce(0, +) / Double(f.count))
                .squareRoot()
        }
        func meanBond(_ f: [SIMD3<Double>]) -> Double {
            var total = 0.0
            for i in 0..<(f.count - 1) { total += simd_length(f[i + 1] - f[i]) }
            return total / Double(f.count - 1)
        }
        let final = frames.last!
        print(String(format: "genie2: start Rg %.2f -> final Rg %.2f, mean CA-CA %.2f A",
                     rg(frames.first!), rg(final), meanBond(final)))
        // A real backbone has consecutive alpha carbons about 3.8 A apart. This is the check
        // that the denoising actually worked: noise has no such spacing.
        #expect(meanBond(final) > 3.0 && meanBond(final) < 4.6,
                "mean CA-CA spacing is \(meanBond(final)) A, not a backbone")
    }
}

extension Genie2SamplerTests {

    /// Seed 1 diverges on its own and must still produce a backbone through the retry.
    ///
    /// The seed is not arbitrary: seeds 1 and 2 were measured to reach NaN part way through
    /// the reverse process while 3 and 4 complete cleanly. This pins that the workaround
    /// actually rescues the case it exists for, rather than only appearing to.
    @Test("A seed that diverges still yields a backbone", .timeLimit(.minutes(30)))
    func divergentSeedRecovers() async throws {
        guard Self.runsFullSampler else { return }
        guard let sampler = try await Self.sampler() else {
            Issue.record("Models/Genie2Step_L64.mlpackage is absent - retry not exercised")
            return
        }
        let frames = try sampler.sample(seed: 1, frameCount: 24)
        let final = frames.last!
        var bond = 0.0
        for i in 0..<(final.count - 1) { bond += simd_length(final[i + 1] - final[i]) }
        let mean = bond / Double(final.count - 1)
        print(String(format: "seed 1 after retry: mean CA-CA %.2f A", mean))
        #expect(mean > 3.0 && mean < 4.6, "mean CA-CA spacing is \(mean) A, not a backbone")
        #expect(final.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    /// A single attempt on a known-bad seed must still fail, or the retry test proves nothing.
    @Test("Without the retry, a divergent seed is reported honestly",
          .timeLimit(.minutes(30)))
    func divergentSeedFailsAlone() async throws {
        guard Self.runsFullSampler, let sampler = try await Self.sampler() else { return }
        #expect(throws: Genie2Sampler.Failure.self) {
            _ = try sampler.sample(seed: 1, frameCount: 24, attempts: 1)
        }
    }
}
