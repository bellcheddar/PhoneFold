import Foundation

/// The folds this account has run, on whichever device ran them.
///
/// PLAN.md's cross-platform gate: "iCloud trajectory sync round-trips between two Simulators."
///
/// **Descriptions, not coordinates, and that is the third time the same argument has paid.** A
/// trajectory is megabytes; a fold is a deterministic function of the protein, the engine and
/// the seed, so what has to travel is `FoldHandoff` - the same payload Phase 5a defined for
/// Handoff and Phase 5c reuses for SharePlay. Syncing the coordinates would move a hundred
/// times the data to arrive at a fold the receiving device can compute exactly, at *its* own
/// residue cap and frame rate rather than the sending device's. There is one definition of
/// what a fold is, and this is the third thing carrying it.
///
/// The store is `NSUbiquitousKeyValueStore`, which is small (1 MB) and free, and a list of
/// descriptions fits in it with room to spare. That is the app's half; the merge is here,
/// because merging is where a sync goes wrong quietly.
public struct FoldLog: Sendable, Equatable, Codable {

    /// One fold, and when it was run.
    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var fold: FoldHandoff
        public var date: Date
        /// A name for the device that ran it, so the list can say where a fold came from.
        public var device: String

        /// What makes two entries the same fold.
        ///
        /// The protein, the engine and the seed - which is exactly what determines the
        /// trajectory. Not the progress: the same fold watched twice, or watched further on a
        /// second device, is one fold in a list of what you have looked at, and two entries
        /// differing only in how far through you got would fill the list with one protein.
        public var id: String {
            let seed = fold.seed.map(String.init) ?? "-"
            let source = fold.galleryID ?? fold.accession ?? fold.subject
            return "\(source)|\(fold.engine.rawValue)|\(seed)"
        }

        public init(fold: FoldHandoff, date: Date, device: String) {
            self.fold = fold
            self.date = date
            self.device = device
        }
    }

    /// How many folds are kept. Forty is a long tail of a list nobody scrolls, and it keeps the
    /// encoded log far inside the 1 MB the key-value store allows even with long accessions.
    public static let capacity = 40

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Self.tidied(entries)
    }

    /// Add a fold this device has just run.
    public mutating func record(_ entry: Entry) {
        entries = Self.tidied([entry] + entries)
    }

    /// Merge what another device knows into what this one knows.
    ///
    /// **Union, then newest wins per fold.** Both devices may have run folds while offline, so
    /// neither list is authoritative and taking one wholesale loses the other's. The same fold
    /// present in both keeps the later date, because that is when it was last watched.
    ///
    /// A device with a badly wrong clock can push its folds to the top and hold them there,
    /// which is a known limit of merging on timestamps and not one a cap can fix: the entries
    /// are still all present, just in the wrong order. Anything better needs a vector clock
    /// for a list of recently watched proteins, which is not a trade worth making.
    public func merged(with other: FoldLog) -> FoldLog {
        FoldLog(entries: entries + other.entries)
    }

    /// Newest first, one entry per fold, capped.
    private static func tidied(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        var kept: [Entry] = []
        // Sorted before dedup, so the survivor of a duplicate pair is the later one rather
        // than whichever happened to be first in the array.
        //
        // The id breaks ties in the date. Two entries with exactly the same timestamp is not
        // exotic - a merge of two logs written in the same second, or a test - and without a
        // second key the order would depend on the sort's stability, which is a property of
        // the input array rather than of the data.
        for entry in entries.sorted(by: { ($0.date, $0.id) > ($1.date, $1.id) }) {
            guard !seen.contains(entry.id) else { continue }
            seen.insert(entry.id)
            kept.append(entry)
            if kept.count == capacity { break }
        }
        return kept
    }

    // MARK: - The wire

    /// The key the ubiquitous store keeps this under.
    public static let storeKey = "foldLog"

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// **Nil rather than an empty log for unreadable data.** A log that failed to decode and a
    /// log with nothing in it are different situations: overwriting the first with the second
    /// is how a device with a version mismatch quietly deletes everything the account had.
    public static func decoded(from data: Data) -> FoldLog? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FoldLog.self, from: data)
    }
}
