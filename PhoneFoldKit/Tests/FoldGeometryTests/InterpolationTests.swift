import Testing
import Foundation
import simd
import FoldCore
@testable import FoldGeometry

@Suite("Trajectory interpolation")
struct InterpolationTests {

    static func helix(_ n: Int, phase: Float = 0, scale: Float = 1) -> [SIMD3<Float>] {
        (0..<n).map { k in
            let theta = Float(k) * 100 * .pi / 180 + phase
            return SIMD3<Float>(2.3 * scale * cos(theta),
                                2.3 * scale * sin(theta),
                                Float(k) * 1.5)
        }
    }

    /// Catmull-Rom must pass exactly through its control points. A raw readout is a real
    /// model output and must be displayed as it is, not smoothed away.
    @Test("interpolation passes exactly through every raw readout")
    func passesThroughControlPoints() {
        let frames = (0..<6).map { Self.helix(20, phase: Float($0) * 0.2) }
        let interp = TrajectoryInterpolator(rawFrames: frames, alreadyAligned: true)
        for i in 0..<6 {
            let got = interp.positions(at: Float(i))
            for k in got.indices {
                #expect(simd_distance(got[k], frames[i][k]) < 1e-4,
                        "frame \(i) residue \(k) drifted")
            }
        }
    }

    @Test("the spline is continuous: no jumps between adjacent samples")
    func continuity() {
        let frames = (0..<8).map { Self.helix(30, phase: Float($0) * 0.35) }
        let interp = TrajectoryInterpolator(rawFrames: frames, alreadyAligned: true)
        var previous = interp.positions(at: 0)
        var largest: Float = 0
        for step in 1...700 {
            let u = Float(step) / 700 * Float(frames.count - 1)
            let current = interp.positions(at: u)
            for k in current.indices {
                largest = max(largest, simd_distance(current[k], previous[k]))
            }
            previous = current
        }
        // With 700 samples over 7 raw frames, no single step should move an atom far.
        #expect(largest < 0.5, "largest per-sample jump was \(largest)")
    }

    @Test("out-of-range parameters clamp rather than extrapolate")
    func clamping() {
        let frames = (0..<4).map { Self.helix(15, phase: Float($0) * 0.3) }
        let interp = TrajectoryInterpolator(rawFrames: frames, alreadyAligned: true)
        let before = interp.positions(at: -5)
        let first = interp.positions(at: 0)
        let after = interp.positions(at: 99)
        let last = interp.positions(at: Float(frames.count - 1))
        for k in first.indices {
            #expect(simd_distance(before[k], first[k]) < 1e-4)
            #expect(simd_distance(after[k], last[k]) < 1e-4)
        }
    }

    /// Interpolating between two orientations of the SAME structure without aligning them
    /// first drags every atom through the middle of the molecule. This is the check that
    /// the alignment step is actually doing its job.
    @Test("aligning first stops the molecule collapsing through itself")
    func alignmentPreventsCollapse() {
        let base = Self.helix(40)
        let rotation = simd_float3x3(simd_quatf(angle: .pi * 0.8, axis: simd_normalize(SIMD3<Float>(1, 1, 0))))
        let rotated = base.map { rotation * $0 + SIMD3<Float>(20, -10, 5) }

        func midpointRadius(_ frames: [[SIMD3<Float>]], aligned: Bool) -> Float {
            let interp = TrajectoryInterpolator(rawFrames: frames, alreadyAligned: !aligned)
            let mid = interp.positions(at: 0.5)
            let centre = mid.reduce(SIMD3<Float>.zero, +) / Float(mid.count)
            let sq = mid.map { simd_length_squared($0 - centre) }.reduce(0, +) / Float(mid.count)
            return sq.squareRoot()
        }

        let unaligned = midpointRadius([base, rotated], aligned: false)
        let aligned = midpointRadius([base, rotated], aligned: true)
        let reference = { () -> Float in
            let centre = base.reduce(SIMD3<Float>.zero, +) / Float(base.count)
            let sq = base.map { simd_length_squared($0 - centre) }.reduce(0, +) / Float(base.count)
            return sq.squareRoot()
        }()

        // Aligned, the midpoint is the same structure and keeps its size. Unaligned, it
        // collapses towards the centre.
        #expect(abs(aligned - reference) < 0.05 * reference,
                "aligned midpoint radius \(aligned) vs reference \(reference)")
        #expect(unaligned < 0.9 * reference,
                "unaligned midpoint should collapse; got \(unaligned) vs \(reference)")
    }

    @Test("raw frames are distinguishable from interpolated ones")
    func rawFrameDetection() {
        let interp = TrajectoryInterpolator(rawFrames: (0..<3).map { Self.helix(10, phase: Float($0)) },
                                            alreadyAligned: true)
        #expect(interp.isRawFrame(0))
        #expect(interp.isRawFrame(1))
        #expect(interp.isRawFrame(2))
        #expect(interp.isRawFrame(0.5) == false)
        #expect(interp.isRawFrame(1.25) == false)
    }

    @Test("frame budget matches the requested rate and pacing")
    func frameBudget() {
        let interp = TrajectoryInterpolator(rawFrames: (0..<101).map { Self.helix(10, phase: Float($0) * 0.01) },
                                            alreadyAligned: true)
        // 100 intervals at 0.1 s each = 10 s; at 60 fps that is 600 frames plus the first.
        #expect(interp.outputFrameCount(frameRate: 60, secondsPerRawFrame: 0.1) == 601)
        #expect(interp.parameter(forOutputFrame: 0, outOf: 601) == 0)
        #expect(abs(interp.parameter(forOutputFrame: 600, outOf: 601) - 100) < 1e-3)
    }

    @Test("degenerate inputs do not trap")
    func degenerate() {
        #expect(TrajectoryInterpolator(rawFrames: []).positions(at: 0).isEmpty)
        let single = TrajectoryInterpolator(rawFrames: [Self.helix(5)], alreadyAligned: true)
        #expect(single.positions(at: 0).count == 5)
        #expect(single.positions(at: 17).count == 5)
    }

    /// End to end on a real trajectory: align, interpolate to 60 fps, and check that the
    /// chain stays a chain. This is the Phase 1 gate's "sustains 60 fps output" criterion
    /// expressed as a property rather than a timing measurement.
    @Test("a real trajectory interpolates to 60 fps without breaking the chain")
    func realTrajectory() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/genie2_76aa_seed1.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let interp = TrajectoryInterpolator(rawFrames: bundle.readouts.map(\.caPositions))
        #expect(interp.rawFrameCount == bundle.readouts.count)

        let total = interp.outputFrameCount(frameRate: 60, secondsPerRawFrame: 1.0 / 12.0)
        #expect(total > 900, "expected a few hundred frames of animation, got \(total)")

        // The final interpolated frame must still be a real polypeptide.
        let last = interp.positions(at: Float(interp.rawFrameCount - 1))
        var bonds: [Float] = []
        for k in 1..<last.count { bonds.append(simd_distance(last[k], last[k - 1])) }
        let mean = bonds.reduce(0, +) / Float(bonds.count)
        #expect(abs(mean - 3.8) < 0.2, "final CA-CA should be near 3.8 A, got \(mean)")

        for i in stride(from: 0, to: total, by: 37) {
            let u = interp.parameter(forOutputFrame: i, outOf: total)
            let frame = interp.positions(at: u)
            #expect(frame.count == bundle.metadata.residueCount)
            #expect(frame.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
    }
}
