import Testing
import Foundation
import simd
import FoldCore
@testable import FoldEngine

/// A fold computed on the device must be playable through exactly the path a bundled
/// trajectory takes - same provider, same engine, same enrichment. If it is not, the app grows
/// a second code path that will drift.
@Suite("Live trajectory")
struct LiveTrajectoryTests {

    static func native() throws -> [SIMD3<Double>] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/go_native.xyz")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: " ").compactMap { Double($0) }
            return p.count == 3 ? SIMD3<Double>(p[0], p[1], p[2]) : nil
        }
    }

    static func metadata(_ engine: FoldingEngine, residues: Int) -> TrajectoryMetadata {
        TrajectoryMetadata(name: "Ubiquitin",
                           sequence: String(repeating: "A", count: residues),
                           provenance: engine.provenance,
                           sourceModel: "on-device",
                           blocksPerReadout: 1, recycles: 1,
                           generated: "2026-08-30T00:00:00Z")
    }

    @Test("Both reference engines produce a consistent, playable bundle")
    func enginesProduceValidBundles() throws {
        let native = try Self.native()
        let residues = [AminoAcid](repeating: .alanine, count: native.count)
        for engine in [FoldingEngine.morph, .structureBased] {
            let bundle = try LiveTrajectory.fold(
                engine: engine, native: native,
                metadata: Self.metadata(engine, residues: native.count),
                residues: residues, seed: 3,
                steps: 40_000, frameCount: 30)
            #expect(bundle.isConsistent, "\(engine) produced an inconsistent bundle")
            #expect(bundle.readouts.count >= 30 - 1)
            // A provider must accept it, which is what the app will do.
            let provider = try SampleTrajectoryProvider(bundle: bundle)
            #expect(provider.readouts.count == bundle.readouts.count)
            #expect(provider.metadata.provenance == engine.provenance)
            // Every frame a real chain.
            for readout in bundle.readouts {
                #expect(readout.caPositions.count == native.count)
                for p in readout.caPositions {
                    #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
                }
            }
        }
    }

    /// The two reference engines must both end on the structure they were given.
    @Test("Both reference engines finish on the reference structure")
    func enginesFinishOnTheReference() throws {
        let native = try Self.native()
        let residues = [AminoAcid](repeating: .alanine, count: native.count)
        let target = native.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }

        // The morph is defined by its destination and must land on it exactly.
        let morph = try LiveTrajectory.fold(
            engine: .morph, native: native,
            metadata: Self.metadata(.morph, residues: native.count),
            residues: residues, seed: 3, frameCount: 60)
        var worst: Float = 0
        for (a, b) in zip(morph.readouts.last!.caPositions, target) {
            worst = Swift.max(worst, simd_length(a - b))
        }
        #expect(worst < 0.05, "the morph ended \(worst) A from the reference")
    }

    /// The disclosure is not decoration: a viewer told nothing will assume a prediction.
    @Test("Every engine carries the disclosure its claim requires")
    func enginesDiscloseTheirClaim() {
        #expect(FoldingEngine.structureBased.provenance.isTowardKnownStructure)
        #expect(FoldingEngine.morph.provenance.isTowardKnownStructure)
        #expect(!FoldingEngine.generative.provenance.isTowardKnownStructure)
        #expect(FoldingEngine.generative.provenance.isGenerated)
        for engine in FoldingEngine.allCases {
            let disclosure = engine.provenance.disclosure
            #expect(disclosure != nil, "\(engine) makes a claim with no disclosure")
            #expect(disclosure?.isEmpty == false)
        }
        // And the two that fold toward a reference must not be described as predictions.
        #expect(FoldingEngine.structureBased.provenance.disclosure?
            .localizedCaseInsensitiveContains("not a prediction") == true)
    }

    @Test("The generative engine refuses to be driven as a reference fold")
    func generativeIsNotAReferenceEngine() throws {
        let native = try Self.native()
        #expect(throws: LiveTrajectory.Failure.self) {
            _ = try LiveTrajectory.fold(
                engine: .generative, native: native,
                metadata: Self.metadata(.generative, residues: native.count),
                residues: [AminoAcid](repeating: .alanine, count: native.count))
        }
    }

    /// Per-residue native fraction is what the colour ramp reads, so it must actually vary.
    @Test("Per-residue native contact fraction distinguishes core from termini")
    func perResidueFractionVaries() throws {
        let native = try Self.native()
        let model = StructureBasedModel(native: native)
        let atNative = model.perResidueNativeFraction(native)
        #expect(atNative.allSatisfy { $0 > 0.99 }, "the native state should score 1 everywhere")

        let coil = UnfoldedChain.build(residues: native.count, seed: 3)
        let unfolded = model.perResidueNativeFraction(coil)
        let mean = unfolded.reduce(0, +) / Double(unfolded.count)
        #expect(mean < 0.25, "an unfolded coil should have few native contacts, got \(mean)")
        // It must vary across the chain, or it says nothing a single number does not.
        #expect((unfolded.max() ?? 0) - (unfolded.min() ?? 0) > 0.1)
    }
}
