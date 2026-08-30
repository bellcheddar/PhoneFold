import Testing
import Foundation
@testable import FoldAudio

/// The style profiles, and the file that actually ships.
///
/// These read `Apps/Shared/Resources/Styles` in the repository rather than a fixture copied
/// into the test bundle. A copy would pass while the shipping file was broken, which is the
/// only failure this suite exists to catch.
@Suite("Style profiles")
struct StyleProfileTests {

    /// The repository's own style directory, found by walking up from this source file.
    static var stylesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../PhoneFold/PhoneFoldKit/Tests/FoldAudioTests/StyleProfileTests.swift, so four
        // components up - the file, FoldAudioTests, Tests, PhoneFoldKit - is the repository.
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appending(path: "Apps/Shared/Resources/Styles")
    }

    static func voices(_ overrides: [String: VoiceSpec] = [:]) -> [String: VoiceSpec] {
        var all = Dictionary(uniqueKeysWithValues: Voice.allCases.map { ($0.rawValue, VoiceSpec()) })
        for (key, value) in overrides { all[key] = value }
        return all
    }

    static func profile(voices: [String: VoiceSpec]? = nil, progression: [Int] = [0],
                        voicings: [[Int]] = [[0, 2, 4]],
                        slow: Double = 60, fast: Double = 120) -> StyleProfile {
        StyleProfile(id: "test", name: "Test", summary: "", root: 57, mode: .minor,
                     tempoSlow: slow, tempoFast: fast, swing: 0,
                     voicings: voicings, progression: progression,
                     voices: voices ?? Self.voices())
    }

    // MARK: - The shipping files

    @Test("every style in the repository loads and is playable")
    func repositoryStylesLoad() throws {
        let loaded = try StyleLibrary.profiles(in: Self.stylesDirectory)
        #expect(!loaded.isEmpty, "no style profiles were found in \(Self.stylesDirectory.path)")
        for (id, profile) in loaded {
            #expect(profile.id == id)
            #expect(!profile.name.isEmpty)
            #expect(!profile.summary.isEmpty)
            // `profiles(in:)` already validates; this asserts it, so the check cannot be
            // quietly removed from the loader without a test noticing.
            #expect(throws: Never.self) { try profile.validate() }
        }
    }

    @Test("Fantasy is the style PLAN.md describes")
    func fantasyMatchesTheSpecification() throws {
        let fantasy = try StyleLibrary.profiles(in: Self.stylesDirectory)["fantasy"]
        let style = try #require(fantasy, "the default style is missing")

        // PLAN.md: "minor key, rapid arpeggiated figuration ... with R, K, D and E as
        // octave-shift triggers", after Tay et al., Heliyon 2021, 7(9):e07933.
        #expect(style.mode == .minor)
        #expect(Set(style.octaveShiftResidues) == ["R", "K", "D", "E"])

        // The arpeggio has to be able to articulate at speed: a long attack would smear the
        // figuration into the pad, which is the one thing this style cannot sound like.
        #expect(style.spec(.arpeggio).attack < 0.02)
        #expect(style.spec(.pad).attack > 0.3)

        // A tempo range that can actually accelerate, and stays musical at both ends.
        #expect(style.tempoFast >= style.tempoSlow * 1.5)
    }

    // MARK: - The JSON shape

    @Test("voices survive a round trip as a readable JSON object")
    func voicesEncodeAsAnObject() throws {
        // The reason `voices` is keyed by String and not by `Voice`: Swift encodes a
        // dictionary with a non-String key as a flat array of alternating keys and values,
        // which no one could hand-edit. This asserts the JSON is an object.
        let data = try JSONEncoder().encode(Self.profile())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let voices = try #require(object["voices"] as? [String: Any])
        #expect(Set(voices.keys) == Set(Voice.allCases.map(\.rawValue)))

        let decoded = try StyleLibrary.profile(from: data)
        #expect(decoded == Self.profile())
    }

    @Test("a style file the app cannot play is rejected on load, not during a fold")
    func validationCatchesUnplayableStyles() {
        var missing = Self.voices()
        missing["contact"] = nil
        #expect(throws: StyleProfile.Invalid.missingVoice(.contact)) {
            try Self.profile(voices: missing).validate()
        }
        #expect(throws: StyleProfile.Invalid.emptyProgression) {
            try Self.profile(progression: []).validate()
        }
        #expect(throws: StyleProfile.Invalid.emptyVoicings) {
            try Self.profile(voicings: []).validate()
        }
        #expect(throws: StyleProfile.Invalid.tempoRangeInverted(slow: 140, fast: 60)) {
            try Self.profile(slow: 140, fast: 60).validate()
        }
        #expect(throws: StyleProfile.Invalid.tempoOutOfRange(4)) {
            try Self.profile(slow: 4, fast: 60).validate()
        }
    }

    @Test("loading an invalid style names the style and the reason")
    func loadFailureIsSpecific() throws {
        var broken = Self.profile()
        broken.id = "broken"
        broken.progression = []
        let data = try JSONEncoder().encode(broken)
        do {
            _ = try StyleLibrary.profile(from: data)
            Issue.record("an empty progression should not have loaded")
        } catch let failure as StyleLibrary.Failure {
            #expect(failure.description.contains("broken"))
            #expect(failure.description.contains("progression"))
        }
    }

    // MARK: - Musical behaviour

    @Test("compaction drives an accelerando between the style's own limits")
    func tempoTracksCompaction() {
        let style = Self.profile(slow: 66, fast: 132)
        #expect(style.tempo(compaction: 0) == 66)
        #expect(style.tempo(compaction: 1) == 132)
        #expect(style.tempo(compaction: 0.5) == 99)
        // An unfolded chain can report a compaction outside 0...1 as the trajectory's own
        // extremes shift; the tempo must stay inside the style, not run away with it.
        #expect(style.tempo(compaction: -3) == 66)
        #expect(style.tempo(compaction: 9) == 132)
    }

    @Test("the scale comes from the profile's own key")
    func scaleFollowsTheProfile() {
        let style = Self.profile()
        #expect(style.scale.root == 57)
        #expect(style.scale.pitch(degree: 2) == 60)  // C, the minor third of A
    }

    @Test("an absent directory yields no styles rather than a crash")
    func missingDirectoryIsEmpty() throws {
        let nowhere = URL(fileURLWithPath: "/tmp/phonefold-no-such-styles-directory")
        #expect(try StyleLibrary.profiles(in: nowhere).isEmpty)
    }
}
