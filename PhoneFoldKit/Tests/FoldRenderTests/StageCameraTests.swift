import Testing
import Foundation
import simd
@testable import FoldRender

@Suite("Stage camera")
struct StageCameraTests {

    @Test("the automatic orbit runs, but only after the idle delay")
    func autoOrbit() {
        var camera = StageCamera()
        let start = camera.yaw
        // Before the resume delay elapses, nothing moves.
        camera.advance(deltaTime: 1.0)
        #expect(camera.yaw == start, "the orbit should wait out the idle delay")
        camera.advance(deltaTime: 2.0)
        camera.advance(deltaTime: 1.0)
        #expect(camera.yaw > start, "the orbit should have resumed")
    }

    /// PLAN.md: the auto-orbit is "instantly overridden by drag".
    @Test("a drag takes over immediately and stops the orbit")
    func dragOverridesOrbit() {
        var camera = StageCamera()
        for _ in 0..<10 { camera.advance(deltaTime: 0.5) }
        #expect(camera.isOrbiting)

        let before = camera.yaw
        camera.drag(deltaX: 100, deltaY: 0)
        #expect(camera.yaw > before, "the drag should have rotated the view")
        #expect(camera.isOrbiting == false, "the orbit must yield to the hand")

        // And it does not resume the moment the finger lifts.
        camera.endInteraction()
        let afterDrag = camera.yaw
        camera.advance(deltaTime: 0.5)
        #expect(camera.yaw == afterDrag, "the orbit resumed too eagerly")
    }

    /// Drags accumulate. An earlier version set the rotation from the gesture's total
    /// translation, which reset to zero on release and snapped the view back.
    @Test("drags accumulate rather than resetting between gestures")
    func dragsAccumulate() {
        var camera = StageCamera()
        camera.drag(deltaX: 50, deltaY: 0)
        let first = camera.yaw
        camera.endInteraction()
        camera.drag(deltaX: 50, deltaY: 0)
        #expect(camera.yaw > first, "the second drag should build on the first")
        #expect(abs(camera.yaw - 2 * first) < 1e-5)
    }

    /// At exactly vertical the up vector is undefined and the view flips through the pole.
    @Test("pitch clamps short of vertical, however hard it is dragged")
    func pitchClamps() {
        var camera = StageCamera()
        for _ in 0..<200 { camera.drag(deltaX: 0, deltaY: 500) }
        #expect(camera.pitch <= StageCamera.pitchLimit)
        for _ in 0..<400 { camera.drag(deltaX: 0, deltaY: -500) }
        #expect(camera.pitch >= -StageCamera.pitchLimit)
        // And the orientation stays finite at the limit.
        let q = camera.orientation
        #expect(q.vector.x.isFinite && q.vector.y.isFinite
                && q.vector.z.isFinite && q.vector.w.isFinite)
    }

    /// Magnification is relative to where the pinch began. Applying the cumulative scale on
    /// every callback compounds it and the view rockets in or out.
    @Test("pinch is anchored to the start of the gesture")
    func pinchIsAnchored() {
        var camera = StageCamera()
        let start = camera.distance
        camera.magnify(scale: 2)
        let halfway = camera.distance
        #expect(abs(halfway - start / 2) < 1e-4)
        // The same cumulative scale reported again must not compound.
        camera.magnify(scale: 2)
        #expect(abs(camera.distance - halfway) < 1e-4, "the pinch compounded")
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

    /// The camera must always look at what it is targeting, from its stated distance.
    @Test("position and orientation are consistent for any pose")
    func poseIsConsistent() {
        var camera = StageCamera()
        for step in 0..<40 {
            camera.drag(deltaX: Float(step) * 13, deltaY: Float(step % 7) * 11 - 33)
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
        // Long enough to pass the input timeout and the resume delay and the ease-in.
        let before = camera.yaw
        for _ in 0..<600 { camera.advance(deltaTime: 1.0 / 60) }
        #expect(camera.isOrbiting, "the camera never came back from the drag")
        #expect(camera.yaw != before, "the orbit is not actually turning")
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
        for _ in 0..<400 { camera.advance(deltaTime: 1.0 / 60) }
        #expect(camera.isOrbiting)
    }
}
