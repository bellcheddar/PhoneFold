import Testing
import Foundation
@testable import FoldCore

/// PhoneFold now has two engines with different epistemic status: foldingDiff *generates* a
/// novel protein and has no pLDDT, PathDiffusion *predicts* a named one and does. The type
/// system is where that distinction is kept honest, so these are not decorative tests.
@Suite("TrajectoryProvenance")
struct ProvenanceTests {

    @Test("every provenance round-trips through its wire value")
    func wireValues() throws {
        for p in TrajectoryProvenance.allCases {
            let data = try JSONEncoder().encode([p])
            #expect(try JSONDecoder().decode([TrajectoryProvenance].self, from: data) == [p])
        }
        #expect(TrajectoryProvenance.foldingDiffDenoising.rawValue == "foldingdiff-denoising")
        #expect(TrajectoryProvenance.pathDiffusionPathway.rawValue == "pathdiffusion-pathway")
    }

    @Test("an unknown provenance fails to decode rather than defaulting")
    func unknownProvenanceIsAnError() {
        let json = Data(#"["synthesised"]"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([TrajectoryProvenance].self, from: json)
        }
    }

    @Test("only the test fixture is unshippable")
    func shippability() {
        #expect(TrajectoryProvenance.testFixture.isShippable == false)
        for p in TrajectoryProvenance.allCases where p != .testFixture {
            #expect(p.isShippable, "\(p.rawValue) should be shippable")
        }
    }

    /// A foldingDiff protein has never existed. The app must be able to say so, and must
    /// never present a generated backbone as a prediction of anything in the PDB.
    @Test("only foldingDiff trajectories are generated rather than predicted")
    func generatedFlag() {
        #expect(TrajectoryProvenance.foldingDiffDenoising.isGenerated)
        #expect(TrajectoryProvenance.pathDiffusionPathway.isGenerated == false)
        #expect(TrajectoryProvenance.esmFoldReadout.isGenerated == false)
    }

    /// Calling denoising progress "pLDDT" would be a scientific claim foldingDiff cannot
    /// support. This is the check that stops it happening by accident.
    @Test("confidence source follows the engine, and the two labels never collide")
    func confidenceSource() {
        #expect(TrajectoryProvenance.foldingDiffDenoising.confidenceSource == .denoisingProgress)
        #expect(TrajectoryProvenance.pathDiffusionPathway.confidenceSource == .pLDDT)
        #expect(TrajectoryProvenance.esmFoldReadout.confidenceSource == .pLDDT)

        #expect(ConfidenceSource.pLDDT.displayName == "pLDDT")
        #expect(ConfidenceSource.denoisingProgress.displayName == "Resolution")
        let labels = Set(ConfidenceSource.allCases.map(\.displayName))
        #expect(labels.count == ConfidenceSource.allCases.count)
        #expect(labels.contains("pLDDT") && !labels.contains("PLDDT"))
    }
}
