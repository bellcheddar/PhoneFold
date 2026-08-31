import Testing
import simd
@testable import FoldAudio

/// PLAN.md Phase 5c: in the concert hall, "spatial audio finally does what the Phase 3 design
/// always intended: notes arrive from where their residues actually are."
///
/// Nothing on this machine can hear any of it, so what is tested is the arithmetic that decides
/// where a note is - and above all that the default has not moved, because the default is the
/// thing that has actually been listened to.
@Suite("Where a note sounds from")
struct SpatialStageTests {

    static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    /// The one that matters most: this exists to let visionOS place the sound somewhere else,
    /// and it must not have moved the sound on the four surfaces where it was already right.
    @Test("the default is the Phase 3 placement, unchanged")
    func defaultIsUnchanged() {
        let stage = SpatialStage()
        let residue = SIMD3<Float>(20, 0, -40)
        let placed = stage.place(residue)
        // 20 angstroms to the metre, listener at the origin, no rotation.
        #expect(abs(placed.x - 1) < 1e-6)
        #expect(abs(placed.y - 0) < 1e-6)
        #expect(abs(placed.z + 2) < 1e-6)
    }

    @Test("a residue at the centre of the protein sounds from the protein's place")
    func centreOfTheProtein() {
        let stage = SpatialStage(centre: SIMD3<Float>(0, -0.2, -1.2))
        let placed = stage.place(.zero)
        #expect(placed == SIMD3<Float>(0, -0.2, -1.2))
    }

    /// The gap this closes. The stage turns the protein and, before this, the sound stayed
    /// put: a residue you can see on your left arrived from wherever it started.
    @Test("turning the stage turns the sound with it")
    func attitudeCarriesTheSound() {
        let quarterTurn = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let stage = SpatialStage(angstromsPerMetre: 20, attitude: quarterTurn)
        // A residue 20 A to the right, which is one metre right unrotated.
        let placed = stage.place(SIMD3<Float>(20, 0, 0))
        // A quarter turn about +y takes +x to -z: in front of the listener.
        #expect(abs(placed.x) < 1e-6)
        #expect(abs(placed.z + 1) < 1e-6)
    }

    /// The protein's own coordinates are angstroms about wherever the structure happens to sit.
    /// The bundled trajectories are centred to within 5 A of the origin and AlphaFold's models
    /// to within 3, so this is a guard rather than a fix - but a structure that is not centred
    /// would otherwise put the whole piece off to one side, as one point source.
    @Test("an off-centre structure is placed about its own centre")
    func originIsSubtracted() {
        let stage = SpatialStage()
        let far = SIMD3<Float>(120, 100, 100)
        let placed = stage.place(far + SIMD3<Float>(20, 0, 0), origin: far)
        #expect(abs(placed.x - 1) < 1e-6)
        #expect(abs(placed.y) < 1e-6)
    }

    @Test("a volume fills with the protein whatever size the protein is")
    func volumeScalesToTheProtein() {
        // A 30 A peptide and a 300 A domain, both asked to look 0.5 m across.
        let small = SpatialStage.inAVolume(distance: 1, span: 0.5, proteinExtent: 30,
                                           attitude: Self.identity)
        let large = SpatialStage.inAVolume(distance: 1, span: 0.5, proteinExtent: 300,
                                           attitude: Self.identity)
        // Each protein's own edge lands in the same place, which is what "fills the volume"
        // means and what the picture already does.
        let smallEdge = small.place(SIMD3<Float>(30, 0, 0))
        let largeEdge = large.place(SIMD3<Float>(300, 0, 0))
        #expect(abs(smallEdge.x - largeEdge.x) < 1e-5)
        #expect(abs(smallEdge.z + 1) < 1e-6, "and both sit where the volume is")
    }

    @Test("a zero scale cannot divide the sound to infinity")
    func degenerateScale() {
        let stage = SpatialStage(angstromsPerMetre: 0)
        let placed = stage.place(SIMD3<Float>(1, 0, 0))
        #expect(placed.x.isFinite)
    }

    @Test("a volume asked for a zero-wide protein is still finite")
    func degenerateVolume() {
        let stage = SpatialStage.inAVolume(distance: 1, span: 0, proteinExtent: 0,
                                           attitude: Self.identity)
        let placed = stage.place(SIMD3<Float>(10, 0, 0))
        #expect(placed.x.isFinite && placed.z.isFinite)
    }

    /// The engine's own path, rather than the value type alone: a note that names no residue
    /// the frame has - a chain shorter than the score thinks - must land at the protein rather
    /// than at the listener's feet, or a volume on a desk sings from inside your head.
    @Test("a note with no coordinates lands at the protein, not at the origin")
    func missingCoordinates() {
        let stage = SpatialStage(centre: SIMD3<Float>(0, 0, -1.5))
        let note = NoteEvent(voice: .contact, note: MIDINote(pitch: 60, velocity: 90),
                             residue: 999)
        let placed = FoldAudioEngine.position(of: note, in: [], stage: stage)
        #expect(placed == SIMD3<Float>(0, 0, -1.5))
    }
}
