import Testing
import Foundation
@testable import FoldRender
import FoldCore

/// What VoiceOver says about the stage.
@Suite("Stage description")
struct StageDescriptionTests {

    @Test("the fold is described in words a person would use")
    func structureIsDescribedInWords() {
        // Myoglobin: eight helices, no sheet.
        #expect(StageDescription.structurePhrase((0.75, 0.0, 0.25))
            .hasPrefix("Mostly helical"))
        // A WW domain: three strands, no helix.
        #expect(StageDescription.structurePhrase((0.0, 0.45, 0.55))
            .hasPrefix("Mostly sheet"))
        // Protein G B1: one helix on a four-stranded sheet.
        #expect(StageDescription.structurePhrase((0.25, 0.35, 0.40))
            .hasPrefix("Alpha and beta"))
    }

    @Test("a trace of something is not worth naming")
    func traceStructureIsNotAnnounced() {
        // Two sheet residues in a 300-residue helical protein is not "alpha and beta".
        #expect(StageDescription.structurePhrase((0.60, 0.007, 0.393))
            .hasPrefix("Mostly helical"))
    }

    @Test("an unfolded chain is a state, not a failure to describe")
    func unfoldedChainIsDescribed() {
        // This is where every simulated fold begins, so it must read as a starting point
        // rather than as the description giving up.
        let phrase = StageDescription.structurePhrase((0, 0, 1))
        #expect(phrase == "Unstructured coil")
        #expect(!phrase.lowercased().contains("no "))
    }

    @Test("the sentence carries the protein, the fold and how far through it is")
    func sentenceIsComplete() {
        let sentence = StageDescription.describe(
            name: "Hen egg white lysozyme", residueCount: 129,
            fractions: (0.35, 0.08, 0.57), confidence: 94.1,
            confidenceSource: .pLDDT, progress: 0.62)
        #expect(sentence.contains("Hen egg white lysozyme"))
        #expect(sentence.contains("129 residues"))
        #expect(sentence.contains("Mostly helical"))
        // Named, not just numbered: three of the four engines do not report pLDDT, and a bare
        // number under the wrong name is worse than no number.
        #expect(sentence.contains("pLDDT 94"))
        #expect(sentence.contains("62 percent through"))
        #expect(sentence.hasSuffix("."))
    }

    @Test("a nameless protein still gets a sentence")
    func namelessProteinIsDescribed() {
        // Genie 2 invents a backbone: nothing to look up and nothing to call it.
        let sentence = StageDescription.describe(
            name: nil, residueCount: 64, fractions: (0.2, 0.3, 0.5), confidence: 100,
            confidenceSource: .denoisingProgress, progress: 1)
        #expect(sentence.contains("Protein, 64 residues"))
        #expect(sentence.contains(ConfidenceSource.denoisingProgress.displayName))
        #expect(!sentence.contains("pLDDT"))
    }
}
