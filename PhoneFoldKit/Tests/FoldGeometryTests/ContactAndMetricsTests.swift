import Testing
import Foundation
import simd
import FoldCore
@testable import FoldGeometry

@Suite("Contact tracking")
struct ContactTrackerTests {

    /// Exactly one pair that can possibly be in contact.
    ///
    /// Residues are spaced 30 A apart so nothing is within the 8 A cutoff by accident, then
    /// the last one is placed at a controlled distance from the first. An earlier version of
    /// this fixture used realistic 3.8 A spacing and accidentally put the moved residue
    /// within range of four of its neighbours, which made the test measure the fixture
    /// rather than the tracker.
    static func pair(distance: Float, count: Int = 20) -> [SIMD3<Float>] {
        var ca = (0..<count).map { SIMD3<Float>(Float($0) * 30, 0, 0) }
        // Offset perpendicular to the chain: moving it along x lands it on top of another
        // residue at large separations and forms a different contact instead.
        ca[count - 1] = ca[0] + SIMD3<Float>(0, distance, 0)
        return ca
    }

    static let residues = [AminoAcid](repeating: .alanine, count: 20)

    @Test("a contact fires exactly once when it forms, not once per frame")
    func firesOnce() {
        var tracker = ContactTracker()
        // Far apart: nothing.
        #expect(tracker.update(caPositions: Self.pair(distance: 20), residues: Self.residues)
                    .isEmpty)
        // Cross inwards: one event.
        let formed = tracker.update(caPositions: Self.pair(distance: 7),
                                    residues: Self.residues)
        #expect(formed.count == 1)
        #expect(formed[0].i == 0 && formed[0].j == 19)
        // Held: no further events, however many frames pass.
        for _ in 0..<50 {
            #expect(tracker.update(caPositions: Self.pair(distance: 7),
                                   residues: Self.residues).isEmpty)
        }
        #expect(tracker.activeContactCount == 1)
    }

    /// Without hysteresis a pair sitting on the threshold chatters and machine-guns the
    /// sequencer. This is the test that pins the gap between forming and breaking.
    @Test("a pair sitting on the threshold does not chatter")
    func hysteresis() {
        var tracker = ContactTracker(formationCutoff: 8.0, breakCutoff: 8.5)
        _ = tracker.update(caPositions: Self.pair(distance: 7.9), residues: Self.residues)
        var events = 0
        for k in 0..<40 {
            // Oscillate across the formation cutoff but never past the break cutoff.
            let d: Float = k % 2 == 0 ? 8.2 : 7.9
            events += tracker.update(caPositions: Self.pair(distance: d),
                                     residues: Self.residues).count
        }
        #expect(events == 0, "hysteresis should suppress threshold chatter, got \(events)")
    }

    @Test("breaking and re-forming does emit again")
    func reformation() {
        var tracker = ContactTracker()
        #expect(tracker.update(caPositions: Self.pair(distance: 7),
                               residues: Self.residues).count == 1)
        // Well past the break cutoff.
        #expect(tracker.update(caPositions: Self.pair(distance: 30),
                               residues: Self.residues).isEmpty)
        #expect(tracker.activeContactCount == 0)
        #expect(tracker.update(caPositions: Self.pair(distance: 7),
                               residues: Self.residues).count == 1)
    }

    @Test("chain neighbours are never contacts")
    func neighboursExcluded() {
        var tracker = ContactTracker(minimumSeparation: 3)
        // A straight chain: consecutive CA are 3.8 A apart, well inside 8 A.
        let ca = (0..<10).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        let formed = tracker.update(caPositions: ca,
                                    residues: [AminoAcid](repeating: .alanine, count: 10))
        #expect(formed.allSatisfy { $0.separation >= 3 })
        // i to i+2 is 7.6 A, inside the cutoff, and must still be excluded.
        #expect(formed.allSatisfy { $0.separation != 2 })
    }

    @Test("hydrophobic pairing is detected from the sequence")
    func hydrophobicPairs() {
        var residues = [AminoAcid](repeating: .lysine, count: 20)   // hydrophilic
        residues[0] = .leucine
        residues[19] = .isoleucine
        var tracker = ContactTracker()
        let formed = tracker.update(caPositions: Self.pair(distance: 7), residues: residues)
        #expect(formed.count == 1)
        #expect(formed[0].isHydrophobicPair)

        var tracker2 = ContactTracker()
        let formed2 = tracker2.update(caPositions: Self.pair(distance: 7),
                                      residues: [AminoAcid](repeating: .lysine, count: 20))
        #expect(formed2[0].isHydrophobicPair == false)
    }

    /// PLAN.md Phase 3 requires the same protein to yield the same piece, so the order of
    /// events on a frame must be deterministic.
    @Test("event order is deterministic across runs")
    func deterministicOrder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/genie2_76aa_seed1.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let residues = bundle.residues

        func run() -> [[ContactEvent]] {
            var tracker = ContactTracker()
            return bundle.readouts.map {
                tracker.update(caPositions: $0.caPositions, residues: residues)
            }
        }
        #expect(run() == run())
    }

    /// End to end on a real generated fold: contacts should accumulate as it collapses.
    @Test("a real folding trajectory accumulates contacts")
    func realTrajectory() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/genie2_76aa_seed1.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        var tracker = ContactTracker()
        var total = 0
        for readout in bundle.readouts {
            total += tracker.update(caPositions: readout.caPositions,
                                    residues: bundle.residues).count
        }
        #expect(total > 20, "a fold should form plenty of contacts, got \(total)")
        #expect(tracker.activeContactCount > 10,
                "the final structure should hold contacts, has \(tracker.activeContactCount)")
        // Long-range contacts are the musically interesting ones; a real fold has some.
        var final = ContactTracker()
        _ = final.update(caPositions: bundle.readouts[0].caPositions, residues: bundle.residues)
        let last = ContactTracker.contactMap(caPositions: bundle.readouts.last!.caPositions)
        #expect(last.contains { abs($0.1 - $0.0) >= 12 }, "expected long-range contacts")
    }
}

