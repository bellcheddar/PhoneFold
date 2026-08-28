import Testing
import Foundation
import simd
@testable import FoldCore

@Suite("SSAssignment")
struct SSAssignmentTests {
    @Test("confidence is clamped to 0...1 on construction")
    func clamping() {
        #expect(SSAssignment(structure: .helix, confidence: 1.4).confidence == 1)
        #expect(SSAssignment(structure: .helix, confidence: -0.2).confidence == 0)
        #expect(SSAssignment(structure: .sheet, confidence: 0.35).confidence == 0.35)
    }

    @Test("DSSP-style codes")
    func codes() {
        #expect(SecondaryStructure.helix.code == "H")
        #expect(SecondaryStructure.sheet.code == "E")
        #expect(SecondaryStructure.coil.code == "C")
    }

    @Test("a trajectory starts unassigned")
    func unassigned() {
        #expect(SSAssignment.unassigned.structure == .coil)
        #expect(SSAssignment.unassigned.confidence == 0)
    }
}

@Suite("ContactEvent")
struct ContactEventTests {
    @Test("indices are ordered regardless of construction order")
    func ordering() {
        let a = ContactEvent(i: 40, j: 7, distance: 7.2, isHydrophobicPair: true)
        #expect(a.i == 7 && a.j == 40)
        #expect(a.separation == 33)
    }

    // The register mapping in the score hangs off these boundaries, so pin them.
    @Test("separation classes match the contact-order convention",
          arguments: [(3, ContactRange.local), (5, .local),
                      (6, .medium), (11, .medium),
                      (12, .longRange), (200, .longRange)])
    func rangeClasses(separation: Int, expected: ContactRange) {
        #expect(ContactRange(separation: separation) == expected)
        #expect(ContactRange(separation: -separation) == expected)
    }

    @Test("hydrophobic pairing is carried through")
    func hydrophobicPair() {
        let core = ContactEvent(i: 5, j: 60, distance: 6.1, isHydrophobicPair: true)
        #expect(core.isHydrophobicPair)
        #expect(core.range == .longRange)
    }
}

@Suite("FoldFrame")
struct FoldFrameTests {

    /// A minimal well-formed frame. Coordinates are placed on an ideal alpha-helix so the
    /// geometry is real rather than arbitrary: rise 1.5 A per residue, 100 degrees of twist,
    /// CA radius 2.3 A.
    static func helixFrame(residues: Int, ss: SecondaryStructure = .helix) -> FoldFrame {
        var backbone: [BackboneResidue] = []
        for k in 0..<residues {
            let theta = Float(k) * 100 * .pi / 180
            let z = Float(k) * 1.5
            let ca = SIMD3<Float>(2.3 * cos(theta), 2.3 * sin(theta), z)
            backbone.append(BackboneResidue(
                n: ca + SIMD3<Float>(-0.5, 0, -0.6),
                ca: ca,
                c: ca + SIMD3<Float>(0.5, 0, 0.6),
                o: ca + SIMD3<Float>(0.9, 0.6, 0.9)))
        }
        let plddt = [Float](repeating: 82, count: residues)
        let assignment = SSAssignment(structure: ss, confidence: 0.9)
        return FoldFrame(
            index: 0, recycle: 0, blockIndex: 0,
            backbone: backbone,
            pLDDT: plddt,
            secondaryStructure: [SSAssignment](repeating: assignment, count: residues),
            newContacts: [],
            radiusOfGyration: 12.0,
            meanPLDDT: 82,
            isInterpolated: false)
    }

    @Test("a well-formed frame validates")
    func wellFormed() {
        let f = Self.helixFrame(residues: 30)
        #expect(f.isWellFormed)
        #expect(f.residueCount == 30)
    }

    @Test("mismatched per-residue arrays are rejected")
    func arrayLengthMismatch() {
        let f = Self.helixFrame(residues: 30)
        let short = FoldFrame(
            index: 0, recycle: 0, blockIndex: 0,
            backbone: f.backbone,
            pLDDT: Array(f.pLDDT.dropLast()),          // 29 against 30 residues
            secondaryStructure: f.secondaryStructure,
            newContacts: [], radiusOfGyration: 12, meanPLDDT: 82, isInterpolated: false)
        #expect(short.isWellFormed == false)
    }

    // Phase 2's gate asserts zero geometry NaNs across a full sample trajectory, and this
    // is the predicate it uses. A validator that has only ever seen good input is not a
    // validator, so prove it catches each way a coordinate can go bad.
    @Test("non-finite coordinates are rejected", arguments: [Float.nan, .infinity, -.infinity])
    func nonFiniteCoordinates(bad: Float) {
        var f = Self.helixFrame(residues: 10)
        var backbone = f.backbone
        backbone[4].ca.y = bad
        f = FoldFrame(
            index: 0, recycle: 0, blockIndex: 0, backbone: backbone,
            pLDDT: f.pLDDT, secondaryStructure: f.secondaryStructure, newContacts: [],
            radiusOfGyration: 12, meanPLDDT: 82, isInterpolated: false)
        #expect(f.isWellFormed == false)
    }

    @Test("a non-finite metric is rejected")
    func nonFiniteMetric() {
        let g = Self.helixFrame(residues: 10)
        let f = FoldFrame(
            index: 0, recycle: 0, blockIndex: 0, backbone: g.backbone,
            pLDDT: g.pLDDT, secondaryStructure: g.secondaryStructure, newContacts: [],
            radiusOfGyration: .nan, meanPLDDT: 82, isInterpolated: false)
        #expect(f.isWellFormed == false)
    }

    @Test("structure fractions sum to one and split correctly")
    func structureFractions() {
        let f = Self.helixFrame(residues: 100)
        var ss = f.secondaryStructure
        for k in 0..<25 { ss[k] = SSAssignment(structure: .sheet, confidence: 0.8) }
        for k in 25..<45 { ss[k] = SSAssignment(structure: .coil, confidence: 0.5) }
        let g = FoldFrame(
            index: 0, recycle: 0, blockIndex: 0, backbone: f.backbone, pLDDT: f.pLDDT,
            secondaryStructure: ss, newContacts: [], radiusOfGyration: 12,
            meanPLDDT: 82, isInterpolated: false)
        let (h, e, c) = g.structureFractions
        #expect(abs(h - 0.55) < 1e-6)
        #expect(abs(e - 0.25) < 1e-6)
        #expect(abs(c - 0.20) < 1e-6)
        #expect(abs(h + e + c - 1) < 1e-6)
    }

    @Test("an empty frame reports zero fractions rather than dividing by zero")
    func emptyFrame() {
        let f = FoldFrame(index: 0, recycle: 0, blockIndex: 0, backbone: [], pLDDT: [],
                          secondaryStructure: [], newContacts: [], radiusOfGyration: 0,
                          meanPLDDT: 0, isInterpolated: false)
        let (h, e, c) = f.structureFractions
        #expect(h == 0 && e == 0 && c == 0)
    }

    @Test("backbone atoms come out in canonical mmCIF order")
    func atomOrder() {
        let r = Self.helixFrame(residues: 1).backbone[0]
        #expect(r.atoms.map(\.name) == ["N", "CA", "C", "O"])
    }
}
