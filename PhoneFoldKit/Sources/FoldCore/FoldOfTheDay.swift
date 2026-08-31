import Foundation

/// The fold the wrist shows today, and the flat data it draws.
///
/// PLAN.md Phase 5b: "Standalone Fold of the Day: one precomputed short trajectory per day,
/// playable on the Watch alone as a small animation with haptics. No inference, no phone
/// required."
///
/// **Everything here is already computed.** The Watch runs no inference, and it should not run
/// geometry either: decoding a `.pftraj`, building a tube mesh and tracking contacts on a wrist
/// is exactly the ambition PLAN warns Watch apps die of. `Tools/make_fold_of_the_day.py` folds
/// each protein with the structure-based model, projects it onto the folded structure's own
/// principal plane, quantises it and counts the contacts; what arrives here is a list of
/// integer points and a number per frame.
///
/// In `FoldCore` rather than in the watch app because the *picker* is the part that can be
/// wrong in a way nobody notices - a fold that repeats twice in a week, or one that changes
/// while you are looking at it - and `FoldCore` is where things that can be tested live.
public enum FoldOfTheDay {

    /// The day the cycle counts from. Arbitrary, and fixed for ever: moving it would reshuffle
    /// every future day, which nobody would see as a bug and everybody would see as the app
    /// showing them the same protein twice.
    public static let reference = DateComponents(year: 2026, month: 1, day: 1)

    /// Which fold to show on this date, or nil if there are none.
    ///
    /// **A cycle, not a hash.** Hashing the date into the list is one line shorter and gives
    /// you the same protein twice in a fortnight by chance, which reads as the feature being
    /// broken. Counting days means every fold is shown once before any is shown twice.
    ///
    /// **Counted in whole local days**, so the fold changes at midnight where the wearer is
    /// rather than at some hour that depends on their longitude. Crossing a time zone can move
    /// the day by one, which is right: it is a different day there.
    public static func index(on date: Date, count: Int,
                             calendar: Calendar = .current) -> Int? {
        guard count > 0 else { return nil }
        guard let start = calendar.date(from: reference) else { return nil }
        let from = calendar.startOfDay(for: start)
        let to = calendar.startOfDay(for: date)
        guard let days = calendar.dateComponents([.day], from: from, to: to).day else {
            return nil
        }
        // Modulo twice: Swift's % keeps the sign of the left operand, so a date before the
        // reference gives a negative index and an out-of-bounds crash on the one day of the
        // year nobody tests.
        return ((days % count) + count) % count
    }
}

/// A day's worth of folds, as baked.
public struct DailyFoldLibrary: Codable, Sendable, Equatable {

    /// The format's own version, so a watch app older than its resource refuses rather than
    /// decodes half of it.
    public let version: Int
    public let generated: String
    /// The box the integer coordinates live in: they run from `-quantisedRange` to
    /// `+quantisedRange` on the widest frame's widest axis.
    public let quantisedRange: Int
    public let folds: [DailyFold]

    public static let currentVersion = 1

    public init(version: Int, generated: String, quantisedRange: Int, folds: [DailyFold]) {
        self.version = version
        self.generated = generated
        self.quantisedRange = quantisedRange
        self.folds = folds
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsupportedVersion(Int)
        case empty
        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "The Fold of the Day resource is version \(version) and this app reads "
                    + "version \(DailyFoldLibrary.currentVersion)."
            case .empty: "The Fold of the Day resource contains no folds."
            }
        }
    }

    public static func decode(_ data: Data) throws -> DailyFoldLibrary {
        let library = try JSONDecoder().decode(DailyFoldLibrary.self, from: data)
        // **Refused rather than tolerated.** A newer resource may have quantised its
        // coordinates differently or changed what a frame carries; drawing it anyway would
        // produce a protein-shaped thing that is not this protein, and nothing would say so.
        guard library.version == currentVersion else {
            throw Failure.unsupportedVersion(library.version)
        }
        guard !library.folds.isEmpty else { throw Failure.empty }
        return library
    }

    /// Today's fold.
    public func fold(on date: Date = Date(), calendar: Calendar = .current) -> DailyFold? {
        FoldOfTheDay.index(on: date, count: folds.count, calendar: calendar)
            .map { folds[$0] }
    }
}

/// One protein folding, flat enough for a watch to draw without thinking.
public struct DailyFold: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    public let name: String
    public let residueCount: Int
    /// Where the trajectory came from. `structure-based-go` for everything baked so far; it is
    /// recorded rather than assumed because the first version of this resource was baked from
    /// ESMFold trunk readouts, which turned out to show no folding at all.
    public let provenance: String
    public let quality: Quality
    public let frames: [Frame]

    /// What the fold achieved, so the wrist can say so rather than implying it.
    public struct Quality: Codable, Sendable, Equatable {
        public let nativeFraction: Double
        public let rmsdToNative: Double
        public let radiusOfGyrationStart: Double
        public let radiusOfGyrationEnd: Double
        public let seconds: Double
    }

    public struct Frame: Codable, Sendable, Equatable {
        /// x and y interleaved, in the library's quantised box.
        public let points: [Int]
        /// Contacts that formed on this frame, at the same 8.0 A / 8.5 A / separation-3
        /// thresholds `ContactTracker` uses, so the wrist's haptics land where the phone's do.
        public let newContacts: Int

        public init(points: [Int], newContacts: Int) {
            self.points = points
            self.newContacts = newContacts
        }
    }

    public init(id: String, name: String, residueCount: Int, provenance: String,
                quality: Quality, frames: [Frame]) {
        self.id = id
        self.name = name
        self.residueCount = residueCount
        self.provenance = provenance
        self.quality = quality
        self.frames = frames
    }

    /// How long the animation runs, at the rate the wrist plays it.
    public static let framesPerSecond: Double = 15

    public var duration: Double {
        frames.isEmpty ? 0 : Double(frames.count) / Self.framesPerSecond
    }

    /// The chain at a moment, interpolated between the two frames either side.
    ///
    /// Coordinates come back in -1...1 on the widest axis of the widest frame, so a caller
    /// scales by whatever it has room for and nothing else.
    ///
    /// **Interpolated, and the scale is not.** Ninety frames over six seconds is fifteen a
    /// second, which reads as a flicker book rather than as a fold; interpolating between them
    /// costs a subtraction per residue. What must *not* be interpolated - or renormalised - is
    /// the scale: the whole trajectory shares one, because a coil and a folded core drawn the
    /// same size delete the only thing the animation is about.
    public func chain(at time: Double, range: Int) -> [(x: Double, y: Double)] {
        guard !frames.isEmpty, range > 0 else { return [] }
        let scale = Double(range)
        let position = max(0, time) * Self.framesPerSecond
        let lower = min(Int(position), frames.count - 1)
        let upper = min(lower + 1, frames.count - 1)
        let blend = min(max(position - Double(lower), 0), 1)
        let a = frames[lower].points
        let b = frames[upper].points
        let count = min(a.count, b.count) / 2
        return (0..<count).map { index in
            let ax = Double(a[index * 2]), ay = Double(a[index * 2 + 1])
            let bx = Double(b[index * 2]), by = Double(b[index * 2 + 1])
            return (x: (ax + (bx - ax) * blend) / scale,
                    y: (ay + (by - ay) * blend) / scale)
        }
    }

    /// The frame index at a moment, for anything that happens *on* a frame rather than between
    /// two: the contacts, and so the haptics.
    public func frameIndex(at time: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        return min(max(Int(max(0, time) * Self.framesPerSecond), 0), frames.count - 1)
    }
}
