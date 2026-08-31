import Foundation
import FoldCore

/// What the stage would say, to somebody who cannot see it.
///
/// PLAN.md Phase 4 asks for VoiceOver throughout. A control can be labelled where it is
/// declared, but the stage is a protein turning in space - the one thing in the app with no
/// text of its own - so its description has to be built from the fold's state.
///
/// **A pure function, in the package, so it can be tested.** The alternative is a string
/// assembled inside a view, where the only way to check it is to turn VoiceOver on and listen.
public enum StageDescription {

    /// A sentence describing a frame.
    ///
    /// Deliberately not a reading of every number on the HUD. VoiceOver speaks this on every
    /// significant change, and a listener wants to know what the protein is doing, not its
    /// radius of gyration to three decimal places.
    public static func describe(name: String?, residueCount: Int,
                                fractions: (helix: Float, sheet: Float, coil: Float),
                                confidence: Float, confidenceSource: ConfidenceSource,
                                progress: Double) -> String {
        var parts: [String] = []
        parts.append("\(name ?? "Protein"), \(residueCount) residues")

        // Structure content, in words rather than percentages: "mostly helical" is what a
        // person would say, and it is what the shape on screen actually reads as.
        parts.append(structurePhrase(fractions))

        // The confidence is named, for the same reason the caption and the mmCIF name it:
        // three of the four engines do not report pLDDT.
        parts.append("\(confidenceSource.displayName) \(Int(confidence.rounded()))")
        parts.append("\(Int((progress * 100).rounded())) percent through")
        return parts.joined(separator: ". ") + "."
    }

    /// How a structural biologist would describe the fold in three words.
    static func structurePhrase(_ f: (helix: Float, sheet: Float, coil: Float)) -> String {
        let helix = Int((f.helix * 100).rounded())
        let sheet = Int((f.sheet * 100).rounded())
        // Below a tenth there is not enough of something to be worth naming: a two-residue
        // strand in a 300-residue protein is not "alpha and beta".
        let hasHelix = f.helix >= 0.1
        let hasSheet = f.sheet >= 0.1
        switch (hasHelix, hasSheet) {
        case (true, true):
            return "Alpha and beta, \(helix) percent helix and \(sheet) percent sheet"
        case (true, false):
            return "Mostly helical, \(helix) percent"
        case (false, true):
            return "Mostly sheet, \(sheet) percent"
        case (false, false):
            // Not "no structure": an unfolded chain is the *start* of every simulated fold and
            // is a real state, not a failure to describe.
            return "Unstructured coil"
        }
    }
}
