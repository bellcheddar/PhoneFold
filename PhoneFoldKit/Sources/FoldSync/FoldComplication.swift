import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What a complication shows, and when it stops being worth showing.
///
/// PLAN.md Phase 5b: "Complication: current or last fold's mean pLDDT as a progress ring, tap to
/// open the remote." Its machine gate: "complication timeline entries generated correctly."
///
/// **A complication cannot ask, so the timeline has to say when it is out of date.** WidgetKit
/// renders from entries the app supplied earlier; nothing refreshes it while the wrist is down.
/// A fold finished at nine in the morning still on the watch face at six in the evening reads as
/// a fold happening now, and a progress ring is exactly the kind of thing a glance believes. So
/// the timeline is two entries: what is true now, and - at a stated moment - the same complication
/// saying it no longer knows.
public enum FoldComplication {

    /// How long a reading stays worth showing. Two hours: long enough that a fold watched over
    /// lunch is still on the face afterwards, short enough that nothing from this morning is
    /// still claiming to be live.
    public static let freshness: TimeInterval = 2 * 60 * 60

    public struct Entry: Sendable, Equatable {
        public let date: Date
        /// Nil once the reading has gone stale, which is what the second entry carries.
        public let title: String?
        public let progress: Double?
        public let meanConfidence: Double?
        public let confidenceLabel: String
        public let isPlaying: Bool

        public var isStale: Bool { title == nil }

        public init(date: Date, title: String?, progress: Double?, meanConfidence: Double?,
                    confidenceLabel: String = "pLDDT", isPlaying: Bool = false) {
            self.date = date
            self.title = title
            self.progress = progress
            self.meanConfidence = meanConfidence
            self.confidenceLabel = confidenceLabel
            self.isPlaying = isPlaying
        }

        /// What the ring fills to.
        ///
        /// **Confidence when the fold has finished, progress while it is running.** A ring that
        /// showed progress after the fold ended would sit permanently full and say nothing; a
        /// ring that showed confidence before there is any would start full and fall, which
        /// reads as the fold getting worse.
        public var ringFraction: Double {
            if isStale { return 0 }
            if isPlaying { return progress ?? 0 }
            if let meanConfidence { return min(max(meanConfidence / 100, 0), 1) }
            return progress ?? 0
        }

        /// The short text a circular complication has room for.
        public var shortText: String {
            if isStale { return "-" }
            if isPlaying { return "\(Int(((progress ?? 0) * 100).rounded()))%" }
            if let meanConfidence { return "\(Int(meanConfidence.rounded()))" }
            return "-"
        }

        /// What an inline complication says, which has room for a few words and no ring.
        public var inlineText: String {
            guard let title else { return "PhoneFold: no recent fold" }
            if isPlaying {
                return "\(title) \(Int(((progress ?? 0) * 100).rounded()))%"
            }
            if let meanConfidence {
                return "\(title) \(confidenceLabel) \(Int(meanConfidence.rounded()))"
            }
            return title
        }
    }

    /// Build the timeline from the last thing the phone said.
    ///
    /// Two entries, and the second is the point: it is the same complication admitting it has
    /// gone stale, scheduled for the moment that becomes true. Without it the face would show a
    /// morning's fold all day as though it were still happening.
    public static func timeline(from state: FoldRemote.State?, now: Date = Date(),
                                freshness: TimeInterval = freshness) -> [Entry] {
        guard let state else {
            return [Entry(date: now, title: nil, progress: nil, meanConfidence: nil)]
        }
        let live = Entry(date: now, title: state.title, progress: state.progress,
                         meanConfidence: state.meanConfidence,
                         confidenceLabel: state.confidenceLabel,
                         isPlaying: state.isPlaying)
        let stale = Entry(date: now.addingTimeInterval(freshness),
                          title: nil, progress: nil, meanConfidence: nil,
                          confidenceLabel: state.confidenceLabel)
        return [live, stale]
    }
}

/// Where the app leaves the last state for the complication to find.
///
/// **A shared app group, not a message.** The complication is a separate process that WidgetKit
/// wakes on its own schedule, long after the app that heard the state has been suspended. It
/// cannot be told anything; it has to be able to look.
///
/// In `FoldSync` rather than in the widget extension because both ends need it: the app writes
/// and the extension reads, and a copy in each would be two definitions of one file's layout.
public enum FoldComplicationStore {

    /// Must also be created in the developer portal and assigned to both identifiers by hand.
    /// The App Store Connect API has no app-group resource, and enabling the capability without
    /// assigning the group changes nothing while failing in exactly the same way.
    public static let suiteName = "group.com.mdeller.phonefold"
    private static let key = "lastState"

    public static func save(_ state: FoldRemote.State) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(state.payload, forKey: key)
        #if canImport(WidgetKit)
        // Ask for a redraw rather than waiting for the next scheduled one, so a fold started
        // now shows on the face now.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    public static func load() -> FoldRemote.State? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let payload = defaults.dictionary(forKey: key) else { return nil }
        return FoldRemote.State.from(payload: payload)
    }
}
