import Testing
import Foundation
@testable import FoldEngine

/// PLAN.md's cross-platform gate: "iCloud trajectory sync round-trips between two Simulators."
///
/// Two simulators signed into one iCloud account is Marc's to arrange. What can be settled here
/// is the merge, which is where a sync goes wrong quietly: nothing errors, entries just vanish.
@Suite("The folds this account has run")
struct FoldLogTests {

    static func fold(_ gallery: String, engine: FoldingEngine = .structureBased,
                     seed: UInt64? = nil, progress: Double = 1) -> FoldHandoff {
        FoldHandoff(subject: gallery, galleryID: gallery, engine: engine,
                    styleID: "fantasy", progress: progress, seed: seed)
    }

    static func entry(_ gallery: String, minutesAgo: Double, device: String = "iPhone",
                      engine: FoldingEngine = .structureBased,
                      seed: UInt64? = nil, progress: Double = 1) -> FoldLog.Entry {
        FoldLog.Entry(fold: fold(gallery, engine: engine, seed: seed, progress: progress),
                      date: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
                      device: device)
    }

    @Test("the newest fold is first")
    func newestFirst() {
        var log = FoldLog()
        log.record(Self.entry("ubiquitin", minutesAgo: 30))
        log.record(Self.entry("gfp", minutesAgo: 10))
        log.record(Self.entry("lysozyme", minutesAgo: 20))
        #expect(log.entries.map(\.fold.subject) == ["gfp", "lysozyme", "ubiquitin"])
    }

    /// Watching the same protein again is the same fold, not a second one - otherwise a list
    /// of forty fills with one protein and shows nothing else you have looked at.
    @Test("the same fold twice is one entry, at the later time")
    func duplicatesCollapse() {
        var log = FoldLog()
        log.record(Self.entry("ubiquitin", minutesAgo: 60, progress: 0.2))
        log.record(Self.entry("ubiquitin", minutesAgo: 5, progress: 0.9))
        #expect(log.entries.count == 1)
        #expect(log.entries[0].fold.progress == 0.9, "the later watching wins")
    }

    /// And what makes two folds different: the protein, the engine and the seed, which is
    /// exactly what determines the trajectory.
    @Test("a different engine or seed is a different fold")
    func identityIsWhatDeterminesTheTrajectory() {
        var log = FoldLog()
        log.record(Self.entry("ubiquitin", minutesAgo: 30, engine: .structureBased))
        log.record(Self.entry("ubiquitin", minutesAgo: 20, engine: .morph))
        log.record(Self.entry("generated", minutesAgo: 10, engine: .generative, seed: 1))
        log.record(Self.entry("generated", minutesAgo: 5, engine: .generative, seed: 2))
        #expect(log.entries.count == 4)
    }

