import Foundation

/// Which half of a run is being reported to the outside world.
///
/// Folding and playback are genuinely different things to report: while the model runs there is
/// no structure to have confidence in yet, and while the piece plays there is no computation
/// left to make progress on.
public enum FoldActivityPhase: String, Sendable, Codable, Hashable, CaseIterable {
    case fetching
    case folding
    case playing

    public var verb: String {
        switch self {
        case .fetching: "Fetching"
        case .folding: "Folding"
        case .playing: "Playing"
        }
    }
}

/// What a fold looks like from outside the app: the Live Activity's state, and the Watch's.
///
/// PLAN.md Phase 4: "Live Activity and Dynamic Island: progress, current recycle, mean pLDDT."
///
/// **Plain data, here rather than beside the ActivityKit code.** Two reasons, and the second is
/// the one that matters. ActivityKit does not exist on macOS, and PhoneFold is one target for
/// both platforms, so a state type declared inside a platform conditional takes every function
/// that mentions it out of the macOS build too. And a rule about *when* to publish an update is
/// a rule, testable on its own - which it is not if it lives in an app target with no tests.
public struct FoldActivitySnapshot: Sendable, Codable, Hashable {
    public var phase: FoldActivityPhase
    /// 0 to 1.
    public var progress: Double
    /// Which recycle of the trunk the current frame came from, when there is one. A
    /// structure-based fold has a single recycle and reports nil rather than "recycle 1",
    /// which would be a number that never changes taking up a line on the Lock Screen.
    public var recycle: Int?
    /// Mean confidence of the current frame, on the 0-100 scale, once there is a frame.
    public var meanConfidence: Double?
    /// What that confidence is - pLDDT, or something else for an engine that is not predicting.
    /// Carried rather than assumed, for the same reason it is carried everywhere else here.
    public var confidenceLabel: String

    public init(phase: FoldActivityPhase, progress: Double, recycle: Int? = nil,
                meanConfidence: Double? = nil, confidenceLabel: String = "pLDDT") {
        self.phase = phase
        self.progress = progress
        self.recycle = recycle
        self.meanConfidence = meanConfidence
        self.confidenceLabel = confidenceLabel
    }

    /// One percent. Below this a banner is being redrawn for a change nobody can see.
    public static let progressStep = 0.01

    /// Whether this is worth publishing, given what was published last.
    ///
    /// **Rate-limited because ActivityKit is.** Playback publishes a frame sixty times a second
    /// and the system budgets Live Activity updates far below that; pushing every frame gets
    /// updates dropped and the banner freezes at whatever got through.
    ///
    /// A phase change always goes out, however small the progress step: going from folding to
    /// playing at the same fraction is the most informative update in the whole run, and a rule
    /// that only watched progress would swallow it.
    public func isWorthPublishing(after previous: FoldActivitySnapshot?) -> Bool {
        guard let previous else { return true }
        if phase != previous.phase { return true }
        return abs(progress - previous.progress) >= Self.progressStep
    }
}
