import Testing
@testable import FoldRender

/// PLAN.md Phase 5c: "Walk into the core: scale the protein up until you are standing inside it
/// as the hydrophobic core packs around you."
///
/// Whether that *feels* like anything is a headset question. Whether the protein is actually
/// big enough for it to be true is arithmetic over two measured fractions, and it is here.
@Suite("Standing inside a protein")
struct RoomScaleTests {

    /// The surprise in the measurements: at the stage's ordinary framing the structure's
    /// radius is already about half a metre, so a wearer at the centre of an immersive stage
    /// is at its surface before anything is scaled. Its core is not.
    @Test("as framed, you are at the surface and nowhere near the core")
    func framedScale() {
        let scale = RoomScale(multiplier: 1)
        #expect(abs(scale.widthInMetres - 1.15) < 1e-5)
        #expect(abs(scale.structureRadiusInMetres - 0.483) < 0.001)
        #expect(abs(scale.coreRadiusInMetres - 0.193) < 0.001)
        #expect(!scale.isInsideCore)
    }

    @Test("the walked-in scale actually puts the core around you")
    func walkedInIsInside() {
        let scale = RoomScale.walkedIn
        #expect(scale.isInsideCore)
        #expect(scale.isInsideStructure)
        // And it is the smallest such scale to within the tenth it is rounded to, rather than
        // an arbitrary big number: one notch below must not qualify.
        let smaller = RoomScale(multiplier: scale.multiplier - 0.1)
        #expect(!smaller.isInsideCore)
    }

    @Test("walking in is a few times bigger, not a hundred")
    func walkedInIsPlausible() {
        #expect(RoomScale.walkedIn.multiplier > 1)
        #expect(RoomScale.walkedIn.multiplier <= RoomScale.maximumMultiplier)
        // About two and a half metres of protein across the room.
        #expect(RoomScale.walkedIn.widthInMetres > 2)
        #expect(RoomScale.walkedIn.widthInMetres < 5)
    }

    @Test("the scale is clamped at both ends rather than trusted")
    func clamped() {
        #expect(RoomScale(multiplier: 0).multiplier == 1, "smaller than framed is not offered")
        #expect(RoomScale(multiplier: -8).multiplier == 1)
        #expect(RoomScale(multiplier: 500).multiplier == RoomScale.maximumMultiplier)
    }

    @Test("everything grows together and nothing overtakes anything")
    func monotonic() {
        var previous = RoomScale(multiplier: 1)
        for step in stride(from: Float(1.5), through: 6, by: 0.5) {
            let scale = RoomScale(multiplier: step)
            #expect(scale.widthInMetres > previous.widthInMetres)
            #expect(scale.coreRadiusInMetres > previous.coreRadiusInMetres)
            #expect(scale.coreRadiusInMetres < scale.structureRadiusInMetres,
                    "the core cannot be wider than the structure it is inside")
            previous = scale
        }
    }
}
