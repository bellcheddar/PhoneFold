import Foundation
import simd
import FoldCore

/// A contact formation, rendered as a short-lived emissive line between the two residues
/// with a particle burst at its midpoint.
///
/// PLAN.md Phase 2 calls this "the visual that sells the fold is happening", and it is the
/// only element whose timing is driven by events rather than by the frame clock.
///
/// Endpoints are stored as **residue indices, not positions**. A flash lasts up to a second,
/// and in that time the residues move; drawing a line between where they were is the
/// difference between a bond snapping into place and a stray streak in space.
public struct ContactFlash: Sendable, Equatable {
    public let i: Int
    public let j: Int
    public let range: ContactRange
    public let isHydrophobicPair: Bool
    /// Output frame on which the contact formed.
    public let birthFrame: Int

    public init(event: ContactEvent, birthFrame: Int) {
        self.i = event.i
        self.j = event.j
        self.range = event.range
        self.isHydrophobicPair = event.isHydrophobicPair
        self.birthFrame = birthFrame
    }

    /// How long this flash lives, in seconds.
    ///
    /// Long-range contacts linger, because they are the ones that matter: a long-range
    /// hydrophobic contact is core packing, and PLAN.md maps it to a bass note and a haptic
    /// transient. The eye should have time to find it.
    public var lifetime: Float {
        let base: Float
        switch range {
        case .local: base = 0.35
        case .medium: base = 0.55
        case .longRange: base = 0.95
        }
        return isHydrophobicPair ? base * 1.25 : base
    }

    /// Peak brightness, before the envelope.
    public var peakIntensity: Float {
        let base: Float
        switch range {
        case .local: base = 0.55
        case .medium: base = 0.78
        case .longRange: base = 1.0
        }
        return Swift.min(1.0, isHydrophobicPair ? base + 0.15 : base)
    }

    /// Envelope at a given age: a fast attack then an exponential decay.
    ///
    /// Not a linear fade: a linear tail reads as a dimming line rather than a flash, and the
    /// attack has to be short enough that the onset lands with the note.
    public func intensity(age: Float) -> Float {
        guard age >= 0, age < lifetime else { return 0 }
        let attack: Float = 0.035
        if age < attack {
            // Floored at a quarter brightness rather than starting from zero: the contact
            // forms *on* this frame and the note plays with it, so there must be something
            // to see immediately. A literal zero makes the flash invisible on its own birth
            // frame, which reads as the spark lagging the sound.
            return peakIntensity * Swift.max(age / attack, 0.25)
        }
        let decayProgress = (age - attack) / Swift.max(lifetime - attack, 1e-4)
        return peakIntensity * exp(-4.0 * decayProgress) * (1 - decayProgress)
    }

    /// Deterministic per-flash randomness for the particle burst.
    ///
    /// Seeded from the residue pair, so the same protein produces the same burst every time.
    /// PLAN.md requires the same protein to yield the same piece, and the visuals should not
    /// be the one thing that differs between runs.
    public var seed: UInt32 {
        var h: UInt32 = 2166136261
        for value in [UInt32(truncatingIfNeeded: i), UInt32(truncatingIfNeeded: j)] {
            h = (h ^ value) &* 16777619
        }
        return h
    }

    /// Number of particles in the burst, scaled by how much the contact matters.
    public var particleCount: Int {
        switch range {
        case .local: return isHydrophobicPair ? 8 : 5
        case .medium: return isHydrophobicPair ? 14 : 10
        case .longRange: return isHydrophobicPair ? 24 : 18
        }
    }
}

/// One flash, resolved against the current frame's coordinates and ready to draw.
public struct FlashInstance: Sendable, Equatable {
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>
    public let midpoint: SIMD3<Float>
    public let intensity: Float
    public let colour: LinearRGB
    public let particleCount: Int
    public let seed: UInt32
}

/// Holds the live flashes and ages them out.
///
/// Bounded: beyond `capacity` the dimmest flashes are dropped rather than the newest, so a
/// burst of contact formation loses the ones already fading instead of the ones just fired.
/// Unlike frames, a dropped flash costs nothing but a little sparkle, and an unbounded pool
/// on a 300-residue fold would be thousands of emissive lines.
public struct ContactFlashPool: Sendable {
    public let capacity: Int
    public let frameRate: Float
    private var flashes: [ContactFlash] = []

    public init(capacity: Int = 160, frameRate: Float = 60) {
        self.capacity = Swift.max(1, capacity)
        self.frameRate = Swift.max(1, frameRate)
    }

    public var activeCount: Int { flashes.count }

    /// Record the contacts that formed on this frame.
    public mutating func add(_ events: [ContactEvent], atFrame frame: Int) {
        for event in events {
            flashes.append(ContactFlash(event: event, birthFrame: frame))
        }
        if flashes.count > capacity {
            // Keep the brightest. Sorting by current intensity would need the frame; birth
            // order plus peak is a good enough proxy and is stable.
            flashes.sort { ($0.peakIntensity, $0.birthFrame) > ($1.peakIntensity, $1.birthFrame) }
            flashes.removeLast(flashes.count - capacity)
        }
    }

    /// Retire flashes whose lifetime has elapsed.
    public mutating func advance(to frame: Int) {
        // frameRate is copied into a local: calling self.age(of:atFrame:) inside removeAll
        // reads self while the array is held exclusively for mutation.
        let rate = frameRate
        flashes.removeAll { flash in
            Float(frame - flash.birthFrame) / rate >= flash.lifetime
        }
    }

    func age(of flash: ContactFlash, atFrame frame: Int) -> Float {
        Float(frame - flash.birthFrame) / frameRate
    }

    /// Resolve the live flashes against this frame's coordinates.
    public func instances(atFrame frame: Int,
                          caPositions ca: [SIMD3<Float>]) -> [FlashInstance] {
        flashes.compactMap { flash in
            guard flash.i < ca.count, flash.j < ca.count else { return nil }
            let intensity = flash.intensity(age: age(of: flash, atFrame: frame))
            guard intensity > 0.001 else { return nil }
            let start = ca[flash.i]
            let end = ca[flash.j]
            return FlashInstance(
                start: start, end: end, midpoint: (start + end) * 0.5,
                intensity: intensity,
                colour: Self.colour(for: flash),
                particleCount: flash.particleCount,
                seed: flash.seed)
        }
    }

    /// Long-range hydrophobic contacts are core packing and read amber; everything else is
    /// the white contact flash from the Aurora Stage palette.
    static func colour(for flash: ContactFlash) -> LinearRGB {
        guard flash.range == .longRange, flash.isHydrophobicPair else {
            return Palette.contactFlash
        }
        return Colouring.mix(Palette.contactFlash, Palette.confidenceAmber, 0.6)
    }

    public mutating func reset() { flashes.removeAll() }
}
