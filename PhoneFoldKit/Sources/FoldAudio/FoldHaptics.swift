import Foundation
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Plays a `HapticScore` on hardware that has an actuator.
///
/// **Everything about whether this can run is asked, never assumed.** `CoreHaptics` imports on
/// every platform PhoneFold ships to, including ones with no actuator at all, so the header
/// being there proves nothing: a Mac and a simulator both compile this and neither can buzz.
/// `supportsHaptics` is the only honest test, and when it says no this does nothing and says so
/// rather than failing on the first event.
public final class FoldHaptics: @unchecked Sendable {

    public enum Availability: Sendable, Equatable {
        case ready
        /// The hardware has no actuator: a Mac, a simulator, an older device.
        case noHardware
        case failed(String)

        public var isReady: Bool { self == .ready }
    }

    public private(set) var availability: Availability = .noHardware
    /// Events asked for while the engine was not running, so a silent run is visible as a
    /// number rather than as an absence.
    public private(set) var skipped = 0

    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    #endif

    public init() {}

    /// Whether this device can produce haptics at all.
    public static var isSupported: Bool {
        #if canImport(CoreHaptics)
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        false
        #endif
    }

    public func start() {
        #if canImport(CoreHaptics)
        guard Self.isSupported else {
            availability = .noHardware
            return
        }
        do {
            let engine = try CHHapticEngine()
            // The system stops the engine when the app goes to the background, on a phone call,
            // and for reasons it does not enumerate. Without these the first such event leaves
            // a silently dead engine that never buzzes again and never says why.
            engine.stoppedHandler = { [weak self] _ in self?.availability = .noHardware }
            engine.resetHandler = { [weak self] in
                do { try self?.engine?.start() } catch {
                    self?.availability = .failed(error.localizedDescription)
                }
            }
            // Nothing is playing between bars, so letting it idle out and restart on demand
            // costs a few milliseconds of latency and saves the actuator being held awake for
            // a two-minute fold.
            engine.playsHapticsOnly = true
            try engine.start()
            self.engine = engine
            availability = .ready
        } catch {
            availability = .failed(error.localizedDescription)
        }
        #else
        availability = .noHardware
        #endif
    }

    public func stop() {
        #if canImport(CoreHaptics)
        engine?.stop()
        engine = nil
        #endif
        availability = .noHardware
    }

    /// Play one moment's worth of feeling, `beatDuration` seconds to the beat.
    public func play(_ events: [HapticEvent], beatDuration: Double) {
        guard !events.isEmpty else { return }
        #if canImport(CoreHaptics)
        guard availability.isReady, let engine else {
            skipped += events.count
            return
        }
        do {
            let pattern = try CHHapticPattern(events: events.map {
                Self.hapticEvent($0, beatDuration: beatDuration)
            }, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // A pattern that will not play is not worth taking the run down for: the music is
            // the point and the haptics are the accompaniment.
            skipped += events.count
            availability = .failed(error.localizedDescription)
        }
        #else
        skipped += events.count
        #endif
    }

    #if canImport(CoreHaptics)
    static func hapticEvent(_ event: HapticEvent, beatDuration: Double) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity,
                                   value: Float(event.intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness,
                                   value: Float(event.sharpness)),
        ]
        let time = event.beatOffset * beatDuration
        switch event.kind {
        case .transient:
            return CHHapticEvent(eventType: .hapticTransient, parameters: parameters,
                                 relativeTime: time)
        case .rumble, .convergence:
            return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters,
                                 relativeTime: time,
                                 duration: Swift.max(event.duration * beatDuration, 0.05))
        }
    }
    #endif
}
