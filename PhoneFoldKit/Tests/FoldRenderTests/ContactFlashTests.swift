import Testing
import Foundation
import simd
import FoldCore
import FoldGeometry
@testable import FoldRender

@Suite("Contact flashes")
struct ContactFlashTests {

    static func event(_ i: Int, _ j: Int, hydrophobic: Bool = false) -> ContactEvent {
        ContactEvent(i: i, j: j, distance: 7.2, isHydrophobicPair: hydrophobic)
    }

    static func chain(_ n: Int) -> [SIMD3<Float>] {
        (0..<n).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
    }

    /// The envelope is what makes it read as a flash rather than a dimming line: fast attack,
    /// exponential decay, zero at both ends.
    @Test("the envelope rises fast, decays, and reaches exactly zero")
    func envelope() {
        let flash = ContactFlash(event: Self.event(0, 30), birthFrame: 0)
        #expect(flash.intensity(age: -0.1) == 0, "no light before it forms")
        // Visible immediately on the frame it forms: the note plays on that frame too.
        #expect(flash.intensity(age: 0) > 0, "a flash must be visible on its birth frame")
        #expect(flash.intensity(age: 0) < flash.peakIntensity)
        #expect(flash.intensity(age: flash.lifetime) == 0, "must end at exactly zero")
        #expect(flash.intensity(age: flash.lifetime * 2) == 0)

        // Peak lands at the end of the attack.
        let peak = flash.intensity(age: 0.035)
        #expect(abs(peak - flash.peakIntensity) < 1e-4)
        #expect(flash.intensity(age: 0.01) < peak, "still rising during the attack")

        // Monotone decay after the peak.
        var previous = peak
        for step in 1...40 {
            let age = 0.035 + (flash.lifetime - 0.035) * Float(step) / 40
            let value = flash.intensity(age: age)
            #expect(value <= previous + 1e-6, "the decay went back up at age \(age)")
            previous = value
        }
    }

    /// Long-range contacts are the musically and structurally interesting ones, so they
    /// linger and burn brighter.
    @Test("long-range contacts last longer and flash brighter than local ones")
    func longRangeDominates() {
        let local = ContactFlash(event: Self.event(0, 4), birthFrame: 0)
        let medium = ContactFlash(event: Self.event(0, 8), birthFrame: 0)
        let long = ContactFlash(event: Self.event(0, 40), birthFrame: 0)
        #expect(local.range == .local && medium.range == .medium && long.range == .longRange)
        #expect(long.lifetime > medium.lifetime && medium.lifetime > local.lifetime)
        #expect(long.peakIntensity > medium.peakIntensity)
        #expect(medium.peakIntensity > local.peakIntensity)
        #expect(long.particleCount > local.particleCount)
    }

    @Test("a hydrophobic pair burns brighter and longer than the same-range polar one")
    func hydrophobicEmphasis() {
        let polar = ContactFlash(event: Self.event(0, 40), birthFrame: 0)
        let core = ContactFlash(event: Self.event(0, 40, hydrophobic: true), birthFrame: 0)
        #expect(core.lifetime > polar.lifetime)
        #expect(core.peakIntensity >= polar.peakIntensity)
        #expect(core.particleCount > polar.particleCount)
        // Intensity never exceeds full, however the emphases stack.
        #expect(core.peakIntensity <= 1.0)
    }

    /// A long-range hydrophobic contact is core packing, and reads amber rather than white.
    @Test("core packing is coloured differently from an ordinary contact")
    func coreColour() {
        let ordinary = ContactFlash(event: Self.event(0, 40), birthFrame: 0)
        let core = ContactFlash(event: Self.event(0, 40, hydrophobic: true), birthFrame: 0)
        #expect(ContactFlashPool.colour(for: ordinary) == Palette.contactFlash)
        #expect(ContactFlashPool.colour(for: core) != Palette.contactFlash)
        // A local hydrophobic pair is not core packing and stays white.
        let localCore = ContactFlash(event: Self.event(0, 4, hydrophobic: true), birthFrame: 0)
        #expect(ContactFlashPool.colour(for: localCore) == Palette.contactFlash)
    }

