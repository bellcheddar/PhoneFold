import Foundation
import simd
import FoldCore

/// The stage camera: a slow cinematic orbit that a drag overrides instantly.
///
/// Kept as a value type with no gesture or framework types, so the whole interaction model
/// is testable without a device. The app layer only translates gestures into calls.
///
/// PLAN.md Phase 2: interaction never blocks or delays the fold. Nothing here touches the
/// engine; the camera is a pure function of accumulated input and elapsed time.
public struct StageCamera: Sendable, Equatable {

    /// Rotation about the vertical axis, radians.
    public private(set) var yaw: Float = 0
    /// Elevation, radians. Clamped short of the poles.
    public private(set) var pitch: Float = 0.18
    /// Distance from the target, in stage units.
    public private(set) var distance: Float = 1.5
    /// What the camera looks at. Eased toward the action when following.
    public private(set) var target: SIMD3<Float> = .zero

    /// Radians per second of automatic orbit.
    public var autoOrbitRate: Float = 0.12
    /// Seconds of stillness after an interaction before the orbit resumes.
    public var resumeDelay: Float = 2.5

    public var minimumDistance: Float = 0.35
    public var maximumDistance: Float = 6.0
    /// Just short of vertical: at exactly +/- pi/2 the up vector is undefined and the view
    /// snaps through the pole.
    public static let pitchLimit: Float = .pi / 2 - 0.05

    private var idleTime: Float = 0
    private var isInteracting = false
    /// Distance at the start of the current pinch, so magnification is relative to where the
    /// gesture began rather than compounding every callback.
    private var pinchAnchor: Float?

    public init() {}

    /// Whether the automatic orbit is currently running.
    public var isOrbiting: Bool { !isInteracting && idleTime >= resumeDelay }

    // MARK: - Time

    public mutating func advance(deltaTime: Float) {
        guard deltaTime > 0 else { return }
        if isInteracting {
            idleTime = 0
            return
        }
        idleTime += deltaTime
        // Resume gently rather than snapping back to full speed the instant the finger lifts.
        guard idleTime >= resumeDelay else { return }
        let easeIn = Swift.min((idleTime - resumeDelay) / 1.5, 1)
        yaw += autoOrbitRate * deltaTime * easeIn
        yaw = yaw.truncatingRemainder(dividingBy: 2 * .pi)
    }

    // MARK: - Interaction

    /// A drag, in points, since the previous callback.
    public mutating func drag(deltaX: Float, deltaY: Float, sensitivity: Float = 0.006) {
        isInteracting = true
        idleTime = 0
        yaw += deltaX * sensitivity
        pitch = Swift.min(Swift.max(pitch + deltaY * sensitivity, -Self.pitchLimit),
                          Self.pitchLimit)
    }

    /// Pinch. `scale` is the gesture's cumulative magnification, 1 at the start.
    public mutating func magnify(scale: Float) {
        isInteracting = true
        idleTime = 0
        let anchor = pinchAnchor ?? distance
        pinchAnchor = anchor
        distance = Swift.min(Swift.max(anchor / Swift.max(scale, 0.01), minimumDistance),
                             maximumDistance)
    }

    public mutating func endInteraction() {
        isInteracting = false
        idleTime = 0
        pinchAnchor = nil
    }

    /// Two-finger pan, moving what the camera looks at rather than rotating it.
    public mutating func pan(deltaX: Float, deltaY: Float, sensitivity: Float = 0.0015) {
        isInteracting = true
        idleTime = 0
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let up = SIMD3<Float>(0, 1, 0)
        target += (right * -deltaX + up * deltaY) * sensitivity * distance
    }

    /// Double-tap: frame the whole structure and stop following.
    public mutating func reframe(bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?) {
        target = .zero
        pitch = 0.18
        distance = 1.5
        if let bounds {
            let extent = simd_length(bounds.maximum - bounds.minimum)
            // Fit the diagonal into the frame with a little room around it.
            distance = Swift.min(Swift.max(extent * 1.35, minimumDistance), maximumDistance)
            target = (bounds.maximum + bounds.minimum) * 0.5
        }
        endInteraction()
    }

    /// Ease the target toward where contacts are forming.
    ///
    /// Eased, not snapped: PLAN.md asks the camera to *follow* the action. Cutting to each
    /// new contact would be unwatchable, and a fold forms contacts several times a second.
    public mutating func followAction(midpoints: [SIMD3<Float>], easing: Float = 0.04) {
        guard !midpoints.isEmpty, !isInteracting else { return }
        var centroid = SIMD3<Float>.zero
        for point in midpoints { centroid += point }
        centroid /= Float(midpoints.count)
        target += (centroid - target) * Swift.min(Swift.max(easing, 0), 1)
    }

    // MARK: - Output

    /// Camera position in world space.
    public var position: SIMD3<Float> {
        let horizontal = distance * cos(pitch)
        return target + SIMD3<Float>(horizontal * sin(yaw),
                                     distance * sin(pitch),
                                     horizontal * cos(yaw))
    }

    /// Orientation looking at the target, with world up.
    public var orientation: simd_quatf {
        let forward = simd_normalize(target - position)
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(forward, worldUp)
        // Guarded because at the poles forward and up are parallel and the cross product
        // collapses. The pitch clamp makes this unreachable, but a NaN basis would spin the
        // view wildly rather than fail, so it is worth the two lines.
        if simd_length(right) < 1e-5 { right = SIMD3<Float>(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        let matrix = simd_float3x3(right, up, -forward)
        return simd_quatf(matrix)
    }
}
