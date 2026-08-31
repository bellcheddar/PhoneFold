import Foundation

/// What to listen for in each of the bundled proteins.
///
/// PLAN.md Phase 4's sample gallery: "the 12 bundled proteins as one-tap demos, each with a
/// note on what to listen for (GFP's barrel, an IDR that never resolves, lysozyme's
/// disulfide-pinned core)."
///
/// **Data rather than a table in the app**, for the same reason the styles are: these are
/// editorial, Marc is the one qualified to write them, and he should be able to change a word
/// without a recompile. `TrajectoryMetadata` also carries a `listeningNote`, and a bundle that
/// has one wins - so a trajectory generated in future can describe itself.
public struct ListeningNote: Codable, Sendable, Hashable {
    /// A few words for the gallery tile.
    public var headline: String
    /// A sentence or three for the stage, once it is playing.
    public var note: String

    public init(headline: String, note: String) {
        self.headline = headline
        self.note = note
    }
}

public enum ListeningNotes {

    /// Load the notes from a JSON file of `id: {headline, note}`.
    public static func load(from data: Data) throws -> [String: ListeningNote] {
        try JSONDecoder().decode([String: ListeningNote].self, from: data)
    }

    /// The notes that shipped in a bundle, or an empty set.
    ///
    /// Empty is not a failure: the app still folds, still draws and still sings, it just has
    /// nothing extra to say about a protein. A missing note must never be a missing gallery.
    public static func bundled(in bundle: Bundle = .main,
                               named name: String = "listening-notes") -> [String: ListeningNote] {
        guard let url = bundle.url(forResource: name, withExtension: "json",
                                   subdirectory: "Notes")
                ?? bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? load(from: data)
        else { return [:] }
        return notes
    }
}