    /// The one that matters. Both devices ran folds while offline, so neither list is
    /// authoritative: taking one wholesale silently loses everything the other did.
    @Test("merging keeps what both devices did")
    func mergeIsAUnion() {
        var phone = FoldLog()
        phone.record(Self.entry("ubiquitin", minutesAgo: 30, device: "iPhone"))
        phone.record(Self.entry("gfp", minutesAgo: 25, device: "iPhone"))

        var mac = FoldLog()
        mac.record(Self.entry("lysozyme", minutesAgo: 20, device: "Mac"))
        mac.record(Self.entry("myoglobin", minutesAgo: 15, device: "Mac"))

        let merged = phone.merged(with: mac)
        #expect(Set(merged.entries.map(\.fold.subject))
                == ["ubiquitin", "gfp", "lysozyme", "myoglobin"])
        #expect(merged.entries.map(\.fold.subject)
                == ["myoglobin", "lysozyme", "gfp", "ubiquitin"], "newest first, still")
    }

    @Test("a fold both devices ran keeps the later watching, and its device")
    func mergeResolvesDuplicates() {
        var phone = FoldLog()
        phone.record(Self.entry("ubiquitin", minutesAgo: 60, device: "iPhone", progress: 0.3))
        var mac = FoldLog()
        mac.record(Self.entry("ubiquitin", minutesAgo: 5, device: "Mac", progress: 1))

        let merged = phone.merged(with: mac)
        #expect(merged.entries.count == 1)
        #expect(merged.entries[0].device == "Mac")
        #expect(merged.entries[0].fold.progress == 1)
    }

    @Test("merging is the same whichever way round it is done")
    func mergeIsSymmetric() {
        var a = FoldLog()
        a.record(Self.entry("ubiquitin", minutesAgo: 30))
        a.record(Self.entry("gfp", minutesAgo: 10))
        var b = FoldLog()
        b.record(Self.entry("lysozyme", minutesAgo: 20))
        b.record(Self.entry("ubiquitin", minutesAgo: 5))
        #expect(a.merged(with: b) == b.merged(with: a))
    }

    /// Two entries written in the same second is not exotic - a merge, or a test - and without
    /// a second sort key the order would depend on the input array rather than on the data.
    @Test("entries sharing a timestamp still order deterministically")
    func tiesAreDeterministic() {
        let one = Self.entry("alpha", minutesAgo: 10)
        let two = Self.entry("beta", minutesAgo: 10)
        #expect(FoldLog(entries: [one, two]) == FoldLog(entries: [two, one]))
    }

    @Test("the log is capped, keeping the newest")
    func capped() {
        var log = FoldLog()
        for index in 0..<(FoldLog.capacity + 15) {
            log.record(Self.entry("protein\(index)", minutesAgo: Double(200 - index)))
        }
        #expect(log.entries.count == FoldLog.capacity)
        #expect(log.entries.first?.fold.subject == "protein\(FoldLog.capacity + 14)")
    }

    // MARK: - The wire

    @Test("a log survives the trip through the ubiquitous store")
    func roundTrip() throws {
        var log = FoldLog()
        log.record(Self.entry("ubiquitin", minutesAgo: 5))
        log.record(Self.entry("generated", minutesAgo: 1, engine: .generative, seed: 99))
        let decoded = FoldLog.decoded(from: try log.encoded())
        #expect(decoded == log)
        #expect(decoded?.entries.first?.fold.seed == 99, "the seed is the fold's identity")
    }

    /// **Nil, not an empty log.** A log that failed to decode and a log with nothing in it are
    /// different situations, and treating the first as the second is how a device with a
    /// version mismatch quietly deletes everything the account had.
    @Test("unreadable data decodes to nothing rather than to an empty log")
    func corruptDataIsNotAnEmptyLog() {
        #expect(FoldLog.decoded(from: Data("not a log".utf8)) == nil)
        #expect(FoldLog.decoded(from: Data()) == nil)
    }

    @Test("an encoded log fits the ubiquitous store's budget with room to spare")
    func fitsTheStore() throws {
        var log = FoldLog()
        for index in 0..<FoldLog.capacity {
            log.record(FoldLog.Entry(
                fold: FoldHandoff(subject: String(repeating: "X", count: 60),
                                  accession: "A0A0A0A0A\(index)",
                                  engine: .generative, styleID: "hydrophobic-blues",
                                  progress: 0.5, seed: .max),
                date: Date(timeIntervalSince1970: 1_800_000_000 - Double(index)),
                device: "Marc's MacBook Pro (16-inch, 2021)"))
        }
        let size = try log.encoded().count
        // NSUbiquitousKeyValueStore allows 1 MB in total and 1 MB per key. The bound is tight
        // on purpose rather than generous: a loose one would pass just as well if an entry
        // grew by a factor of ten, and the whole argument for syncing descriptions instead of
        // coordinates rests on this staying small. It is also the only place the size is
        // written down, so METRICS.md quotes this number rather than a guess at it.
        #expect(size > 5_000, "a full log encoded to only \(size) bytes - is it really full?")
        #expect(size < 12_000, "a full log encodes to \(size) bytes")
    }
}