    /// The whole reason endpoints are residue indices: a flash outlives the positions it was
    /// born at, and drawing where the residues *were* leaves a streak in empty space.
    @Test("flash endpoints follow the residues as they move")
    func endpointsTrackResidues() {
        var pool = ContactFlashPool(frameRate: 60)
        pool.add([Self.event(0, 30)], atFrame: 0)

        let atBirth = pool.instances(atFrame: 0, caPositions: Self.chain(40))
        #expect(atBirth.count == 1)

        // Move every residue a long way and re-resolve the same flash.
        let moved = Self.chain(40).map { $0 + SIMD3<Float>(0, 100, 0) }
        let later = pool.instances(atFrame: 10, caPositions: moved)
        #expect(later.count == 1)
        #expect(later[0].start.y == 100, "endpoint did not follow its residue")
        #expect(abs(later[0].midpoint.y - 100) < 1e-4)
    }

    @Test("flashes retire once their lifetime elapses")
    func retirement() {
        var pool = ContactFlashPool(frameRate: 60)
        pool.add([Self.event(0, 4)], atFrame: 0)          // local: 0.35 s = 21 frames
        #expect(pool.activeCount == 1)
        pool.advance(to: 10)
        #expect(pool.activeCount == 1, "should still be alive at 0.17 s")
        pool.advance(to: 40)
        #expect(pool.activeCount == 0, "should have retired by 0.67 s")
        #expect(pool.instances(atFrame: 40, caPositions: Self.chain(10)).isEmpty)
    }

    /// An unbounded pool on a 300-residue fold would be thousands of emissive lines.
    @Test("the pool is bounded and keeps the brightest")
    func capacity() {
        var pool = ContactFlashPool(capacity: 10, frameRate: 60)
        // Fire many local contacts, then some long-range ones.
        pool.add((0..<30).map { Self.event($0, $0 + 4) }, atFrame: 0)
        pool.add((0..<5).map { Self.event($0, $0 + 40) }, atFrame: 0)
        #expect(pool.activeCount == 10)
        // Sampled past the attack, so the survivors are at full brightness rather than
        // partway up the onset ramp.
        let instances = pool.instances(atFrame: 3, caPositions: Self.chain(100))
        // The long-range ones, being brightest, must have survived the cull.
        #expect(instances.contains { $0.intensity > 0.5 },
                "the cull dropped the brightest flashes")
    }

    /// PLAN.md requires the same protein to yield the same piece; the visuals should not be
    /// the one thing that differs between runs.
    @Test("particle seeds are deterministic and vary between pairs")
    func deterministicSeeds() {
        let a = ContactFlash(event: Self.event(3, 40), birthFrame: 0)
        let b = ContactFlash(event: Self.event(3, 40), birthFrame: 99)
        let c = ContactFlash(event: Self.event(4, 40), birthFrame: 0)
        #expect(a.seed == b.seed, "the same pair must always seed the same burst")
        #expect(a.seed != c.seed, "different pairs should not share a burst")

        var seeds = Set<UInt32>()
        for i in 0..<40 { seeds.insert(ContactFlash(event: Self.event(i, i + 20),
                                                    birthFrame: 0).seed) }
        #expect(seeds.count > 35, "seeds are colliding badly: \(seeds.count) of 40")
    }

    @Test("a flash whose residues no longer exist is dropped, not resolved out of range")
    func handlesShrinkingChain() {
        var pool = ContactFlashPool(frameRate: 60)
        pool.add([Self.event(0, 90)], atFrame: 0)
        #expect(pool.instances(atFrame: 1, caPositions: Self.chain(10)).isEmpty)
    }

    /// End to end against a real fold: contacts form, flash, and clear.
    @Test("a real trajectory produces flashes that all expire")
    func realTrajectory() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/genie2_76aa_seed1.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        var tracker = ContactTracker()
        var pool = ContactFlashPool(frameRate: 12)
        var peak = 0
        for (frame, readout) in bundle.readouts.enumerated() {
            let events = tracker.update(caPositions: readout.caPositions,
                                        residues: bundle.residues)
            pool.add(events, atFrame: frame)
            pool.advance(to: frame)
            let live = pool.instances(atFrame: frame, caPositions: readout.caPositions)
            peak = max(peak, live.count)
            #expect(live.allSatisfy { $0.intensity > 0 && $0.intensity <= 1.001 })
            #expect(live.allSatisfy {
                $0.start.x.isFinite && $0.midpoint.y.isFinite && $0.colour.min() >= 0
            })
        }
        #expect(peak > 0, "a real fold should light up at some point")
        // Long after the last frame, everything must have cleared.
        pool.advance(to: bundle.readouts.count + 1000)
        #expect(pool.activeCount == 0)
    }
}
