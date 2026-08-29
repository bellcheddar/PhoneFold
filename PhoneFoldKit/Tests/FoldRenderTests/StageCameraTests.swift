import Testing
import Foundation
import simd
@testable import FoldRender

/// The rotation between two attitudes, as an angle. Robust to the double cover: q and -q
/// are the same rotation, so the angle is folded into [0, pi].
private func turn(from a: simd_quatf, to b: simd_quatf) -> Float {
    let angle = (b * a.inverse).angle
    return Swift.min(angle, 2 * .pi - angle)
}

@Suite("Stage camera")
struct StageCameraTests {

    @Test("the automatic orbit runs, but only after the idle delay")
    func autoOrbit() {
        var camera = StageCamera()
        let start = camera.attitude
        // Timed against the camera's own delay rather than a number: the delay is a matter of
        // taste and has been changed, and a test that pins the taste fails for no reason.
        camera.advance(deltaTime: camera.resumeDelay * 0.4)
        #expect(turn(from: start, to: camera.attitude) < 1e-6,
                "the orbit should wait out the idle delay")
        camera.advance(deltaTime: camera.resumeDelay)
        camera.advance(deltaTime: 2.0)
        #expect(turn(from: start, to: camera.attitude) > 0, "the orbit should have resumed")
    }

    /// PLAN.md: the auto-orbit is "instantly overridden by drag".
    @Test("a drag takes over immediately and stops the orbit")
    func dragOverridesOrbit() {
        var camera = StageCamera()
        for _ in 0..<10 { camera.advance(deltaTime: camera.resumeDelay * 0.5) }
        #expect(camera.isOrbiting)

        let before = camera.attitude
        camera.drag(deltaX: 100, deltaY: 0)
        #expect(turn(from: before, to: camera.attitude) > 0,
                "the drag should have rotated the view")
        #expect(camera.isOrbiting == false, "the orbit must yield to the hand")

        // And it does not resume the moment the finger lifts.
        camera.endInteraction()
        let afterDrag = camera.attitude
        camera.advance(deltaTime: 0.5)
        #expect(turn(from: afterDrag, to: camera.attitude) < 1e-6,
                "the orbit resumed too eagerly")
    }

    /// Drags accumulate. An earlier version set the rotation from the gesture's total
    /// translation, which reset to zero on release and snapped the view back.
    @Test("drags accumulate rather than resetting between gestures")
    func dragsAccumulate() {
        var camera = StageCamera()
        let start = camera.attitude
        camera.drag(deltaX: 50, deltaY: 0)
        let first = turn(from: start, to: camera.attitude)
        camera.endInteraction()
        camera.drag(deltaX: 50, deltaY: 0)
        let total = turn(from: start, to: camera.attitude)
        #expect(total > first, "the second drag should build on the first")
        #expect(abs(total - 2 * first) < 1e-4)
    }

    /// The regression behind "the drag is stuck". Pitch used to be clamped to
    /// +/-(pi/2 - 0.05), which from the resting tilt of 0.18 at 0.006 rad/point was reached
    /// after 223 points of downward drag - one ordinary trackpad drag - after which vertical
    /// input did nothing at all while horizontal kept working. The protein is a subject
    /// rotation with no pole to protect, so a vertical drag must keep turning it forever.
    @Test("a vertical drag never saturates, however far it goes")
    func verticalDragNeverSaturates() {
        var camera = StageCamera()
        // 40 x 100 points = 24 radians: several full tumbles. Every step must keep
        // rotating by the full increment; the old clamp stopped after ~2 steps.
        for step in 0..<40 {
            let before = camera.attitude
            camera.drag(deltaX: 0, deltaY: 100)
            let advanced = turn(from: before, to: camera.attitude)
            #expect(abs(advanced - 0.6) < 1e-3,
                    "vertical drag saturated at step \(step): moved \(advanced) rad")
        }
    }

    /// Screen-space consistency: the drag directions must hold in every orientation,
    /// including upside down - the reason increments are premultiplied about screen axes.
    @Test("dragging right still turns right when the protein is upside down")
    func dragDirectionsSurviveInversion() {
        var camera = StageCamera()
        // Tumble the protein through half a turn vertically: upside down.
        camera.drag(deltaX: 0, deltaY: .pi / 0.006)
        // The material point currently facing the camera.
        let facing = camera.attitude.inverse.act(SIMD3<Float>(0, 0, 1))
        camera.drag(deltaX: 60, deltaY: 0)
        let moved = camera.subjectRotation.act(facing)
        #expect(moved.x > 0.05,
                "inverted, dragging right should still carry the front right, got \(moved)")
    }

    /// Magnification is relative to where the pinch began. Applying the cumulative scale on
    /// every callback compounds it and the view rockets in or out.
    @Test("pinch is anchored to the start of the gesture")
    func pinchIsAnchored() {
        var camera = StageCamera()
        let start = camera.distance
        // Pinching *out*, so the result stays clear of the near limit: this test is about
        // anchoring, and letting it land on the clamp would make it assert the clamp instead.
        camera.magnify(scale: 0.5)
        let doubled = camera.distance
        #expect(abs(doubled - start * 2) < 1e-4)
        // The same cumulative scale reported again must not compound.
        camera.magnify(scale: 0.5)
        #expect(abs(camera.distance - doubled) < 1e-4, "the pinch compounded")
        camera.endInteraction()
    }

    @Test("distance stays within its limits")
    func distanceClamps() {
        var camera = StageCamera()
        camera.magnify(scale: 1000)
        #expect(camera.distance >= camera.minimumDistance)
        camera.endInteraction()
        camera.magnify(scale: 0.0001)
        #expect(camera.distance <= camera.maximumDistance)
    }

    /// PLAN.md: "Mac adds scroll-wheel zoom". Signed steps, clamped like the pinch.
    @Test("scroll zoom moves the distance the right way and clamps")
    func scrollZoom() {
        var camera = StageCamera()
        let start = camera.distance
        camera.zoom(steps: 0.2)
        #expect(camera.distance < start, "positive steps should zoom in")
        camera.zoom(steps: -0.4)
        #expect(camera.distance > start * 0.9, "negative steps should zoom out")
        for _ in 0..<100 { camera.zoom(steps: 1) }
        #expect(camera.distance >= camera.minimumDistance)
        for _ in 0..<100 { camera.zoom(steps: -1) }
        #expect(camera.distance <= camera.maximumDistance)
        // A zoom is an interaction: the orbit must yield to it like any other.
        #expect(camera.isOrbiting == false)
        // And junk input changes nothing.
        let held = camera.distance
        camera.zoom(steps: 0)
        camera.zoom(steps: .nan)
        #expect(camera.distance == held)
    }

    @Test("double-tap reframes to fit the structure")
    func reframe() {
        var camera = StageCamera()
        camera.drag(deltaX: 400, deltaY: 200)
        camera.magnify(scale: 4)
        camera.endInteraction()

        let bounds = (minimum: SIMD3<Float>(-1, -1, -1), maximum: SIMD3<Float>(1, 1, 1))
        camera.reframe(bounds: bounds)
        #expect(camera.target == .zero)
        #expect(camera.distance > camera.minimumDistance)
        #expect(camera.distance <= camera.maximumDistance)
        #expect(turn(from: camera.attitude, to: StageCamera.restingAttitude) < 1e-5,
                "reframe should restore the resting tilt")

        // An off-centre structure is centred, not just resized.
        camera.reframe(bounds: (minimum: SIMD3<Float>(9, 9, 9),
                                maximum: SIMD3<Float>(11, 11, 11)))
        #expect(simd_distance(camera.target, SIMD3<Float>(10, 10, 10)) < 1e-4)
        // No bounds at all is a safe default rather than a crash or a zero distance.
        camera.reframe(bounds: nil)
        #expect(camera.distance > 0)
    }

    /// Cutting to each new contact would be unwatchable; a fold forms several a second.
    @Test("follow-the-action eases toward the contacts rather than snapping")
    func followEases() {
        var camera = StageCamera()
        let action = [SIMD3<Float>(10, 0, 0), SIMD3<Float>(10, 2, 0)]
        camera.followAction(midpoints: action)
        let firstStep = camera.target
        #expect(firstStep.x > 0 && firstStep.x < 1, "it snapped instead of easing")

        for _ in 0..<400 { camera.followAction(midpoints: action) }
        #expect(abs(camera.target.x - 10) < 0.2, "it never arrived")
        #expect(abs(camera.target.y - 1) < 0.2, "it should track the centroid")
    }

    @Test("following yields to the hand and ignores an empty frame")
    func followYields() {
        var camera = StageCamera()
        camera.drag(deltaX: 10, deltaY: 0)
        let held = camera.target
        camera.followAction(midpoints: [SIMD3<Float>(50, 50, 50)])
        #expect(camera.target == held, "the camera moved while being dragged")

        camera.endInteraction()
        camera.followAction(midpoints: [])
        #expect(camera.target == held)
    }

    /// The camera must always look at what it is targeting, from its stated distance -
    /// at *any* attitude now that the protein tumbles freely, poles included.
    @Test("position and orientation are consistent for any pose")
    func poseIsConsistent() {
        var camera = StageCamera()
        for step in 0..<80 {
            camera.drag(deltaX: Float(step) * 13, deltaY: Float(step % 11) * 47 - 200)
            camera.endInteraction()
            camera.magnify(scale: 1 + Float(step % 5) * 0.3)
            camera.endInteraction()

            let offset = camera.position - camera.target
            #expect(abs(simd_length(offset) - camera.distance) < 1e-3,
                    "the camera is not at its stated distance")

            // The camera's forward axis must point at the target.
            let forward = camera.orientation.act(SIMD3<Float>(0, 0, -1))
            let toTarget = simd_normalize(camera.target - camera.position)
            #expect(simd_dot(forward, toTarget) > 0.999,
                    "the camera is not looking at its target")
        }
    }
}

