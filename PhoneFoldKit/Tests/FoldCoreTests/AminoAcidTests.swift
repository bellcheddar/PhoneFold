import Testing
import Foundation
@testable import FoldCore

@Suite("AminoAcid")
struct AminoAcidTests {

    @Test("all twenty standard residues plus unknown are present")
    func caseCount() {
        #expect(AminoAcid.allCases.count == 21)
        let codes = Set(AminoAcid.allCases.map(\.code))
        #expect(codes == Set("ACDEFGHIKLMNPQRSTVWYX"))
    }

    @Test("lookup is case-insensitive and never fails")
    func lookup() {
        #expect(AminoAcid(code: "a") == .alanine)
        #expect(AminoAcid(code: "A") == .alanine)
        #expect(AminoAcid(code: "W") == .tryptophan)
        // Ambiguity codes and junk resolve to unknown rather than trapping: a sequence
        // with a B in it should still fold.
        for junk in "BZJUO*-1?" {
            #expect(AminoAcid(code: junk) == .unknown, "\(junk) should resolve to unknown")
        }
    }

    @Test("three-letter codes are unique and three characters long")
    func threeLetterCodes() {
        let codes = AminoAcid.allCases.map(\.threeLetterCode)
        #expect(Set(codes).count == codes.count)
        #expect(codes.allSatisfy { $0.count == 3 && $0 == $0.uppercased() })
    }

    // Spot values straight out of Kyte & Doolittle 1982, Table 1. If these drift, the
    // hydrophobicity colour mode and every core-formation event in the score drift with them.
    @Test("Kyte-Doolittle hydropathy matches the published table",
          arguments: [(Character("I"), Float(4.5)), ("V", 4.2), ("L", 3.8), ("F", 2.8),
                      ("C", 2.5), ("M", 1.9), ("A", 1.8), ("G", -0.4), ("T", -0.7),
                      ("S", -0.8), ("W", -0.9), ("Y", -1.3), ("P", -1.6), ("H", -3.2),
                      ("E", -3.5), ("Q", -3.5), ("D", -3.5), ("N", -3.5), ("K", -3.9),
                      ("R", -4.5)])
    func hydropathy(code: Character, expected: Float) {
        #expect(AminoAcid(code: code).hydropathy == expected)
    }

    @Test("hydropathy spans the full published range and unknown sits at zero")
    func hydropathyRange() {
        let standard = AminoAcid.allCases.filter { $0 != .unknown }
        #expect(standard.map(\.hydropathy).min() == -4.5)
        #expect(standard.map(\.hydropathy).max() == 4.5)
        #expect(AminoAcid.unknown.hydropathy == 0)
        #expect(AminoAcid.unknown.isHydrophobic == false)
    }

    @Test("exactly nine residues are hydrophobic by a positive index")
    func hydrophobicSet() {
        let hydrophobic = Set(AminoAcid.allCases.filter(\.isHydrophobic).map(\.code))
        #expect(hydrophobic == Set("IVLFCMA"))
    }

    @Test("only R, K, D and E carry charge — the Fantasy octave-shift triggers")
    func charge() {
        #expect(AminoAcid(code: "R").charge == 1)
        #expect(AminoAcid(code: "K").charge == 1)
        #expect(AminoAcid(code: "D").charge == -1)
        #expect(AminoAcid(code: "E").charge == -1)
        // Histidine is neutral at physiological pH by the usual convention.
        #expect(AminoAcid(code: "H").charge == 0)
        let charged = Set(AminoAcid.allCases.filter(\.isCharged).map(\.code))
        #expect(charged == Set("RKDE"))
    }
}
