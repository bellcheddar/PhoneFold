import Testing
import Foundation
import simd
@testable import FoldCore
@testable import FoldGeometry

@Suite("Comparing a prediction against an experimental structure")
struct StructureComparisonTests {

    /// A helix, so the two structures have a real shape to superpose rather than a line.
    static func structure(_ identifier: String, numbers: [Int],
                          offset: SIMD3<Float> = .zero,
                          jitter: Float = 0, chain: String = "A") -> StructureFile {
        let residues = numbers.map { number -> StructureFile.Residue in
            let t = Float(number) * 1.75
            let base = SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(number) * 1.5)
            let wobble = jitter == 0 ? SIMD3<Float>.zero
                : SIMD3<Float>(jitter * sin(Float(number)), 0, 0)
            return StructureFile.Residue(number: number, name: "ALA", chain: chain,
                                         ca: base + offset + wobble, bFactor: 20)
        }
        return StructureFile(identifier: identifier, residues: residues)
    }

    @Test("the same structure, moved, superposes back to essentially zero")
    func identicalStructures() throws {
        let reference = Self.structure("REF", numbers: Array(1...30))
        let moved = Self.structure("PRED", numbers: Array(1...30),
                                   offset: SIMD3(10, -5, 3))
        let result = try StructureComparison.compare(mobile: moved, reference: reference)
        #expect(result.matched == 30)
        #expect(result.rmsd < 0.001, "rmsd was \(result.rmsd)")
        #expect(result.deviations.allSatisfy { $0.deviation < 0.001 })
    }

    /// **The test this whole type exists for.** A crystal structure missing its first two
    /// residues and its last three still has to be compared to the right residues of the
    /// prediction. Matching by array position would pair prediction residue 1 with reference
    /// residue 3 and everything after it would be wrong, giving a large RMSD that reads as a
    /// bad prediction rather than as a bug.
    @Test("residues are matched by number, not by position in the array")
    func matchesByNumberNotIndex() throws {
        let prediction = Self.structure("PRED", numbers: Array(1...30))
        // The experimental structure: residues 3 to 27, disordered ends missing.
        let experimental = Self.structure("XTAL", numbers: Array(3...27),
                                          offset: SIMD3(4, 4, 4))

        let result = try StructureComparison.compare(mobile: prediction,
                                                     reference: experimental)
        #expect(result.matched == 25, "only the residues both files have")
        // Same shape, so matching by number gives essentially zero. Matching by index would
        // pair prediction residue 1 with experimental residue 3 and give a large value.
        #expect(result.rmsd < 0.001)
        #expect(result.onlyInMobile == [1, 2, 28, 29, 30])
        #expect(result.onlyInReference.isEmpty)
    }

    @Test("a genuine difference shows up in the residues that differ")
    func localDifference() throws {
        let reference = Self.structure("REF", numbers: Array(1...30))
        var residues = reference.residues
        // Push three residues out of place, and only those three.
        for index in 10...12 {
            residues[index] = StructureFile.Residue(
                number: residues[index].number, name: residues[index].name,
                chain: residues[index].chain,
                ca: residues[index].ca + SIMD3(6, 0, 0),
                bFactor: residues[index].bFactor)
        }
        let prediction = StructureFile(identifier: "PRED", residues: residues)

        let result = try StructureComparison.compare(mobile: prediction, reference: reference)
        #expect(result.rmsd > 0.5)
        let worst = result.worst(3).map(\.number).sorted()
        #expect(worst == [11, 12, 13], "the moved residues are the worst three, got \(worst)")
    }

    @Test("no shared numbering is refused with an explanation, not a wrong answer")
    func noCommonResidues() {
        let a = Self.structure("A", numbers: Array(1...20))
        let b = Self.structure("B", numbers: Array(500...520))
        #expect(throws: StructureComparison.Failure.self) {
            _ = try StructureComparison.compare(mobile: a, reference: b)
        }
    }

    @Test("two residues in common is not enough to superpose")
    func tooFew() {
        let a = Self.structure("A", numbers: [1, 2, 3, 4])
        let b = Self.structure("B", numbers: [3, 4])
        #expect(throws: StructureComparison.Failure.self) {
            _ = try StructureComparison.compare(mobile: a, reference: b)
        }
    }

    /// Quoting an RMSD without saying how much was compared invites reading 0.8 A over twelve
    /// residues of a three-hundred-residue protein as a good agreement.
    @Test("the summary states how many residues the number covers")
    func summaryStatesCoverage() throws {
        let prediction = Self.structure("PRED", numbers: Array(1...30))
        let experimental = Self.structure("XTAL", numbers: Array(3...27))
        let result = try StructureComparison.compare(mobile: prediction,
                                                     reference: experimental)
        #expect(result.summary.contains("25 residues"))
        #expect(result.summary.contains("unmatched"))
        #expect(result.summary.contains("chain A"))
    }

    /// **Matching by number is necessary and not sufficient**, and this is the case that shows
    /// it. Both files number from 1 and mean different things by it, because a UniProt entry
    /// includes the signal peptide and a structure of the mature protein does not. Measured on
    /// real files: AlphaFold P00698 against 1LYZ matched all 129 residues by number and
    /// returned 18.11 Å, which is not a bad prediction but the same structure eighteen
    /// residues out of register.
    @Test("two numberings that do not correspond are caught, not reported as a bad prediction")
    func numberingMismatchIsCaught() throws {
        // A prediction numbered from its construct: residues 19 to 48 are the real protein.
        let prediction = StructureFile(identifier: "PRED", residues:
            Self.structure("PRED", numbers: Array(1...48)).residues.enumerated().map { i, r in
                StructureFile.Residue(number: r.number,
                                      name: i < 18 ? "SER" : "ALA",
                                      chain: r.chain, ca: r.ca, bFactor: r.bFactor)
            })
        // The mature protein, numbered from 1, same shape as the prediction's 19 onwards.
        let experimental = StructureFile(identifier: "XTAL", residues:
            Self.structure("XTAL", numbers: Array(19...48)).residues.map { r in
                StructureFile.Residue(number: r.number - 18, name: "ALA", chain: r.chain,
                                      ca: r.ca, bFactor: r.bFactor)
            })

        let naive = try StructureComparison.compare(mobile: prediction,
                                                    reference: experimental)
        #expect(!naive.numberingAgrees, "the names disagree, so the numbering does not")
        #expect(naive.suggestedOffset == 18, "got \(String(describing: naive.suggestedOffset))")
        #expect(naive.summary.contains("do not use the same numbering"),
                "the summary must not lead with a number that means nothing")

        // Applying the offset it suggested gives the real answer.
        let corrected = try StructureComparison.compare(mobile: prediction,
                                                        reference: experimental, offset: 18)
        #expect(corrected.numberingAgrees)
        #expect(corrected.rmsd < 0.001)
        #expect(corrected.matched == 30)
        // Reported in the prediction's own numbering, not the shifted keys.
        #expect(corrected.onlyInMobile.allSatisfy { $0 >= 1 && $0 <= 18 })
    }

    /// The reference is the experimental structure and does not move; the prediction does.
    @Test("the reference stays put and the prediction is what moves")
    func referenceIsFixed() throws {
        let reference = Self.structure("REF", numbers: Array(1...20))
        let prediction = Self.structure("PRED", numbers: Array(1...20),
                                        offset: SIMD3(100, 100, 100))
        let result = try StructureComparison.compare(mobile: prediction, reference: reference)
        // The deviation is measured after superposition, so a pure translation is not a
        // difference in shape and must vanish.
        #expect(result.rmsd < 0.001, "a translation is not a structural difference")
    }
}