/// Which way the protein turns when you drag it.
///
/// This was backwards in the shipped build - dragging right turned the protein left - and the
/// reason it survived is that it is easy to reason yourself into either sign and impossible
/// to see in a screenshot. Asserting where a known point lands settles it.
@Suite("Drag direction")
struct DragDirectionTests {

    /// A point on the front of the protein, facing the camera on +Z.
    static let front = SIMD3<Float>(0, 0, 1)
    /// A point on top of it.
    static let top = SIMD3<Float>(0, 1, 0)

    @Test("Dragging right carries the front of the protein to the right")
    func draggingRightTurnsRight() {
        var camera = StageCamera()
        camera.drag(deltaX: 60, deltaY: 0)
        let moved = camera.subjectRotation.act(Self.front)
        #expect(moved.x > 0.05, "the front should swing toward +x, got \(moved)")
    }

    @Test("Dragging left carries it to the left")
    func draggingLeftTurnsLeft() {
        var camera = StageCamera()
        camera.drag(deltaX: -60, deltaY: 0)
        #expect(camera.subjectRotation.act(Self.front).x < -0.05)
    }

    @Test("Dragging down brings the top of the protein toward the viewer")
    func draggingDownTipsTowardTheViewer() {
        var camera = StageCamera()
        camera.drag(deltaX: 0, deltaY: 60)
        let moved = camera.subjectRotation.act(Self.top)
        #expect(moved.z > 0.05, "the top should swing toward the camera on +z, got \(moved)")
    }

