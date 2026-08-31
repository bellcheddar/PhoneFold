import Foundation
import simd

/// Where the sound of a residue is, relative to the listener's head.
///
/// PLAN.md Phase 3 put each note at its residue's live coordinate through
/// `AVAudioEnvironmentNode`; Phase 5c asks for that sound to be "placed where the residues
/// are", which on a headset is a different sentence. On a phone the protein is behind glass and
/// the listener is nowhere in particular, so the design that works is the protein wrapped around
/// the head: the fold collapses around you. In a volume on a desk the protein has a *place* -
/// you can see it, an arm's length away and slightly below eye level - and audio arriving from
/// inside your own skull for something you are looking at over there is not immersive, it is
/// wrong in a way that is hard to name and impossible to ignore.
///
/// So the placement is a configuration rather than a constant, and this is it.
///
/// **The default is exactly the behaviour that has been listened to**: centred on the head, no
/// rotation, angstroms over `angstromsPerMetre`. Nothing changes on any surface that does not
/// ask, because none of this can be heard from this machine and a change nobody can hear is not
/// a change anybody should make blind.
public struct SpatialStage: Sendable, Equatable {

    /// Where the protein's centre sits relative to the listener, in metres.
    public var centre: SIMD3<Float>
    /// How many angstroms of protein span one metre of the listener's world.
    public var angstromsPerMetre: Float
    /// The rotation the stage is showing the protein at.
    ///
    /// Identity everywhere the picture and the listener are not in the same space. In a volume
    /// they are: a residue drawn on the left of the object in front of you has to sound on the
    /// left, and it stops being on the left the moment the stage is turned.
    public var attitude: simd_quatf

    public init(centre: SIMD3<Float> = .zero,
                angstromsPerMetre: Float = 20,
                attitude: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))) {
        self.centre = centre
        self.angstromsPerMetre = angstromsPerMetre
        self.attitude = attitude
    }

    /// The protein around the listener: the Phase 3 design, and the phone's.
    public static func aroundTheListener(angstromsPerMetre: Float) -> SpatialStage {
        SpatialStage(centre: .zero, angstromsPerMetre: angstromsPerMetre)
    }

    /// The protein in a volume: a place in the room, turning with the stage.
    ///
    /// `distance` is how far in front of the listener the volume sits, in metres, negative z
    /// because that is the direction `AVAudioEnvironmentNode` calls forward. `span` is how wide
    /// the protein looks, in metres, and `proteinExtent` how wide it really is, in angstroms.
    ///
    /// Scaled from the protein's own size rather than from a constant, so a 20-residue peptide
    /// and a 300-residue domain both fill the volume - which is what the stage does to the
    /// picture, and the sound has to agree with the picture or the two are describing different
    /// objects.
    public static func inAVolume(distance: Float, span: Float,
                                 proteinExtent: Float,
                                 attitude: simd_quatf) -> SpatialStage {
        let extent = Swift.max(proteinExtent, 0.001)
        return SpatialStage(centre: SIMD3<Float>(0, 0, -distance),
                            angstromsPerMetre: extent / Swift.max(span, 0.001),
                            attitude: attitude)
    }

    /// Where this coordinate sounds from.
    ///
    /// `origin` is the protein's own centre in mesh space - the coordinates are angstroms about
    /// wherever the structure happens to sit, which for a fetched structure is not the origin
    /// and can be hundreds of angstroms away.
    public func place(_ coordinate: SIMD3<Float>, origin: SIMD3<Float> = .zero) -> SIMD3<Float> {
        let scale = Swift.max(angstromsPerMetre, 0.001)
        return attitude.act((coordinate - origin) / scale) + centre
    }
}
