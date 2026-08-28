import Testing
import Foundation
import simd
import FoldCore
@testable import FoldGeometry

/// The Phase 1 exit gate: P-SEA must agree with a DSSP reference on 10 PDB structures at
/// 85% or better per residue, from CA positions alone.
///
/// The reference is `pydssp`, a Kabsch-Sander hydrogen-bond DSSP over N, CA, C and O.
/// Biotite's `annotate_sse` is deliberately not used: it is itself a P-SEA implementation
/// and would compare the method against itself.
@Suite("P-SEA against DSSP")
struct PSEAAgreementTests {

    struct Reference: Decodable {
        struct Entry: Decodable {
            let pdb: String
            let description: String
            let residueCount: Int
            let ca: [[Float]]
            let dssp: String
        }
        let structures: [Entry]
    }

    static func loadReference() throws -> Reference {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/dssp_reference",
                                                 withExtension: "json"),
                               "DSSP fixtures missing; run Tools/make_dssp_fixtures.py")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    static func agreement(_ entry: Reference.Entry) -> (matched: Int, total: Int) {
        let ca = entry.ca.map { SIMD3<Float>($0[0], $0[1], $0[2]) }
        let assigned = PSEA.assign(caPositions: ca)
        let reference = Array(entry.dssp)
        var matched = 0
        for i in reference.indices where assigned[i].structure.code == reference[i] {
            matched += 1
        }
        return (matched, reference.count)
    }

    @Test("the fixture set is present and structurally diverse")
    func fixtureSanity() throws {
        let reference = try Self.loadReference()
        #expect(reference.structures.count == 10)
        let total = reference.structures.reduce(0) { $0 + $1.residueCount }
        #expect(total > 800)
        // A gate that only sees helices would be no gate at all.
        let allDSSP = reference.structures.map(\.dssp).joined()
        let helix = allDSSP.filter { $0 == "H" }.count
        let sheet = allDSSP.filter { $0 == "E" }.count
        #expect(helix > 200, "reference should contain plenty of helix, has \(helix)")
        #expect(sheet > 150, "reference should contain plenty of sheet, has \(sheet)")
        for entry in reference.structures {
            #expect(entry.ca.count == entry.dssp.count,
                    "\(entry.pdb): \(entry.ca.count) CA vs \(entry.dssp.count) DSSP states")
        }
    }

    /// PLAN.md's Phase 1 gate asks for 85%. A correct P-SEA does not reach it: see
    /// BLOCKERS.md. This asserts the level a correct implementation *does* achieve, so a
    /// future change cannot silently degrade it, and the gate itself is escalated rather
    /// than quietly lowered. **The Phase 1 exit gate criterion is NOT marked met.**
    static let measuredAgreement = 79.4
    static let regressionFloor = 78.0

    @Test("agreement does not regress below a correct implementation's level")
    func overallAgreement() throws {
        let reference = try Self.loadReference()
        var matched = 0, total = 0
        for entry in reference.structures {
            let (m, t) = Self.agreement(entry)
            matched += m
            total += t
        }
        let percent = Double(matched) / Double(total) * 100
        print(String(format: "P-SEA vs DSSP overall: %.1f%% (%d/%d residues)",
                     percent, matched, total))
        // Guards against regression, not against PLAN.md's 85%, which is unreachable.
        #expect(percent >= Self.regressionFloor,
                "P-SEA agreement regressed below the level a correct implementation reaches")
        #expect(percent < 95.0, "suspiciously high: check the reference has not been faked")
    }

    @Test("no single structure collapses")
    func perStructure() throws {
        let reference = try Self.loadReference()
        for entry in reference.structures {
            let (m, t) = Self.agreement(entry)
            let percent = Double(m) / Double(t) * 100
            print(String(format: "  %@ %5.1f%%  %@", entry.pdb, percent, entry.description))
            // 1SHG, an all-beta SH3 domain, is the weakest at ~60%: its beta bridges and
            // short strands are exactly what a CA-only method with 5-residue seeding cannot
            // reach. The floor is set below it deliberately rather than excluding it.
            #expect(percent >= 55.0, "per-structure agreement fell below 55 percent")
        }
    }
}

@Suite("P-SEA geometry and hysteresis")
struct PSEAUnitTests {