    /// The camera starts at a framing angle rather than dead-on, so "at rest" is not the
    /// identity. What must hold is that a drag of nothing changes nothing.
    @Test("A drag of nothing changes nothing")
    func zeroDragChangesNothing() {
        var camera = StageCamera()
        let before = camera.subjectRotation.act(Self.front)
        camera.drag(deltaX: 0, deltaY: 0)
        #expect(simd_distance(camera.subjectRotation.act(Self.front), before) < 1e-6)
    }
}

/// The stage must not be left frozen by a gesture that never announced its end.
@Suite("Stalled interactions")
struct StalledInteractionTests {

    /// SwiftUI's `onEnded` does not always run. When it did not, `isInteracting` stayed true
    /// for the life of the app, `advance` returned early every tick, and the orbit never came
    /// back: the stage was stuck. Ending the interaction on a timeout makes the camera
    /// recover on its own rather than depending on a callback that may not arrive.
    @Test("A drag with no ending still lets the orbit resume")
    func orbitResumesWithoutAnOnEnded() {
        var camera = StageCamera()
        camera.drag(deltaX: 20, deltaY: 0)          // and no endInteraction, ever
        // Long enough to pass the input timeout, the resume delay and the ease-in.
        let before = camera.attitude
        let ticks = Int((camera.inputTimeout + camera.resumeDelay + 3) * 60)
        for _ in 0..<ticks { camera.advance(deltaTime: 1.0 / 60) }
        #expect(camera.isOrbiting, "the camera never came back from the drag")
        #expect(camera.attitude != before, "the orbit is not actually turning")
    }

