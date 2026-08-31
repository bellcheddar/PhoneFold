import Foundation
import simd

/// The box a pinch has to hit before the protein can be turned by hand.
///
/// PLAN.md Phase 5c: "Hand interaction: pinch-drag to rotate, two-handed pinch to scale."
///
/// **On visionOS a gesture attached to a `RealityView` reaches nothing unless the pinch ray
/// hits an entity carrying `InputTargetComponent` and a `CollisionComponent`.** That is the
/// whole difference between the phone and the headset: on the phone the drag lands on a view
/// and the view is always there, so `FoldCanvas`'s existing `DragGesture` works with no
/// collision geometry anywhere in the scene. Ported unchanged to visionOS it is not a weaker
/// gesture, it is *no* gesture - it never fires, and the protein simply cannot be turned.
///
/// The mesh changes shape every frame of a fold, so the box has to follow it. Rebuilding it
/// every frame would allocate a `ShapeResource` sixty times a second for a box that is
/// usually the same box, which is why this exists as a policy rather than as a line in the
/// render loop: it answers *when* the box is stale, and it is a value type so that answer is
/// testable without a headset.
public struct InputTargetShape: Sendable, Equatable {

    /// The extent the live shape was built for, or nil while there is no shape.
    public private(set) var extent: SIMD3<Float>?
    /// The centre the live shape was built for.
    public private(set) var centre: SIMD3<Float> = .zero

    /// How much the protein may change size before the box is rebuilt, as a fraction of the
    /// box's own diagonal. Five per cent: a fold's frame-to-frame change is far below it and
    /// the collapse from extended chain to folded core is far above.
    public var tolerance: Float

    /// The smallest box that can be pinched.
    ///
    /// **Never zero.** A `ShapeResource` box of zero size is degenerate and hit-tests against
    /// nothing, and the frame where that happens is not exotic: a trajectory's first frame can
    /// carry a single residue, or every atom on one line, and both give a zero extent along at
    /// least one axis. The failure is silent and looks exactly like a gesture that was never
    /// wired up.
    public var minimumSize: Float

    public init(tolerance: Float = 0.05, minimumSize: Float = 0.5) {
        self.tolerance = tolerance
        self.minimumSize = minimumSize
    }

    /// The box to build for these bounds, or nil if the one already built still fits.
    ///
    /// The box is returned in the protein's own space - unscaled, unrotated - because that is
    /// where the collision shape is attached: the entity's transform carries the framing scale
    /// and the orbit, and a shape built in stage units would be scaled a second time.
    public mutating func update(
        bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)
    ) -> (size: SIMD3<Float>, centre: SIMD3<Float>)? {
        let raw = bounds.maximum - bounds.minimum
        guard raw.x.isFinite, raw.y.isFinite, raw.z.isFinite else { return nil }
        // Padded outward rather than clamped per axis to a minimum, so a flat structure keeps
        // a box a hand can find from any side rather than a razor a pinch has to hit edge on.
        let size = SIMD3<Float>(Swift.max(raw.x, minimumSize),
                                Swift.max(raw.y, minimumSize),
                                Swift.max(raw.z, minimumSize))
        let middle = (bounds.maximum + bounds.minimum) * 0.5
        guard let extent else {
            self.extent = size
            self.centre = middle
            return (size, middle)
        }
        // Against the diagonal of the box already built, so the test means "this much of the
        // protein" on every axis rather than "this many angstroms", which would be a different
        // threshold for a 20-residue peptide and a 300-residue domain.
        let reference = Swift.max(simd_length(extent), minimumSize)
        let moved = simd_length(size - extent) + simd_length(middle - self.centre)
        guard moved > tolerance * reference else { return nil }
        self.extent = size
        self.centre = middle
        return (size, middle)
    }

    /// Forget the live shape, so the next frame rebuilds it. Called when the protein changes.
    public mutating func invalidate() {
        extent = nil
        centre = .zero
    }
}
