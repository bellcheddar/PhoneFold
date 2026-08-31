import Foundation

/// How big the protein is in the room, and what it takes to be standing inside it.
///
/// PLAN.md Phase 5c: "**Walk into the core**: scale the protein up until you are standing
/// inside it as the hydrophobic core packs around you. Absurd, memorable, and scientifically
/// legible."
///
/// **"Scientifically legible" is the part that needs a number rather than a feeling.** How far
/// the protein has to be scaled before someone is inside its *core*, rather than merely inside
/// its bounding box, depends on how deep a hydrophobic core actually is - and that is
/// measurable rather than arguable. Both constants below were measured on the ten bundled
/// structures of fifty residues or more; see METRICS.md, P5c-07.
///
/// A value type in `FoldRender` so the arithmetic is testable without a headset, which is the
/// only place any of it can be *judged*.
public struct RoomScale: Sendable, Equatable {

    /// What the stage normalises every protein's bounding-box diagonal to.
    ///
    /// The single definition of a number that was written twice in `FoldCanvas` and once in
    /// a comment about the depth buffer.
    public static let framedExtent: Float = 1.15

    /// The furthest alpha carbon from the centroid, as a fraction of the bounding-box
    /// diagonal. **Measured: median 0.42 over ten structures, range 0.37 to 0.51.** Tight,
    /// because a folded protein is roughly globular whatever it is made of.
    public static let radiusOverDiagonal: Float = 0.42

    /// How far the hydrophobic core reaches, as a fraction of the structure's own radius.
    ///
    /// **Measured: median 0.40, mean 0.41, range 0.0 to 0.6.** Binned by distance from the
    /// centroid, the mean Kyte-Doolittle hydropathy is strongly positive at the centre and
    /// negative at the surface, and this is where it crosses. The 0.0 is proinsulin, which is
    /// a disulphide-linked precursor rather than a globular domain and has no core in this
    /// sense - a real answer rather than a failure of the measurement.
    public static let coreFraction: Float = 0.40

    /// The room a standing person needs around them, in metres.
    ///
    /// Half a metre: enough to stand and turn without the structure passing through you. This
    /// one is a stated choice, not a measurement - it is about a body, not about a protein -
    /// and it is the number most likely to change once someone has actually stood in one.
    public static let personalRadius: Float = 0.5

    /// 1 is the protein as the stage frames it. Larger is closer to being inside it.
    public var multiplier: Float

    /// The largest scale offered. Beyond about this the near clip plane and the wearer's own
    /// comfort become the limit rather than anything about the protein.
    public static let maximumMultiplier: Float = 6

    public init(multiplier: Float = 1) {
        self.multiplier = Swift.min(Swift.max(multiplier, 1), Self.maximumMultiplier)
    }

    /// The protein's bounding-box diagonal, in metres.
    public var widthInMetres: Float { Self.framedExtent * multiplier }

    /// How far the structure reaches from its centre, in metres.
    public var structureRadiusInMetres: Float { widthInMetres * Self.radiusOverDiagonal }

    /// How far the hydrophobic core reaches, in metres.
    public var coreRadiusInMetres: Float { structureRadiusInMetres * Self.coreFraction }

    /// Whether a person standing at the centre is inside the structure at all.
    public var isInsideStructure: Bool { structureRadiusInMetres >= Self.personalRadius }

    /// Whether they are inside the *core*, which is the thing PLAN actually asks for.
    public var isInsideCore: Bool { coreRadiusInMetres >= Self.personalRadius }

    /// The smallest scale at which the core has closed around a person.
    ///
    /// Derived, not chosen: it falls out of the two measured fractions and the half-metre.
    /// At the stage's ordinary framing the structure's radius is already about 0.48 m, so a
    /// wearer standing at the centre of an immersive stage is at its surface before anything
    /// is scaled at all - but its *core* is only 0.19 m across, which is a grapefruit held at
    /// arm's length rather than a room.
    public static var walkedIn: RoomScale {
        let needed = personalRadius / (framedExtent * radiusOverDiagonal * coreFraction)
        return RoomScale(multiplier: (needed * 10).rounded(.up) / 10)
    }
}