    @Test("A drag that keeps arriving is not timed out from under the finger")
    func continuousDragIsNotInterrupted() {
        var camera = StageCamera()
        for _ in 0..<120 {
            camera.drag(deltaX: 1, deltaY: 0)
            camera.advance(deltaTime: 1.0 / 60)
            #expect(!camera.isOrbiting, "the orbit fought the drag")
        }
    }

    @Test("An explicit end is still respected immediately")
    func explicitEndStillWorks() {
        var camera = StageCamera()
        camera.drag(deltaX: 10, deltaY: 0)
        camera.endInteraction()
        for _ in 0..<Int(camera.resumeDelay * 120) { camera.advance(deltaTime: 1.0 / 60) }
        #expect(camera.isOrbiting)
    }
}

/// The camera must not be able to get inside the protein.
///
/// The stage normalises every protein to a bounding box of 1.15 units - radius about 0.575 -
/// and the minimum distance used to be 0.35. Zooming all the way in put the camera inside the
/// mesh, and since nothing culls a face here that shows as an empty stage with no explanation.
/// Pinch could reach it; scroll-to-zoom made it easy.
@Suite("Zoom limits")
struct ZoomLimitTests {

    /// What `applyProteinTransform` normalises to, and half of it.
    static let normalisedExtent: Float = 1.15
    static let proteinRadius = normalisedExtent / 2

    @Test("Zooming all the way in leaves the camera outside the protein")
    func closestApproachClearsTheProtein() {
        var camera = StageCamera()
        for _ in 0..<200 { camera.zoom(steps: 1) }        // hard against the stop
        #expect(camera.distance > Self.proteinRadius,
                "the camera reached \(camera.distance), inside a protein of radius \(Self.proteinRadius)")
        // And clear of the near plane too, or the front of the protein clips away.
        #expect(camera.distance > Self.proteinRadius + 0.05)
    }

    @Test("Zooming all the way out keeps the protein on screen")
    func furthestStillShowsSomething() {
        var camera = StageCamera()
        for _ in 0..<200 { camera.zoom(steps: -1) }
        // At a 42 degree field of view the protein must still subtend a usable angle.
        let subtended = 2 * atan(Self.proteinRadius / camera.distance) * 180 / Float.pi
        #expect(subtended > 5, "the protein subtends only \(subtended) degrees when zoomed out")
    }

    @Test("A pinch cannot get inside either")
    func pinchRespectsTheSameFloor() {
        var camera = StageCamera()
        camera.magnify(scale: 100)
        #expect(camera.distance > Self.proteinRadius)
    }
}
