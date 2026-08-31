import Testing
import Foundation
@testable import FoldCore

/// The gallery's listening notes.
///
/// These read the shipping file rather than a fixture, for the same reason the style tests do:
/// a copy would pass while the real notes were broken or missing.
@Suite("Listening notes")
struct ListeningNotesTests {

    static var notesURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appending(path: "Apps/Shared/Resources/Notes/listening-notes.json")
    }

    /// Every trajectory that ships in the app.
    static var trajectoryIDs: [String] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let directory = url.appending(path: "Apps/PhoneFold/Resources")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "pftraj" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    @Test("every bundled protein has something to listen for")
    func everyTrajectoryIsCovered() throws {
        let notes = try ListeningNotes.load(from: try Data(contentsOf: Self.notesURL))
        let ids = Self.trajectoryIDs
        #expect(!ids.isEmpty)
        for id in ids {
            let note = try #require(notes[id], "\(id) has no listening note")
            #expect(!note.headline.isEmpty)
            #expect(!note.note.isEmpty)
            // A headline is a gallery tile, not a paragraph: one line at a small size.
            #expect(note.headline.count <= 44, "\(id): \"\(note.headline)\" is too long for a tile")
        }
        // And nothing describes a protein that is not there, which is how a note outlives the
        // trajectory it was written for.
        for id in notes.keys {
            #expect(ids.contains(id), "\(id) has a note but no trajectory")
        }
    }

    @Test("the notes say what a listener would otherwise get wrong")
    func notesCarryTheHonestClaims() throws {
        let notes = try ListeningNotes.load(from: try Data(contentsOf: Self.notesURL))
        // The three PLAN.md names, and the three things this app has to be honest about.
        let synuclein = try #require(notes["alpha_synuclein"])
        #expect(synuclein.note.lowercased().contains("disordered"))
        #expect(synuclein.note.lowercased().contains("never"),
                "an IDR's note has to say it never resolves")

        let gfp = try #require(notes["gfp"])
        #expect(gfp.note.lowercased().contains("barrel"))
        // GFP's bundled trajectory has a mean confidence of 34 and does not reach the barrel.
        // The note says so rather than describing a structure the film does not show.
        #expect(gfp.note.contains("34") || gfp.note.lowercased().contains("does not get there"))

        let genie = try #require(notes["genie2_76aa_seed1"])
        #expect(genie.note.lowercased().contains("never existed")
                || genie.note.lowercased().contains("noise"))

        let lysozyme = try #require(notes["lysozyme"])
        #expect(lysozyme.note.lowercased().contains("disulfide"))
    }

    @Test("a missing notes file is an empty gallery caption, not a crash")
    func missingNotesAreSurvivable() {
        // A missing note must never be a missing gallery: the app still folds, still draws and
        // still sings, it just has nothing extra to say.
        #expect(ListeningNotes.bundled(in: .main, named: "no-such-notes-file").isEmpty)
        #expect(throws: (any Error).self) {
            try ListeningNotes.load(from: Data("not json".utf8))
        }
    }
}
