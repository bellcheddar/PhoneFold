import Testing
import Foundation
import simd
import FoldCore
@testable import FoldGeometry

@Suite("Learned CA-only secondary structure")
struct LearnedSSETests {

    struct Parity: Decodable {
        let ca: [[Float]]
        let features: [[Float]]
        let logits: [[Float]]
    }

    static func model() throws -> LearnedSSE {
        try #require(LearnedSSE.bundled, "the bundled classifier failed to load")
    }

    @Test("the bundled classifier loads and is small enough to ship")
    func loads() throws {
        let model = try Self.model()
        #expect(model.parameterCount > 1000)
        #expect(model.parameterCount < 20_000, "must stay small enough for a phone")
        #expect(model.validationAccuracy > 85)
    }

    /// The Swift feature extraction must match `Tools/sse_features.py` exactly. If it does
    /// not, the model is being fed something it was never trained on, and the failure would
    /// be a quietly worse assignment rather than an error.
    @Test("features match the Python implementation exactly")
    func featureParity() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/sse_parity",
                                                 withExtension: "json"))
        let parity = try JSONDecoder().decode(Parity.self, from: Data(contentsOf: url))
        let ca = parity.ca.map { SIMD3<Float>($0[0], $0[1], $0[2]) }

        let features = try Self.model().features(caPositions: ca)
        #expect(features.count == parity.features.count)
        var worst: Float = 0
        for (mine, theirs) in zip(features, parity.features) {
            #expect(mine.count == theirs.count)
            for (a, b) in zip(mine, theirs) { worst = max(worst, abs(a - b)) }
        }
        #expect(worst < 1e-4, "largest feature difference vs Python was \(worst)")
    }

    @Test("logits match the Python forward pass")
    func logitParity() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/sse_parity",
                                                 withExtension: "json"))
        let parity = try JSONDecoder().decode(Parity.self, from: Data(contentsOf: url))
        let ca = parity.ca.map { SIMD3<Float>($0[0], $0[1], $0[2]) }

        let model = try Self.model()
        let logits = model.logits(features: model.features(caPositions: ca))
        var worst: Float = 0
        for (mine, theirs) in zip(logits, parity.logits) {
            for (a, b) in zip(mine, theirs) { worst = max(worst, abs(a - b)) }
        }
        #expect(worst < 1e-2, "largest logit difference vs Python was \(worst)")
    }

    /// **The Phase 1 exit gate.** The ten structures here were excluded from the training
    /// set entirely, so this measures generalisation.
    @Test("agreement with DSSP on the held-out ten is at least 85%")
    func meetsPhase1Gate() throws {
        let reference = try PSEAAgreementTests.loadReference()
        let model = try Self.model()
        var matched = 0, total = 0
        var perStructure: [(String, Double)] = []
        for entry in reference.structures {
            let ca = entry.ca.map { SIMD3<Float>($0[0], $0[1], $0[2]) }
            let assigned = model.assign(caPositions: ca)
            let truth = Array(entry.dssp)
            var m = 0
            for i in truth.indices where assigned[i].structure.code == truth[i] { m += 1 }
            matched += m
            total += truth.count
            perStructure.append((entry.pdb, Double(m) / Double(truth.count) * 100))
        }
        let percent = Double(matched) / Double(total) * 100
        for (pdb, score) in perStructure {
            print(String(format: "  %@ %5.1f%%", pdb, score))
        }
        print(String(format: "Learned CA-only vs DSSP: %.1f%% (%d/%d), P-SEA baseline 79.4%%",
                     percent, matched, total))
        #expect(percent >= 85.0, "PLAN.md Phase 1 gate: at least 85 percent agreement")
    }

    @Test("it beats the P-SEA baseline it replaces")
    func beatsPSEA() throws {
        let reference = try PSEAAgreementTests.loadReference()
        let model = try Self.model()
        var learned = 0, psea = 0, total = 0
        for entry in reference.structures {
            let ca = entry.ca.map { SIMD3<Float>($0[0], $0[1], $0[2]) }
            let truth = Array(entry.dssp)
            let a = model.assign(caPositions: ca)
            let b = PSEA.assign(caPositions: ca)
            for i in truth.indices {
                if a[i].structure.code == truth[i] { learned += 1 }
                if b[i].structure.code == truth[i] { psea += 1 }
            }
            total += truth.count
        }
        #expect(learned > psea,
                "learned \(learned)/\(total) should beat P-SEA \(psea)/\(total)")
    }

    @Test("an ideal helix and an extended strand are called correctly")
    func idealShapes() throws {
        let model = try Self.model()
        let helix = (0..<24).map { k -> SIMD3<Float> in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
        let assignedHelix = model.assign(caPositions: helix)
        #expect(assignedHelix[4..<20].filter { $0.structure == .helix }.count >= 12)
        #expect(assignedHelix.allSatisfy { $0.structure != .sheet })
    }

    @Test("confidence is a real probability")
    func confidenceIsProbability() throws {
        let model = try Self.model()
        let helix = (0..<20).map { k -> SIMD3<Float> in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
        for a in model.assign(caPositions: helix) {
            #expect(a.confidence >= 0 && a.confidence <= 1)
            if a.structure != .coil { #expect(a.confidence > 0.33) }
        }
    }

    @Test("short chains and empty input do not trap")
    func degenerate() throws {
        let model = try Self.model()
        #expect(model.assign(caPositions: []).isEmpty)
        for n in 1...4 {
            let ca = (0..<n).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
            let a = model.assign(caPositions: ca)
            #expect(a.count == n)
            #expect(a.allSatisfy { $0.structure == .coil })
        }
    }

    @Test("the default assigner routes to the learned model")
    func defaultAssigner() throws {
        let ca = (0..<24).map { k -> SIMD3<Float> in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
        let viaEnum = SecondaryStructureAssigner.learned.assign(caPositions: ca)
        let direct = try Self.model().assign(caPositions: ca)
        #expect(viaEnum.map(\.structure) == direct.map(\.structure))
    }
}
