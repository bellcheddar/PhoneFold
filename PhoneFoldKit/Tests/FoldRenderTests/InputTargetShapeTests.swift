import Testing
import simd
@testable import FoldRender

/// PLAN.md Phase 5c: "Hand interaction: pinch-drag to rotate, two-handed pinch to scale."
///
/// The pinch has to land on something. These are the rules for the box it lands on, kept
/// here because a headset cannot be put in a test suite and the policy can.
@Suite("The box a pinch has to hit")
struct InputTargetShapeTests {

    static func bounds(_ minimum: SIMD3<Float>, _ maximum: SIMD3<Float>)
        -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) { (minimum, maximum) }

    @Test("the first frame always builds a box")
    func firstFrameBuilds() {
        var shape = InputTargetShape()
        let built = shape.update(bounds: Self.bounds(SIMD3(-10, -10, -10), SIMD3(10, 10, 10)))
        #expect(built != nil)
        #expect(built?.size == SIMD3<Float>(20, 20, 20))
        #expect(built?.centre == SIMD3<Float>(0, 0, 0))
    }

    /// The point of the whole type: a fold changes shape sixty times a second and almost
    /// none of those changes need a new `ShapeResource`.
    @Test("an unchanged protein does not rebuild the box")
    func unchangedDoesNotRebuild() {
        var shape = InputTargetShape()
        let bounds = Self.bounds(SIMD3(-10, -10, -10), SIMD3(10, 10, 10))
        _ = shape.update(bounds: bounds)
        #expect(shape.update(bounds: bounds) == nil)
    }

    @Test("a frame-sized change does not rebuild the box")
    func smallChangeDoesNotRebuild() {
        var shape = InputTargetShape()
        _ = shape.update(bounds: Self.bounds(SIMD3(-10, -10, -10), SIMD3(10, 10, 10)))
        // Half an angstrom on one axis, against a 34.6 A diagonal: well inside the tolerance.
        #expect(shape.update(bounds: Self.bounds(SIMD3(-10, -10, -10),
                                                 SIMD3(10.5, 10, 10))) == nil)
    }

    /// And the change that matters: an extended chain collapsing into a folded core is a
    /// different object, and a box still sized for the extended chain would be pinchable
    /// far outside the protein.
    @Test("a fold collapsing rebuilds the box")
    func collapseRebuilds() {
        var shape = InputTargetShape()
        _ = shape.update(bounds: Self.bounds(SIMD3(-60, -10, -10), SIMD3(60, 10, 10)))
        let built = shape.update(bounds: Self.bounds(SIMD3(-14, -14, -14), SIMD3(14, 14, 14)))
        #expect(built != nil)
        #expect(built?.size == SIMD3<Float>(28, 28, 28))
    }

    /// A protein that has not changed size but has moved is still somewhere else, and a box
    /// left behind is a box the hand reaches through.
    @Test("a protein that only moves still rebuilds the box")
    func translationRebuilds() {
        var shape = InputTargetShape()
        _ = shape.update(bounds: Self.bounds(SIMD3(-10, -10, -10), SIMD3(10, 10, 10)))
        let built = shape.update(bounds: Self.bounds(SIMD3(20, -10, -10), SIMD3(40, 10, 10)))
        #expect(built != nil)
        #expect(built?.size == SIMD3<Float>(20, 20, 20), "the same size, in a new place")
        #expect(built?.centre == SIMD3<Float>(30, 0, 0))
    }

    /// The silent one. A degenerate box hit-tests against nothing, and a first frame with a
    /// single residue - or every CA on one line - is exactly how that happens. It looks
    /// identical to a gesture that was never connected.
    @Test("a flat or single-point structure still gets a box a hand can find")
    func degenerateBoundsArePadded() {
        var shape = InputTargetShape(minimumSize: 0.5)
        let point = shape.update(bounds: Self.bounds(SIMD3(3, 4, 5), SIMD3(3, 4, 5)))
        #expect(point?.size == SIMD3<Float>(0.5, 0.5, 0.5))
        #expect(point?.centre == SIMD3<Float>(3, 4, 5))

        var flat = InputTargetShape(minimumSize: 0.5)
        let plane = flat.update(bounds: Self.bounds(SIMD3(-8, -8, 0), SIMD3(8, 8, 0)))
        #expect(plane?.size == SIMD3<Float>(16, 16, 0.5), "thickened, not clamped square")
    }

    @Test("a bounds that is not a number builds nothing rather than a broken shape")
    func nonFiniteBoundsRefused() {
        var shape = InputTargetShape()
        #expect(shape.update(bounds: Self.bounds(SIMD3(0, 0, 0),
                                                 SIMD3(.nan, 1, 1))) == nil)
        #expect(shape.extent == nil)
    }

    @Test("changing protein invalidates the box")
    func invalidateRebuilds() {
        var shape = InputTargetShape()
        let bounds = Self.bounds(SIMD3(-10, -10, -10), SIMD3(10, 10, 10))
        _ = shape.update(bounds: bounds)
        shape.invalidate()
        #expect(shape.update(bounds: bounds) != nil)
    }
}
