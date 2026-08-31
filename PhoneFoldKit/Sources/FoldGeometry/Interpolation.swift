import Foundation
import simd

/// Smooths a trajectory's raw model readouts into a 60 fps stream.
///
/// A trajectory arrives as a few hundred readouts at best, and PLAN.md Phase 2 asks for
/// 60 fps with nothing popping. The interpolation happens here, in the platform-clean core,
/// so the renderer and the score consume the same frames.
///
/// **Superpose before interpolating.** Two consecutive readouts can describe the same
/// structure in different orientations, and interpolating between them without alignment
/// drags every atom through the middle of the molecule. `align` does that; the initialiser
/// does it for you.
public struct TrajectoryInterpolator: Sendable {

    /// CA positions per raw readout, already superposed onto their predecessor.
    public let alignedFrames: [[SIMD3<Float>]]
    public var rawFrameCount: Int { alignedFrames.count }
    public var residueCount: Int { alignedFrames.first?.count ?? 0 }

    /// Align a sequence of raw readouts, each onto the one before it, so the molecule stops
    /// tumbling. A frame that fails to superpose keeps its predecessor's orientation rather
    /// than being dropped: the order of a trajectory is the trajectory.
    public static func align(_ frames: [[SIMD3<Float>]]) -> [[SIMD3<Float>]] {
        guard var previous = frames.first else { return [] }
        var out: [[SIMD3<Float>]] = [previous]
        out.reserveCapacity(frames.count)
        for frame in frames.dropFirst() {
            if let fit = Kabsch.superpose(mobile: frame, onto: previous) {
                let aligned = fit.apply(frame)
                out.append(aligned)
                previous = aligned
            } else {
                out.append(frame)
                previous = frame
            }
        }
        return out
    }

    public init(rawFrames: [[SIMD3<Float>]], alreadyAligned: Bool = false) {
        self.alignedFrames = alreadyAligned ? rawFrames : Self.align(rawFrames)
    }

    /// Positions at a continuous position along the trajectory, where whole numbers land
    /// exactly on raw readouts.
    ///
    /// Catmull-Rom in time, which passes through every control point: a raw readout is a
    /// real model output and must be shown as it is, not smoothed away. Ends are clamped by
    /// duplicating the terminal frame, so the trajectory neither overshoots nor stalls.
    public func positions(at u: Float) -> [SIMD3<Float>] {
        guard !alignedFrames.isEmpty else { return [] }
        guard alignedFrames.count > 1 else { return alignedFrames[0] }

        let clamped = min(max(u, 0), Float(alignedFrames.count - 1))
        let i = min(Int(clamped.rounded(.down)), alignedFrames.count - 2)
        let t = clamped - Float(i)

        let p0 = alignedFrames[max(i - 1, 0)]
        let p1 = alignedFrames[i]
        let p2 = alignedFrames[i + 1]
        let p3 = alignedFrames[min(i + 2, alignedFrames.count - 1)]

        var out = [SIMD3<Float>]()
        out.reserveCapacity(p1.count)
        for k in p1.indices {
            out.append(Self.catmullRom(p0[k], p1[k], p2[k], p3[k], t))
        }
        return out
    }

    /// The uniform Catmull-Rom spline point at `t` in 0...1 between `p1` and `p2`.
    @inlinable
    public static func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
                                  _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                                  _ t: Float) -> SIMD3<Float> {
        // Written as explicit steps: as one expression the Swift type checker gives up.
        let t2: Float = t * t
        let t3: Float = t2 * t
        let a: SIMD3<Float> = p1 * 2
        let b: SIMD3<Float> = (p2 - p0) * t
        let c0: SIMD3<Float> = p0 * 2
        let c1: SIMD3<Float> = p1 * 5
        let c2: SIMD3<Float> = p2 * 4
        let c: SIMD3<Float> = (c0 - c1 + c2 - p3) * t2
        let d0: SIMD3<Float> = p1 * 3
        let d1: SIMD3<Float> = p2 * 3
        let d: SIMD3<Float> = (d0 - d1 + p3 - p0) * t3
        let sum: SIMD3<Float> = a + b + c + d
        return sum * 0.5
    }

    /// How many output frames a trajectory should produce at a given frame rate and speed.
    ///
    /// `secondsPerRawFrame` is the playback pacing, not anything the model did: raw readouts
    /// have no wall-clock meaning of their own.
    public func outputFrameCount(frameRate: Float = 60, secondsPerRawFrame: Float) -> Int {
        guard rawFrameCount > 1, frameRate > 0, secondsPerRawFrame > 0 else {
            return max(rawFrameCount, 1)
        }
        let seconds = Float(rawFrameCount - 1) * secondsPerRawFrame
        return Int((seconds * frameRate).rounded()) + 1
    }

    /// The continuous trajectory position for output frame `index`.
    public func parameter(forOutputFrame index: Int, outOf total: Int) -> Float {
        guard total > 1 else { return 0 }
        return Float(index) / Float(total - 1) * Float(rawFrameCount - 1)
    }

    /// Whether an output frame lands exactly on a raw readout.
    ///
    /// **Not the way to enumerate readouts.** This is an exactness test, and it is only true
    /// when the output frame rate is an integer multiple of the readout rate. Pacing the
    /// animation from the score makes it 145.5 frames per readout, at which this is true for
    /// 2 readouts in 8. `FoldFrameSequence` marks a frame raw when it is the first one nearest
    /// a readout, which holds at any ratio; this remains for callers that genuinely want to
    /// know whether a parameter is on a readout.
    public func isRawFrame(_ u: Float, tolerance: Float = 1e-4) -> Bool {
        abs(u - u.rounded()) < tolerance
    }
}
