import Foundation

/// What the Watch and the phone say to each other.
///
/// PLAN.md Phase 5b: "Transport remote over `WatchConnectivity`: play, pause, scrub, switch
/// style, switch colour mode." And its machine gate: "connectivity handshake unit-tested with a
/// **mock session**".
///
/// **That gate is a constraint on the design, not a note about testing.** `WCSession` cannot be
/// constructed in a unit test - it is a singleton owned by the system and it refuses to activate
/// off a real device pairing - so if the code talks to it directly the handshake can never be
/// tested and the gate can never be met. The transport is therefore a protocol from the first
/// line, `WCSession` is one conformance, and a mock is another.
public enum FoldRemote {

    /// A command from the wrist to the phone. The Watch runs no inference and asks for nothing
    /// that would require any: every case here is a transport or presentation change.
    public enum Command: Sendable, Equatable, Codable {
        case play
        case pause
        /// 0 to 1 through the piece. The Digital Crown sends a stream of these.
        case scrub(Double)
        case style(String)
        case colourMode(String)
        /// Start the fold the gallery entry names, so the wrist can pick the protein.
        case fold(galleryID: String)

        /// The wire form. A dictionary rather than `Codable`'s data, because
        /// `WCSession.sendMessage` takes a property-list dictionary and round-tripping JSON
        /// through it would be encoding twice.
        public var payload: [String: Any] {
            switch self {
            case .play: ["command": "play"]
            case .pause: ["command": "pause"]
            case .scrub(let value): ["command": "scrub", "value": value]
            case .style(let id): ["command": "style", "id": id]
            case .colourMode(let mode): ["command": "colourMode", "id": mode]
            case .fold(let id): ["command": "fold", "id": id]
            }
        }

        /// **Nil for anything unrecognised, never a default.** A Watch newer than the phone will
        /// send commands the phone has no case for, and the phone silently treating an unknown
        /// command as `play` is worse than ignoring it.
        public static func from(payload: [String: Any]) -> Command? {
            guard let command = payload["command"] as? String else { return nil }
            switch command {
            case "play": return .play
            case "pause": return .pause
            case "scrub":
                guard let value = payload["value"] as? Double else { return nil }
                // Clamped rather than rejected: the Crown can overshoot at the ends, and
                // refusing the message would make the timeline stick instead of stopping.
                return .scrub(Swift.min(Swift.max(value, 0), 1))
            case "style":
                guard let id = payload["id"] as? String else { return nil }
                return .style(id)
            case "colourMode":
                guard let id = payload["id"] as? String else { return nil }
                return .colourMode(id)
            case "fold":
                guard let id = payload["id"] as? String else { return nil }
                return .fold(galleryID: id)
            default: return nil
            }
        }
    }

    /// What the phone tells the wrist about the fold it is playing.
    ///
    /// Sent as **application context** rather than as messages: context is coalesced by the
    /// system and only the latest survives, which is exactly right for a state snapshot that
    /// changes sixty times a second. Queuing every update as a message would fill the transfer
    /// queue and deliver a backlog of stale states minutes later.
    public struct State: Sendable, Equatable {
        public var title: String
        public var isPlaying: Bool
        public var progress: Double
        public var meanConfidence: Double?
        public var confidenceLabel: String
        public var styleID: String
        public var colourMode: String
        /// The choices the phone can actually offer, as identifier and display name.
        ///
        /// **Sent rather than known.** The Watch runs no audio and draws no protein, so it has
        /// no business depending on `FoldAudio` or `FoldRender` just to learn five style names -
        /// that would put a synthesiser and a renderer on a device whose whole design principle
        /// is that it runs no inference. Hard-coding the list instead would drift the moment a
        /// style is added. The phone knows; the phone says. They ride in the application
        /// context, which the system coalesces, so repeating them costs nothing.
        public var styles: [String: String]
        public var colourModes: [String: String]

        public init(title: String, isPlaying: Bool, progress: Double,
                    meanConfidence: Double? = nil, confidenceLabel: String = "pLDDT",
                    styleID: String = "fantasy", colourMode: String = "secondaryStructure",
                    styles: [String: String] = [:], colourModes: [String: String] = [:]) {
            self.title = title
            self.isPlaying = isPlaying
            self.progress = progress
            self.meanConfidence = meanConfidence
            self.confidenceLabel = confidenceLabel
            self.styleID = styleID
            self.colourMode = colourMode
            self.styles = styles
            self.colourModes = colourModes
        }

        public var payload: [String: Any] {
            var info: [String: Any] = [
                "title": title,
                "isPlaying": isPlaying,
                "progress": progress,
                "confidenceLabel": confidenceLabel,
                "styleID": styleID,
                "colourMode": colourMode,
                "styles": styles,
                "colourModes": colourModes,
            ]
            if let meanConfidence { info["meanConfidence"] = meanConfidence }
            return info
        }

        public static func from(payload: [String: Any]) -> State? {
            guard let title = payload["title"] as? String,
                  let isPlaying = payload["isPlaying"] as? Bool,
                  let progress = payload["progress"] as? Double else { return nil }
            return State(
                title: title, isPlaying: isPlaying, progress: progress,
                meanConfidence: payload["meanConfidence"] as? Double,
                confidenceLabel: payload["confidenceLabel"] as? String ?? "pLDDT",
                styleID: payload["styleID"] as? String ?? "fantasy",
                colourMode: payload["colourMode"] as? String ?? "secondaryStructure",
                styles: payload["styles"] as? [String: String] ?? [:],
                colourModes: payload["colourModes"] as? [String: String] ?? [:])
        }
    }

    /// The link between the two devices, so neither side has to know it is `WCSession`.
    public protocol Transport: AnyObject, Sendable {
        /// Whether the other device is there right now. A remote that cannot say so shows a
        /// transport that silently does nothing.
        var isReachable: Bool { get }
        func send(_ command: Command)
        func update(_ state: State)
    }

    /// What a side of the link does with what arrives.
    public protocol Receiver: AnyObject, Sendable {
        func received(_ command: Command)
        func received(_ state: State)
    }
}
