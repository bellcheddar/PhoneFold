import Foundation
import RealityKit
import simd

/// The lights the protein is lit by, on screen and in an export.
///
/// **One rig, built once, used by both.** PLAN.md's Phase 4 gate is that "exported video and
/// live playback are audibly and visually identical", and the live view was relying on
/// `RealityView`'s implicit default environment while the offscreen renderer - which gets no
/// environment at all - had to light itself. Two different lightings cannot produce one
/// picture. Marc chose to unify on explicit lights on 2026-08-31.
///
/// A key and a fill from opposite sides, so a swept tube reads as round rather than as a flat
/// silhouette. The fill is cool and weak: it lifts the shadow side enough to keep the far edge
/// of a helix visible without flattening the form the key is there to describe.
public enum StageLighting {

    /// Lux. Bright enough to read against the near-black indigo stage.
    public static let keyIntensity: Float = 12_000
    public static let fillIntensity: Float = 4_000

    /// Where the lights sit, looking at the origin. The protein is centred there in both paths.
    public static let keyPosition = SIMD3<Float>(3, 5, 4)
    public static let fillPosition = SIMD3<Float>(-4, -2, -3)

    /// The fill's colour: a cool blue, so the shadow side reads as shadow rather than as a
    /// second key from the other side.
    public static let fillColour = SIMD3<Float>(0.55, 0.62, 0.95)

    /// Two entities, ready to be added to a scene.
    ///
    /// Returned rather than added, because the live path adds them to a `RealityViewContent`
    /// and the offscreen one appends them to a `RealityRenderer` - different containers for the
    /// same two lights.
    @MainActor
    public static func makeLights() -> [Entity] {
        let key = Entity()
        key.name = "phonefold-key"
        key.components.set(DirectionalLightComponent(color: .white, intensity: keyIntensity))
        key.look(at: .zero, from: keyPosition, relativeTo: nil)

        let fill = Entity()
        fill.name = "phonefold-fill"
        fill.components.set(DirectionalLightComponent(
            color: .init(red: CGFloat(fillColour.x), green: CGFloat(fillColour.y),
                         blue: CGFloat(fillColour.z), alpha: 1),
            intensity: fillIntensity))
        fill.look(at: .zero, from: fillPosition, relativeTo: nil)

        return [key, fill]
    }
}
