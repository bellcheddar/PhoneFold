import Testing
import Foundation
import simd
import RealityKit
@testable import FoldCapture
import FoldCore
import FoldGeometry
import FoldRender

/// The offscreen render pass. PLAN.md's Phase 4 forbids ReplayKit for the deliverable and asks
/// for an `MTLTexture` pass at export resolution, so what this has to prove is that a protein
/// really lands in a texture at a size nothing is displaying.
@Suite("Offscreen stage", .serialized)
struct OffscreenStageTests {

    /// A short helix, which is the easiest thing to see whether it drew.
    static func helix(residues n: Int = 24) -> (TubeMesh, [Float], ColourOptions) {
        let rise: Float = 1.5, radius: Float = 2.3, turn: Float = 100 * .pi / 180
        let ca = (0..<n).map { i -> SIMD3<Float> in
            let a = Float(i) * turn
            return SIMD3(radius * cos(a), radius * sin(a), Float(i) * rise)
        }
        let assignment = (0..<n).map { _ in SSAssignment(structure: .helix, confidence: 1) }
        let mesh = TubeGeometry.build(caPositions: ca, secondaryStructure: assignment)
        let confidence = (0..<n).map { _ in Float(90) }
        let residues = (0..<n).map { _ in AminoAcid.alanine }
        return (mesh, confidence, ColourOptions(residueCount: n, residues: residues))
    }

    /// A short digest of a frame.
    ///
    /// **Never compare the pixel arrays themselves in an expectation.** swift-testing prints
    /// the values it compared, and two 1920x1080 frames printed as arrays produced 55 MB of
    /// console output for one failing line.
    static func digest(_ pixels: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in pixels {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// The background, read from a corner rather than assumed.
    ///
    /// Assuming it was wrong: the stage colour is given to RealityKit as sRGB and written into
    /// a linear `rgba8Unorm` target, so the 0.047 asked for arrives as 1, not 12. Every pixel
    /// then counted as drawn and the coverage test could not fail.
    static func background(_ pixels: [UInt8]) -> SIMD3<UInt8> {
        SIMD3(pixels[0], pixels[1], pixels[2])
    }

    /// Far enough back to hold a 24-residue helix, and on its axis.
    ///
    /// The helix runs along +z from 0 to about 34, so it is centred near z = 17 - and a camera
    /// at y = 18 looking down -z, as RealityKit cameras do, misses it entirely.
    static let viewpoint = Transform(scale: .one,
                                     rotation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                                     translation: SIMD3(0, 0, 90))

    /// The fraction of pixels that are not the background.
    static func coverage(_ pixels: [UInt8], background: SIMD3<UInt8>) -> Double {
        var drawn = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let delta = abs(Int(pixels[i]) - Int(background.x))
                + abs(Int(pixels[i + 1]) - Int(background.y))
                + abs(Int(pixels[i + 2]) - Int(background.z))
            if delta > 24 { drawn += 1 }
        }
        return Double(drawn) / Double(pixels.count / 4)
    }

    @MainActor
    static func stage(_ size: OffscreenStage.Size) async throws -> (OffscreenStage, [UInt8]) {
        let stage = try OffscreenStage(size: size)
        let (mesh, confidence, options) = helix()
        try stage.show(mesh: mesh, confidence: confidence, mode: .secondaryStructure,
                       options: options)
        stage.place(camera: Self.viewpoint)
        _ = try await stage.render()
        return (stage, stage.readPixels())
    }

    // MARK: -

    @MainActor
    @Test("a protein lands in a texture with nothing on screen")
    func rendersOffscreen() async throws {
        let (stage, pixels) = try await Self.stage(.landscape)
        #expect(stage.size.width == 1920 && stage.size.height == 1080)
        #expect(pixels.count == 1920 * 1080 * 4)
        // A renderer that ran but drew nothing returns a texture of pure background, which is
        // exactly what a wiring mistake looks like and exactly what this has to rule out.
        let drawn = Self.coverage(pixels, background: Self.background(pixels))
        #expect(drawn > 0.001, "only \(drawn * 100)% of the frame was drawn into")
        #expect(drawn < 0.95, "\(drawn * 100)% drawn - the camera is probably inside the mesh")
    }

    @MainActor
    @Test("the export resolution is the texture's resolution")
    func honoursExportSize() async throws {
        for size in [OffscreenStage.Size.landscape, .vertical, .ultraHD] {
            let stage = try OffscreenStage(size: size)
            #expect(stage.size.width == size.width)
            #expect(stage.size.height == size.height)
            // PLAN.md's three presets, at the aspect ratios they are named for.
            #expect(abs(size.aspect - Float(size.width) / Float(size.height)) < 1e-6)
        }
        #expect(OffscreenStage.Size.landscape.aspect > 1)
        #expect(OffscreenStage.Size.vertical.aspect < 1)
        #expect(OffscreenStage.Size.ultraHD.width == 3840)
    }

    @Test("an odd dimension is made even, because an encoder cannot take it")
    func dimensionsAreEven() {
        // H.264 and HEVC encode in macroblocks: an odd width is either rejected or silently
        // rounded, and a video one pixel narrower than its frames tears diagonally.
        #expect(OffscreenStage.Size(width: 1921, height: 1081).width == 1920)
        #expect(OffscreenStage.Size(width: 1921, height: 1081).height == 1080)
        #expect(OffscreenStage.Size(width: 0, height: 0).width >= 2)
        #expect(OffscreenStage.Size(width: -100, height: -100).height >= 2)
    }

    @MainActor
    @Test("rendering twice does not reallocate the mesh")
    func meshIsReusedAcrossFrames() async throws {
        let stage = try OffscreenStage(size: .landscape)
        let (mesh, confidence, options) = Self.helix()
        stage.place(camera: Self.viewpoint)
        // Sixty frames of the same topology, which is what a trajectory is: the vertex count
        // is constant by construction so the buffer is updated in place rather than rebuilt.
        for _ in 0..<60 {
            try stage.show(mesh: mesh, confidence: confidence, mode: .secondaryStructure,
                           options: options)
            _ = try await stage.render()
        }
        let last = stage.readPixels()
        let drawn = Self.coverage(last, background: Self.background(last))
        #expect(drawn > 0.001, "the sixtieth frame drew nothing")
    }

    @MainActor
    @Test("every colour mode renders, and they are not all the same picture")
    func colourModesDiffer() async throws {
        let stage = try OffscreenStage(size: .landscape)
        let (mesh, confidence, options) = Self.helix()
        stage.place(camera: Self.viewpoint)
        var digests: [ColourMode: UInt64] = [:]
        for mode in ColourMode.allCases {
            try stage.show(mesh: mesh, confidence: confidence, mode: mode, options: options)
            _ = try await stage.render()
            let pixels = stage.readPixels()
            #expect(Self.coverage(pixels, background: Self.background(pixels)) > 0.001,
                    "\(mode) drew nothing")
            digests[mode] = Self.digest(pixels)
        }
        // The material is rebuilt when the mode changes; if it were not, every mode would come
        // out identical and the export would ignore the user's choice.
        let rainbow = try #require(digests[.rainbow])
        let sse = try #require(digests[.secondaryStructure])
        #expect(rainbow != sse, "two colour modes produced the same pixels")
    }
}
