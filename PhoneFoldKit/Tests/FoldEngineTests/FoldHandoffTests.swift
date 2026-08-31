import Testing
import Foundation
@testable import FoldEngine

@Suite("Handoff: what one device tells another about a fold")
struct FoldHandoffTests {

    @Test("a payload survives the dictionary Handoff actually carries")
    func roundTrip() throws {
        let original = FoldHandoff(subject: "Trp-cage TC5b", galleryID: "trp_cage",
                                   engine: .structureBased, styleID: "jazz",
                                   progress: 0.42)
        let back = try #require(FoldHandoff.from(userInfo: original.userInfo))
        #expect(back == original)
    }

    @Test("a fetched accession and a generated seed both survive")
    func optionalFieldsSurvive() throws {
        let fetched = FoldHandoff(subject: "P69905", accession: "P69905",
                                  engine: .morph, styleID: "pop", progress: 0.1)
        #expect(FoldHandoff.from(userInfo: fetched.userInfo) == fetched)

        let generated = FoldHandoff(subject: "Generated backbone", engine: .generative,
                                    styleID: "fantasy", progress: 0.9, seed: 7)
        let back = try #require(FoldHandoff.from(userInfo: generated.userInfo))
        #expect(back.seed == 7, "without the seed the Mac generates a different protein")
        #expect(back == generated)
    }

    /// `NSUserActivity.userInfo` is plist-encoded, and a `UInt64` past `Int64.max` does not
    /// survive that. The app increments seeds freely, so this is reachable.
    @Test("a seed larger than Int64.max survives, because it is carried as a string")
    func largeSeed() throws {
        let big = UInt64(Int64.max) + 12345
        let payload = FoldHandoff(subject: "Generated backbone", engine: .generative,
                                  styleID: "fantasy", progress: 0, seed: big)
        let back = try #require(FoldHandoff.from(userInfo: payload.userInfo))
        #expect(back.seed == big)
    }

    /// **Nil rather than defaults.** A continuation that quietly substitutes the default engine
    /// for a missing field does not continue anything: it starts something else on the other
    /// machine and looks like it worked.
    @Test("a payload missing any required field is refused, not filled in")
    func incompleteIsRefused() {
        let complete = FoldHandoff(subject: "Trp-cage TC5b", galleryID: "trp_cage",
                                   engine: .structureBased, styleID: "jazz", progress: 0.4)
        for key in ["subject", "engine", "style", "progress"] {
            var info = complete.userInfo
            info.removeValue(forKey: key)
            #expect(FoldHandoff.from(userInfo: info) == nil,
                    "a payload with no \(key) must not be accepted")
        }
        #expect(FoldHandoff.from(userInfo: nil) == nil)
        #expect(FoldHandoff.from(userInfo: [:]) == nil)
    }

    @Test("an engine name this build does not know is refused rather than defaulted")
    func unknownEngine() {
        var info = FoldHandoff(subject: "X", engine: .morph, styleID: "jazz",
                               progress: 0).userInfo
        info["engine"] = "quantum-annealing"
        #expect(FoldHandoff.from(userInfo: info) == nil,
                "a newer phone's engine must not silently become this Mac's default")
    }

    /// The type string is the contract between the two apps and appears in both Info.plists.
    /// A typo in either means the continuation never arrives, with no error anywhere.
    @Test("the activity type is the reverse-DNS name both apps declare")
    func activityType() {
        #expect(FoldHandoff.activityType == "com.mdeller.phonefold.fold")
    }

    @Test("the title names the protein, because that is what the other device shows")
    func title() {
        let payload = FoldHandoff(subject: "Green fluorescent protein", engine: .morph,
                                  styleID: "surf", progress: 0)
        #expect(payload.title.contains("Green fluorescent protein"))
    }
}