    /// An ideal alpha helix must read as helix. Rise 1.5 A, 100 degrees of twist, CA radius
    /// 2.3 A: the textbook parameters.
    @Test("an ideal alpha helix is assigned helix")
    func idealHelix() {
        let ca = (0..<24).map { k -> SIMD3<Float> in
            let theta = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(theta), 2.3 * sin(theta), Float(k) * 1.5)
        }
        let assigned = PSEA.assign(caPositions: ca)
        let helices = assigned[2..<22].filter { $0.structure == .helix }.count
        #expect(helices >= 18, "expected a helical run, got \(helices)/20")
        #expect(assigned[10].confidence > 0.3)
    }

    /// An ideal extended beta strand: 3.8 A rise, near-linear, alternating.
    @Test("an extended strand is assigned sheet, not helix")
    func idealStrand() {
        let ca = (0..<16).map { k -> SIMD3<Float> in
            SIMD3<Float>(Float(k) * 3.3, (k % 2 == 0) ? 0.9 : -0.9, 0)
        }
        let assigned = PSEA.assign(caPositions: ca)
        let sheets = assigned[2..<14].filter { $0.structure == .sheet }.count
        let helices = assigned.filter { $0.structure == .helix }.count
        #expect(sheets >= 8, "expected a strand, got \(sheets)/12 sheet")
        #expect(helices == 0, "an extended strand must not read as helix")
    }

    @Test("termini and short chains are coil with no confidence, not guesses")
    func termini() {
        #expect(PSEA.assign(caPositions: []).isEmpty)
        let tiny = PSEA.assign(caPositions: (0..<4).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) })
        #expect(tiny.count == 4)
        #expect(tiny.allSatisfy { $0.structure == .coil && $0.confidence == 0 })
    }

    @Test("angle and dihedral match known values")
    func geometry() {
        let a = SIMD3<Float>(1, 0, 0), b = SIMD3<Float>(0, 0, 0), c = SIMD3<Float>(0, 1, 0)
        #expect(abs(PSEA.angle(a, b, c) - 90) < 1e-3)

        // A planar trans arrangement has a dihedral of 180 degrees.
        let p0 = SIMD3<Float>(1, 1, 0), p1 = SIMD3<Float>(0, 1, 0)
        let p2 = SIMD3<Float>(0, 0, 0), p3 = SIMD3<Float>(-1, 0, 0)
        #expect(abs(abs(PSEA.dihedral(p0, p1, p2, p3)) - 180) < 1e-2)

        // A 90-degree twist.
        let q3 = SIMD3<Float>(0, 0, -1)
        #expect(abs(abs(PSEA.dihedral(p0, p1, p2, q3)) - 90) < 1e-2)
    }

    /// Without hysteresis a residue that flickers between states makes the renderer strobe.
    @Test("hysteresis holds a state until the change is sustained")
    func hysteresisHolds() {
        var h = SSHysteresis(window: 3, residueCount: 1)
        let helix = [SSAssignment(structure: .helix, confidence: 0.9)]
        let sheet = [SSAssignment(structure: .sheet, confidence: 0.9)]

        _ = h.smooth(helix); _ = h.smooth(helix)
        #expect(h.smooth(helix)[0].structure == .helix)

        // Two frames of sheet is not enough to flip it.
        #expect(h.smooth(sheet)[0].structure == .helix)
        #expect(h.smooth(sheet)[0].structure == .helix)
        // The third sustained frame flips it.
        #expect(h.smooth(sheet)[0].structure == .sheet)
    }

    @Test("an isolated one-frame flicker never changes the state")
    func hysteresisRejectsFlicker() {
        var h = SSHysteresis(window: 3, residueCount: 1)
        let helix = [SSAssignment(structure: .helix, confidence: 0.9)]
        let sheet = [SSAssignment(structure: .sheet, confidence: 0.9)]
        for _ in 0..<5 { _ = h.smooth(helix) }
        for _ in 0..<20 {
            #expect(h.smooth(sheet)[0].structure == .helix)   // one frame of noise
            #expect(h.smooth(helix)[0].structure == .helix)   // back again
        }
    }

    @Test("confidence tracks the incoming frame even while the state is held")
    func confidenceStaysLive() {
        var h = SSHysteresis(window: 3, residueCount: 1)
        for _ in 0..<4 { _ = h.smooth([SSAssignment(structure: .helix, confidence: 0.2)]) }
        let held = h.smooth([SSAssignment(structure: .sheet, confidence: 0.77)])
        #expect(held[0].structure == .helix)
        #expect(abs(held[0].confidence - 0.77) < 1e-5)
    }
}
