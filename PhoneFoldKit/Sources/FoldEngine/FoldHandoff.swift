import Foundation

/// What one device tells another about the fold it is playing.
///
/// PLAN.md Phase 5a: "Handoff: start a fold on the phone, continue on the Mac."
///
/// **A description of what to fold, not the fold itself.** A trajectory is megabytes and
/// Handoff's payload is not the place for it; more importantly, the receiving device does not
/// want the phone's frames, it wants to run the same fold at its own resolution and residue
/// cap. Every field here is something the other end can act on: which protein, which engine,
/// which style, and how far through.
///
/// Deliberately not the fold's coordinates, and deliberately not a file reference either: the
/// Mac may not have the same bundled gallery version, so the gallery entry is named and looked
/// up rather than pointed at.
public struct FoldHandoff: Sendable, Equatable, Codable {

    /// The activity type both apps declare. Reverse-DNS, and it must appear in each app's
    /// `NSUserActivityTypes` or the other end never sees it.
    public static let activityType = "com.mdeller.phonefold.fold"

    /// Which protein. A gallery entry's identifier, or an accession that was fetched.
    public var subject: String
    /// The gallery entry's id, when the fold came from the bundled gallery. Nil for a fetched
    /// accession or a generated backbone.
    public var galleryID: String?
    /// A UniProt accession, when the fold was fetched. Nil otherwise.
    public var accession: String?
    public var engine: FoldingEngine
    public var styleID: String
    /// 0 to 1 through the piece, so the Mac can pick up where the phone was rather than
    /// starting again. Approximate by nature: the two devices fold at different speeds.
    public var progress: Double
    /// Genie 2's seed, so a generated backbone continues as the *same* backbone. Without it
    /// the Mac would generate a different protein and call it a continuation.
    public var seed: UInt64?

    public init(subject: String, galleryID: String? = nil, accession: String? = nil,
                engine: FoldingEngine, styleID: String, progress: Double,
                seed: UInt64? = nil) {
        self.subject = subject
        self.galleryID = galleryID
        self.accession = accession
        self.engine = engine
        self.styleID = styleID
        self.progress = progress
        self.seed = seed
    }

    // MARK: - The dictionary Handoff actually carries

    /// Keys for `NSUserActivity.userInfo`, which is a plist dictionary rather than anything
    /// typed. Spelled out so both ends agree, and so a rename in Swift cannot silently break
    /// the wire format between an old phone and a new Mac.
    enum Key {
        static let subject = "subject"
        static let galleryID = "galleryID"
        static let accession = "accession"
        static let engine = "engine"
        static let style = "style"
        static let progress = "progress"
        static let seed = "seed"
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            Key.subject: subject,
            Key.engine: engine.rawValue,
            Key.style: styleID,
            Key.progress: progress,
        ]
        if let galleryID { info[Key.galleryID] = galleryID }
        if let accession { info[Key.accession] = accession }
        // As a string: `NSUserActivity`'s dictionary is plist-encoded and a `UInt64` above
        // `Int64.max` does not survive the trip. Seeds are incremented freely by the app.
        if let seed { info[Key.seed] = String(seed) }
        return info
    }

    /// Read a payload back, returning nil rather than a half-filled one.
    ///
    /// **Nil rather than defaults.** A continuation that silently substitutes the default
    /// engine because the field was missing does not continue anything: it starts something
    /// else on the other machine and looks like it worked.
    public static func from(userInfo: [AnyHashable: Any]?) -> FoldHandoff? {
        guard let userInfo,
              let subject = userInfo[Key.subject] as? String,
              let engineRaw = userInfo[Key.engine] as? String,
              let engine = FoldingEngine(rawValue: engineRaw),
              let style = userInfo[Key.style] as? String,
              let progress = userInfo[Key.progress] as? Double
        else { return nil }
        return FoldHandoff(
            subject: subject,
            galleryID: userInfo[Key.galleryID] as? String,
            accession: userInfo[Key.accession] as? String,
            engine: engine,
            styleID: style,
            progress: progress,
            seed: (userInfo[Key.seed] as? String).flatMap(UInt64.init))
    }

    /// What the other device should show while it decides whether to accept.
    public var title: String { "Fold \(subject)" }
}