@Suite("Frame metrics")
struct FrameMetricsTests {

    @Test("radius of gyration of a known shape")
    func radiusOfGyration() {
        // Eight corners of a cube of side 2 centred on the origin: every point is at
        // sqrt(3) from the centre, so Rg is exactly sqrt(3).
        var ca: [SIMD3<Float>] = []
        for x in [Float(-1), 1] { for y in [Float(-1), 1] { for z in [Float(-1), 1] {
            ca.append(SIMD3<Float>(x, y, z))
        } } }
        #expect(abs(Metrics.radiusOfGyration(ca) - Float(3).squareRoot()) < 1e-5)
        #expect(Metrics.radiusOfGyration([]) == 0)
    }

    /// The compactness expectation is checked against a real protein, so the formula is
    /// anchored rather than asserted.
    @Test("the compactness expectation matches experimental ubiquitin")
    func compactnessAnchor() throws {
        let expected = FrameMetrics.expectedRadiusOfGyration(residueCount: 76)
        #expect(abs(expected - 11.4) < 0.2, "expected ~11.4 A for 76 residues, got \(expected)")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/ubiquitin.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let rg = Metrics.radiusOfGyration(bundle.readouts.last!.caPositions)
        #expect(abs(rg - 11.5) < 1.0, "ESMFold ubiquitin Rg should be near 11.5, got \(rg)")
    }

    @Test("contact order is zero without contacts and positive with them")
    func contactOrder() {
        #expect(Metrics.relativeContactOrder([], residueCount: 50) == 0)
        // One contact spanning 25 residues in a 50-residue chain: 25 / (1 * 50) = 0.5.
        #expect(abs(Metrics.relativeContactOrder([(0, 25)], residueCount: 50) - 0.5) < 1e-6)
    }

    @Test("an extended chain is not compact and a folded one is")
    func compactnessDiscriminates() throws {
        let extended = (0..<76).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        let residues = [AminoAcid](repeating: .alanine, count: 76)
        let confidence = [Float](repeating: 50, count: 76)
        let extendedMetrics = Metrics.compute(caPositions: extended, residues: residues,
                                              confidence: confidence)
        #expect(extendedMetrics.compactness > 3,
                "an extended chain should be far from compact, got \(extendedMetrics.compactness)")
        #expect(extendedMetrics.contactCount == 0)

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/genie2_76aa_seed1.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let folded = Metrics.compute(caPositions: bundle.readouts.last!.caPositions,
                                     residues: bundle.residues,
                                     confidence: bundle.readouts.last!.confidence)
        #expect(folded.compactness < 1.2,
                "the final Genie 2 frame should be compact, got \(folded.compactness)")
        #expect(folded.contactCount > 30)
    }

    @Test("confidence statistics ignore non-finite values rather than propagating them")
    func confidenceStats() {
        let ca = (0..<10).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        let residues = [AminoAcid](repeating: .alanine, count: 10)
        var confidence = [Float](repeating: 80, count: 10)
        confidence[3] = .nan
        confidence[7] = 20
        let m = Metrics.compute(caPositions: ca, residues: residues, confidence: confidence)
        #expect(m.meanConfidence.isFinite)
        #expect(m.minimumConfidence == 20)
    }

    @Test("burial rises as a structure compacts")
    func burial() throws {
        let residues = [AminoAcid](repeating: .leucine, count: 60)
        let extended = (0..<60).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        let extendedBurial = Metrics.buriedHydrophobicFraction(extended, residues: residues)
        // A tight ball: 60 points on a small sphere.
        let packed = (0..<60).map { k -> SIMD3<Float> in
            let phi = Float(k) * 2.399963
            let z = 1 - 2 * Float(k) / 59
            let r = (max(0, 1 - z * z)).squareRoot()
            return SIMD3<Float>(r * cos(phi), r * sin(phi), z) * 9
        }
        let packedBurial = Metrics.buriedHydrophobicFraction(packed, residues: residues)
        #expect(extendedBurial < packedBurial,
                "packed \(packedBurial) should exceed extended \(extendedBurial)")
    }
}
