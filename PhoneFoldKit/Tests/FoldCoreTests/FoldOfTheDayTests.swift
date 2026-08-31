import Testing
import Foundation
@testable import FoldCore

/// PLAN.md Phase 5b: "Standalone Fold of the Day: one precomputed short trajectory per day."
///
/// The picker is the part that can be wrong in a way nobody reports: a fold that repeats twice
/// in a fortnight reads as the feature being broken, and one that changes while you are looking
/// at it reads as a glitch. Neither shows up in a screenshot.
@Suite("The fold of the day")
struct FoldOfTheDayTests {

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Fixed, so the test is not a different test in Denver.
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: - Which fold

    @Test("the fold does not change while you are looking at it")
    func stableWithinADay() {
        let early = Self.date(2026, 9, 14, 0, 1)
        let late = Self.date(2026, 9, 14, 23, 59)
        #expect(FoldOfTheDay.index(on: early, count: 6, calendar: Self.calendar)
                == FoldOfTheDay.index(on: late, count: 6, calendar: Self.calendar))
    }

    @Test("and it does change overnight")
    func changesOvernight() {
        let today = FoldOfTheDay.index(on: Self.date(2026, 9, 14), count: 6,
                                       calendar: Self.calendar)
        let tomorrow = FoldOfTheDay.index(on: Self.date(2026, 9, 15), count: 6,
                                          calendar: Self.calendar)
        #expect(today != tomorrow)
    }

    /// The reason this is a cycle rather than a hash of the date. Hashing is a line shorter and
    /// repeats a protein within a fortnight by chance.
    @Test("every fold is shown once before any is shown twice")
    func cyclesBeforeRepeating() {
        let count = 6
        var seen: [Int] = []
        for offset in 0..<count {
            let day = Self.calendar.date(byAdding: .day, value: offset,
                                         to: Self.date(2026, 9, 14))!
            seen.append(FoldOfTheDay.index(on: day, count: count,
                                           calendar: Self.calendar)!)
        }
        #expect(Set(seen).count == count, "saw \(seen), which repeats inside one cycle")
    }

    /// Swift's `%` keeps the sign of its left operand, so a date before the reference gives a
    /// negative index and an out-of-bounds crash on the one day of the year nobody tests.
    @Test("a date before the reference day still picks a real fold")
    func beforeTheReference() {
        let index = FoldOfTheDay.index(on: Self.date(2020, 3, 1), count: 6,
                                       calendar: Self.calendar)
        #expect(index != nil)
        #expect((index ?? -1) >= 0 && (index ?? 99) < 6)
    }

    @Test("no folds means no fold, and one fold means that one every day")
    func degenerateCounts() {
        #expect(FoldOfTheDay.index(on: Date(), count: 0) == nil)
        #expect(FoldOfTheDay.index(on: Self.date(2026, 9, 14), count: 1,
                                   calendar: Self.calendar) == 0)
        #expect(FoldOfTheDay.index(on: Self.date(2027, 4, 2), count: 1,
                                   calendar: Self.calendar) == 0)
    }

    // MARK: - The resource

    static func frame(_ points: [Int], contacts: Int = 0) -> DailyFold.Frame {
        DailyFold.Frame(points: points, newContacts: contacts)
    }

    static func fold(_ frames: [DailyFold.Frame]) -> DailyFold {
        DailyFold(id: "trp_cage", name: "Trp-cage TC5b", residueCount: frames.first.map {
            $0.points.count / 2
        } ?? 0, provenance: "structure-based-go",
        quality: DailyFold.Quality(nativeFraction: 0.97, rmsdToNative: 0.68,
                                   radiusOfGyrationStart: 9.5, radiusOfGyrationEnd: 6.9,
                                   seconds: 10.7),
        frames: frames)
    }

    static func library(_ folds: [DailyFold], version: Int = 1) -> DailyFoldLibrary {
        DailyFoldLibrary(version: version, generated: "2026-08-31T20:00:00+00:00",
                         quantisedRange: 1000, folds: folds)
    }

    @Test("a library round-trips through the JSON the generator writes")
    func roundTrip() throws {
        let original = Self.library([Self.fold([Self.frame([0, 0, 1000, -500], contacts: 3)])])
        let data = try JSONEncoder().encode(original)
        #expect(try DailyFoldLibrary.decode(data) == original)
    }

    /// A newer resource may have quantised differently or changed what a frame carries.
    /// Drawing it anyway gives a protein-shaped thing that is not this protein, silently.
    @Test("a resource from the future is refused, not half-read")
    func versionMismatch() throws {
        let data = try JSONEncoder().encode(Self.library([Self.fold([Self.frame([0, 0])])],
                                                         version: 2))
        #expect(throws: DailyFoldLibrary.Failure.self) {
            _ = try DailyFoldLibrary.decode(data)
        }
    }

    @Test("an empty resource is refused rather than shown as an empty screen")
    func emptyLibrary() throws {
        let data = try JSONEncoder().encode(Self.library([]))
        #expect(throws: DailyFoldLibrary.Failure.self) {
            _ = try DailyFoldLibrary.decode(data)
        }
    }

    // MARK: - Drawing it

    @Test("the chain is interpolated between the frames either side")
    func interpolates() {
        let fold = Self.fold([Self.frame([0, 0]), Self.frame([1000, -1000])])
        let start = fold.chain(at: 0, range: 1000)
        #expect(start.count == 1)
        #expect(abs(start[0].x - 0) < 1e-9)

        // Half a frame in, at fifteen frames a second.
        let middle = fold.chain(at: 0.5 / DailyFold.framesPerSecond, range: 1000)
        #expect(abs(middle[0].x - 0.5) < 1e-9)
        #expect(abs(middle[0].y + 0.5) < 1e-9)
    }

    @Test("time before the start and past the end both hold rather than wrap or crash")
    func clampsAtBothEnds() {
        let fold = Self.fold([Self.frame([0, 0]), Self.frame([1000, 1000])])
        #expect(abs(fold.chain(at: -5, range: 1000)[0].x - 0) < 1e-9)
        let past = fold.chain(at: 60, range: 1000)
        #expect(abs(past[0].x - 1) < 1e-9, "the last frame holds, it does not loop")
        #expect(fold.frameIndex(at: 60) == 1)
        #expect(fold.frameIndex(at: -3) == 0)
    }

    @Test("an empty fold draws nothing rather than crashing")
    func emptyFoldDrawsNothing() {
        let fold = Self.fold([])
        #expect(fold.chain(at: 1, range: 1000).isEmpty)
        #expect(fold.duration == 0)
        #expect(fold.frameIndex(at: 1) == 0)
    }

    /// Two frames of different lengths cannot happen from the generator, but a truncated
    /// download or a hand-edited resource can produce one, and reading past the end of the
    /// shorter is a crash rather than a wrong picture.
    // MARK: - The resource the generator actually wrote

    /// The cross-language check, and the only one that can catch the two sides drifting:
    /// `Tools/make_fold_of_the_day.py` writes this file and the Watch decodes it, so a field
    /// renamed on one side is a screen that says "nothing baked for today" on the other.
    static var resource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // -> FoldCoreTests
            .deletingLastPathComponent()   // -> Tests
            .deletingLastPathComponent()   // -> PhoneFoldKit
            .deletingLastPathComponent()   // -> repo root
            .appending(path: "Apps/PhoneFold-watchOS/Resources/FoldOfTheDay.json")
    }

    @Test("the baked resource decodes, and every fold in it is a fold")
    func bakedResourceDecodes() throws {
        let library = try DailyFoldLibrary.decode(try Data(contentsOf: Self.resource))
        #expect(library.folds.count >= 2, "a daily fold needs more than one day of material")

        for fold in library.folds {
            #expect(fold.frames.count > 10, "\(fold.id) has \(fold.frames.count) frames")
            #expect(fold.residueCount > 0)
            // Every frame is the same chain, so every frame has the same number of points.
            let expected = fold.residueCount * 2
            for (index, frame) in fold.frames.enumerated() {
                #expect(frame.points.count == expected,
                        "\(fold.id) frame \(index) has \(frame.points.count) points")
            }
            // In the quantised box, not outside it.
            let widest = fold.frames.flatMap(\.points).map(abs).max() ?? 0
            #expect(widest <= library.quantisedRange,
                    "\(fold.id) reaches \(widest), outside the \(library.quantisedRange) box")

            // **The check that killed the first version of this resource.** It was baked from
            // ESMFold trunk readouts, which are already folded: 65% of protein G's contacts
            // formed on frame 1 and its width changed by one part in a thousand across the
            // whole trajectory. Everything upstream was correct and the output was an
            // animation of nothing happening.
            //
            // Radius of gyration is the measurement that means it. The projected span below
            // is a weaker proxy - the projection is two of three dimensions, so a chain that
            // collapses along the discarded axis barely moves in it - and it is checked too
            // only because it is the number the animation actually draws.
            #expect(fold.quality.radiusOfGyrationEnd
                        < fold.quality.radiusOfGyrationStart * 0.8,
                    "\(fold.id) Rg \(fold.quality.radiusOfGyrationStart) to \(fold.quality.radiusOfGyrationEnd) A: it does not collapse")
            let first = fold.frames.first!.points.map(abs).max() ?? 0
            let last = fold.frames.last!.points.map(abs).max() ?? 1
            #expect(Double(last) < Double(first) * 0.85,
                    "\(fold.id) draws \(last) against \(first): it does not visibly shrink")

            let total = fold.frames.reduce(0) { $0 + $1.newContacts }
            let onFirst = fold.frames.first!.newContacts
            #expect(total > 0, "\(fold.id) forms no contacts at all")
            #expect(Double(onFirst) < Double(total) * 0.25,
                    "\(fold.id) starts folded: \(onFirst) of \(total) contacts on frame 1")

            #expect(fold.provenance == "structure-based-go")
            #expect(fold.quality.nativeFraction > 0.8,
                    "\(fold.id) only reaches Q \(fold.quality.nativeFraction)")
            #expect(fold.quality.radiusOfGyrationEnd < fold.quality.radiusOfGyrationStart)
        }
    }

    @Test("frames of different lengths draw the shorter, not a crash")
    func raggedFrames() {
        let fold = Self.fold([Self.frame([0, 0, 100, 100]), Self.frame([500, 500])])
        #expect(fold.chain(at: 0.03, range: 1000).count == 1)
    }
}
