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

    /// The subject's accumulated rotation, as a quaternion rather than yaw and pitch.
    ///
    /// It was yaw and pitch, with pitch clamped to +/-(pi/2 - 0.05) to protect the up
    /// vector of a camera orbit - and that clamp is what made a vertical drag die
    /// mid-gesture. From the resting pitch of 0.18 at 0.006 radians per point, the clamp
    /// was reached after **223 points of downward drag** (283 upward): one ordinary
    /// trackpad drag, after which vertical input did nothing while horizontal kept
    /// working. On the stage the protein is what rotates, against a fixed camera on +Z,
    /// and a quaternion on the subject has no pole to protect - so the protein now
    /// tumbles freely, like the object in the hand the drag is meant to be.
    ///
    /// Each drag increment is applied about the *screen* axes (premultiplied), which is
    /// what keeps "drag right turns right, drag down tips toward you" true in every
    /// orientation, including upside down. Composing on the other side would flip the
    /// horizontal direction whenever the protein is inverted.
    public private(set) var attitude = Self.restingAttitude
    /// Distance from the target, in stage units.
    public private(set) var distance: Float = 1.5
    /// What the camera looks at. Eased toward the action when following.
    public private(set) var target: SIMD3<Float> = .zero

    /// The framing tilt the stage opens with: slightly above, as a stage should be lit.
    public static let restingAttitude = simd_quatf(angle: 0.18,
                                                   axis: SIMD3<Float>(1, 0, 0))

    /// Radians per second of automatic orbit.
    public var autoOrbitRate: Float = 0.12
    /// Seconds of stillness after an interaction before the orbit resumes.
    ///
    /// Eight, not two and a half. PLAN.md wants the orbit instantly overridden by a drag, and
    /// it is - but resuming two and a half seconds after the finger lifts means a view you
    /// just set starts sliding away while you are still looking at it, which is
    /// something quite different from "cinematic". Long enough to read as deliberate.
    public var resumeDelay: Float = 8.0

    /// How close the camera may come.
    ///
    /// **0.8, not 0.35.** The stage normalises every protein so its bounding box measures
    /// 1.15 units across, which is a radius of about 0.575 - so a minimum of 0.35 let the
    /// camera sit *inside* the protein. Nothing culls a face here, so from in there you see
    /// the tube's interior or nothing at all, and the stage looks empty with no way to tell
    /// why. Pinch could always reach it in principle; scroll-to-zoom made it a flick of a
    /// finger. 0.8 clears the protein's own radius and the 0.05 near plane with room to spare.
    public var minimumDistance: Float = 0.8
    public var maximumDistance: Float = 6.0

    private var idleTime: Float = 0
    private var isInteracting = false
    /// Seconds since the last drag or pinch callback arrived.
    ///
    /// The interaction is ended by this, not only by `endInteraction`. SwiftUI's `onEnded`
    /// does not always run - a gesture pre-empted by the simultaneous magnify, or cancelled
    /// by the system, simply stops - and when it did not run the camera stayed in the
    /// interacting state for good: `advance` returns early there, so the orbit never came
    /// back and the stage sat still until the app was relaunched. That is what "the drag gets
    /// stuck" was.
    private var sinceLastInput: Float = 0
    /// How long without input before an interaction is treated as over.
    ///
    /// Two seconds, not a fraction of one. This is a backstop for a gesture whose end was
    /// never announced, and nothing else: a hand holding the protein still for a moment
    /// mid-drag is completely normal, and at 0.3 s the interaction was being ended out from
    /// under a finger that had not lifted. Long enough that only a genuinely abandoned
    /// gesture trips it.
    public var inputTimeout: Float = 2.0
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
            sinceLastInput += deltaTime
            guard sinceLastInput >= inputTimeout else {
                idleTime = 0
                return
            }
            // No input for a while: the gesture is over whether or not anyone said so.
            endInteraction()
        }
        idleTime += deltaTime
        // Resume gently rather than snapping back to full speed the instant the finger lifts.
        guard idleTime >= resumeDelay else { return }
        let easeIn = Swift.min((idleTime - resumeDelay) / 1.5, 1)
        rotate(aboutScreenX: 0, aboutScreenY: autoOrbitRate * deltaTime * easeIn)
    }

    // MARK: - Interaction

    /// The rotation to apply to the subject, so that dragging turns it like an object in
    /// the hand rather than like a camera flying around it.
    ///
    /// The stage orbits the *protein* against a fixed camera on +Z, so this is the rotation
    /// the protein carries. The signs are the whole of it, and they were the wrong way round
    /// once already: dragging right turned the protein left. They are hard to get right by
    /// reasoning at the call site and easy to check here, which is why the maths lives in
    /// the camera and not in the view.
    ///
    /// Dragging **right** turns the front of the protein toward the right of the screen.
    /// Dragging **down** brings its top toward the viewer.
    public var subjectRotation: simd_quatf { attitude }

    /// A drag, in points, since the previous callback.
    public mutating func drag(deltaX: Float, deltaY: Float, sensitivity: Float = 0.006) {
        isInteracting = true
        idleTime = 0
        sinceLastInput = 0
        rotate(aboutScreenX: deltaY * sensitivity, aboutScreenY: deltaX * sensitivity)
    }

    private mutating func rotate(aboutScreenX x: Float, aboutScreenY y: Float) {
        let turn = simd_quatf(angle: x, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: y, axis: SIMD3<Float>(0, 1, 0))
        attitude = simd_normalize(turn * attitude)
    }

    /// Pinch. `scale` is the gesture's cumulative magnification, 1 at the start.
    public mutating func magnify(scale: Float) {
        isInteracting = true
        idleTime = 0
        sinceLastInput = 0
        let anchor = pinchAnchor ?? distance
        pinchAnchor = anchor
        distance = Swift.min(Swift.max(anchor / Swift.max(scale, 0.01), minimumDistance),
                             maximumDistance)
    }

    /// Scroll-wheel zoom, for the Mac: PLAN.md's "Mac adds scroll-wheel zoom".
    ///
    /// `steps` is signed scroll input - positive zooms in - already scaled by the caller to
    /// taste. Exponential, so a step is the same *proportion* of the distance wherever the
    /// camera is, and clamped like the pinch. Scroll has no end event (momentum just stops
    /// arriving), so the interaction is left to the input timeout to close.
    public mutating func zoom(steps: Float) {
        guard steps != 0, steps.isFinite else { return }
        isInteracting = true
        idleTime = 0
        sinceLastInput = 0
        distance = Swift.min(Swift.max(distance * exp(-steps), minimumDistance),
                             maximumDistance)
    }

    public mutating func endInteraction() {
        isInteracting = false
        idleTime = 0
        sinceLastInput = 0
        pinchAnchor = nil
    }

    /// Two-finger pan, moving what the camera looks at rather than rotating it.
    public mutating func pan(deltaX: Float, deltaY: Float, sensitivity: Float = 0.0015) {
        isInteracting = true
        idleTime = 0
        sinceLastInput = 0
        // Screen axes carried into the subject's space, so a pan tracks the screen
        // whatever orientation the protein has been tumbled into.
        let right = attitude.inverse.act(SIMD3<Float>(1, 0, 0))
        let up = attitude.inverse.act(SIMD3<Float>(0, 1, 0))
        target += (right * -deltaX + up * deltaY) * sensitivity * distance
    }

    /// Double-tap: frame the whole structure and stop following.
    public mutating func reframe(bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?) {
        target = .zero
        attitude = Self.restingAttitude
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

    /// Camera position in the subject's space: the fixed eye on +Z, carried back through
    /// the subject's rotation.
    public var position: SIMD3<Float> {
        target + attitude.inverse.act(SIMD3<Float>(0, 0, distance))
    }

    /// Orientation looking at the target.
    ///
    /// The up vector comes from the attitude itself rather than from world up, because the
    /// protein can now be tumbled through the poles: at a pole, world up is parallel to the
    /// view axis and the basis would collapse, but the attitude's own up never is.
    public var orientation: simd_quatf {
        let forward = simd_normalize(target - position)
        var right = simd_cross(forward, attitude.inverse.act(SIMD3<Float>(0, 1, 0)))
        if simd_length(right) < 1e-5 { right = attitude.inverse.act(SIMD3<Float>(1, 0, 0)) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        let matrix = simd_float3x3(right, up, -forward)
        return simd_quatf(matrix)
    }
}
