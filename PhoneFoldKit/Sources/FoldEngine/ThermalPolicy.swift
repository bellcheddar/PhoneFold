import Foundation
import FoldGeometry

/// How the engine degrades under thermal pressure or low power mode.
///
/// PLAN.md Phase 1 is specific about the shape of this: **degrade by doing less work per
/// second, never by stuttering.** Dropping frames from a 60 fps stream to save power makes
/// the fold judder and breaks the trajectory's order. Lowering the output frame rate instead
/// produces fewer, evenly spaced frames, which reads as a slower fold rather than a broken
/// one, and the interpolator resamples cleanly because it is parameterised by a continuous
/// position rather than a frame index.
///
/// `ProcessInfo` supplies both signals on every platform PhoneFold targets, so this needs no
/// platform conditionals.
public struct ThermalPolicy: Sendable, Equatable {

    /// The state the engine is being asked to run under.
    public struct Conditions: Sendable, Equatable {
        public var thermalState: ProcessInfo.ThermalState
        public var lowPowerMode: Bool

        public init(thermalState: ProcessInfo.ThermalState = .nominal,
                    lowPowerMode: Bool = false) {
            self.thermalState = thermalState
            self.lowPowerMode = lowPowerMode
        }

        /// What the device reports right now.
        public static var current: Conditions {
            Conditions(thermalState: ProcessInfo.processInfo.thermalState,
                       lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    /// The result of applying a policy: what to run, and why.
    public struct Decision: Sendable, Equatable {
        public let frameRate: Float
        public let assigner: SecondaryStructureAssigner
        /// Human-readable, for the About panel and the debug overlay. PLAN.md asks for
        /// thermal state to be surfaced honestly rather than hidden.
        public let explanation: String
    }

    public var nominalFrameRate: Float

    public init(nominalFrameRate: Float = 60) {
        self.nominalFrameRate = nominalFrameRate
    }

    public func decide(_ conditions: Conditions) -> Decision {
        // Low power mode is the user's explicit request and is honoured even when cool.
        if conditions.lowPowerMode, conditions.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue {
            return Decision(frameRate: nominalFrameRate / 2, assigner: .learned,
                            explanation: "Low Power Mode: half frame rate")
        }
        switch conditions.thermalState {
        case .nominal:
            return Decision(frameRate: nominalFrameRate, assigner: .learned,
                            explanation: "Nominal")
        case .fair:
            return Decision(frameRate: nominalFrameRate, assigner: .learned,
                            explanation: "Fair: full rate")
        case .serious:
            return Decision(frameRate: nominalFrameRate / 2, assigner: .learned,
                            explanation: "Serious heat: half frame rate")
        case .critical:
            // P-SEA is arithmetic on a handful of distances; the learned assigner is a
            // 5,699-parameter forward pass per residue per frame. Under critical heat the
            // cheaper one is the right trade, and it is a real method rather than a stub.
            return Decision(frameRate: nominalFrameRate / 3, assigner: .pSEA,
                            explanation: "Critical heat: third frame rate, lighter assignment")
        @unknown default:
            return Decision(frameRate: nominalFrameRate / 2, assigner: .learned,
                            explanation: "Unrecognised thermal state: half frame rate")
        }
    }

    /// Apply a decision to a configuration, leaving everything else alone.
    public func applied(to configuration: FoldFrameSequence.Configuration,
                        under conditions: Conditions) -> FoldFrameSequence.Configuration {
        let decision = decide(conditions)
        var updated = configuration
        updated.frameRate = decision.frameRate
        updated.assigner = decision.assigner
        return updated
    }
}

extension FoldEngine {
    /// Re-evaluate the thermal policy and adjust the configuration.
    ///
    /// Takes conditions as a parameter rather than reading `ProcessInfo` directly so the
    /// behaviour is testable without heating the machine up.
    public func adapt(to conditions: ThermalPolicy.Conditions,
                      policy: ThermalPolicy = ThermalPolicy()) -> ThermalPolicy.Decision {
        let decision = policy.decide(conditions)
        var updated = configuration
        updated.frameRate = decision.frameRate
        updated.assigner = decision.assigner
        update(configuration: updated)
        return decision
    }
}
