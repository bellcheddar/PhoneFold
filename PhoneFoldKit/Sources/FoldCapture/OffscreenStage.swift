import Foundation
import Metal
import RealityKit
import simd
import FoldCore
import FoldRender

/// Renders the fold into a texture, at whatever size the export asks for.
///
/// PLAN.md Phase 4: "Do **not** use ReplayKit for the deliverable. Render offscreen for a clean
/// output. Offscreen `MTLTexture` pass at export resolution, driven by the same frame stream."
///
/// **`RealityRenderer`, not a second renderer written in Metal.** Verified available and
/// rendering to a 1920x1080 texture on this machine before any of this was written. The
/// alternative - drawing `TubeMesh` again in raw Metal - would be a second implementation of
/// the picture, and PLAN's own gate is that the exported film and live playback are visually
/// identical. Two implementations of a picture are two pictures.
///
/// The mesh, the packing, the colour ramp and the material all come from `FoldRender`, so what
/// is drawn here is what is drawn on screen, at a different size.
/// `RealityRenderer` needs macOS 15, iOS 18 or visionOS 2, which are this package's own
/// minimums - so there is no availability annotation here. One would also make the type
/// untestable: swift-testing refuses to attach `@Suite` or `@Test` to an `@available`
/// declaration.
@MainActor
public final class OffscreenStage {

    public enum Failure: Error, CustomStringConvertible {
        case noMetalDevice
        case noTexture(width: Int, height: Int)
        case rendererFailed(String)
        case renderFailed(String)

        public var description: String {
            switch self {
            case .noMetalDevice: "This machine has no Metal device."
            case .noTexture(let w, let h): "Could not allocate a \(w) by \(h) render target."
            case .rendererFailed(let m): "The offscreen renderer could not be built: \(m)"
            case .renderFailed(let m): "The offscreen render failed: \(m)"
            }
        }
    }

    /// What the export is being rendered at.
    public struct Size: Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            // Even dimensions, because H.264 and HEVC both encode in macroblocks and an odd
            // width is either rejected or silently rounded by the encoder - and a video one
            // pixel narrower than the frames fed into it tears diagonally.
            self.width = Swift.max(width - (width % 2), 2)
            self.height = Swift.max(height - (height % 2), 2)
        }

        /// PLAN.md's three presets.
        public static let landscape = Size(width: 1920, height: 1080)
        public static let vertical = Size(width: 1080, height: 1920)
        public static let ultraHD = Size(width: 3840, height: 2160)

        public var aspect: Float { Float(width) / Float(height) }
    }

    public let size: Size
    public let device: MTLDevice
    private let renderer: RealityRenderer
    private let colour: MTLTexture
    private let depth: MTLTexture

    private let protein = Entity()
    private let camera = Entity()
    private var lights: [Entity] = []
    private var mesh: LowLevelTubeMesh?
    private var vertexCapacity = 0
    private var materialMode: ColourMode?

    public init(size: Size) throws {
        self.size = size
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noMetalDevice }
        self.device = device

        let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size.width, height: size.height, mipmapped: false)
        colourDescriptor.usage = [.renderTarget, .shaderRead]
        // Shared, not private: the whole point is to read the pixels back into a pixel buffer,
        // and a private texture cannot be read without a blit into a staging buffer.
        colourDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size.width, height: size.height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let colour = device.makeTexture(descriptor: colourDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor)
        else { throw Failure.noTexture(width: size.width, height: size.height) }
        self.colour = colour
        self.depth = depth

        do { renderer = try RealityRenderer() } catch {
            throw Failure.rendererFailed(error.localizedDescription)
        }

        // The field of view is set rather than defaulted, because the framing maths below
        // needs to know it and a default that changed in a later SDK would silently reframe
        // every export.
        var lens = PerspectiveCameraComponent()
        lens.fieldOfViewInDegrees = Self.fieldOfViewDegrees
        lens.fieldOfViewOrientation = .vertical
        // The near and far planes are set from the protein's own scale rather than left at a
        // room-scale default: the depth buffer's precision goes as the ratio of the two, and
        // the live stage's dark creases along the ribbons were exactly this - 10,000 to 1
        // spends almost all of the buffer on the first fraction of the scene.
        lens.near = 0.5
        lens.far = 2_000
        camera.components.set(lens)
        renderer.entities.append(camera)
        renderer.entities.append(protein)
        renderer.activeCamera = camera

        // **The stage has to light itself, and the live one used not to.**
        //
        // `RealityView` supplies a default environment automatically; `RealityRenderer` supplies
        // nothing at all, so a lit `SimpleMaterial` renders black - and against a near-black
        // stage that is a frame in which the protein is present and invisible. Measured: with
        // no light, 0% of the frame differed from the background.
        //
        // The rig comes from `FoldRender` and the live view now uses the same one, so the two
        // paths are lit by the same code rather than by a default on one side and a guess on
        // the other. That was Marc's call on 2026-08-31.
        lights = StageLighting.makeLights()
        for light in lights { renderer.entities.append(light) }
        renderer.cameraSettings.colorBackground = .color(.init(red: 0.047, green: 0.039,
                                                              blue: 0.122, alpha: 1))
    }

    /// Vertical field of view, in degrees.
    ///
    /// **42, because that is what the live stage uses.** Lighting was not the only thing that
    /// differed between the two paths: a 60-degree lens against the live view's 42 gives a
    /// visibly deeper perspective on the same protein, which "exported video and live playback
    /// are visually identical" does not survive either. Matching the lens costs nothing.
    public static let fieldOfViewDegrees: Float = 42

    /// Where the camera stands, in the same terms the live stage uses.
    public func place(camera transform: Transform) {
        camera.transform = transform
    }

    /// Frame a protein of a given extent so it fills the picture.
    ///
    /// **Here rather than in each caller**, because the distance depends on the field of view
    /// and the caller does not know it. The first version guessed at `radius * 3.2 + 6` and
    /// put a 129-residue protein in the middle third of a 1920 by 1080 frame.
    ///
    /// The vertical axis is the limiting one at every preset except the vertical video, where
    /// it is the horizontal - so the aspect is folded in rather than assumed.
    public func frame(centre: SIMD3<Float>, radius: Float, margin: Float = 1.12) {
        let vertical = Self.fieldOfViewDegrees * .pi / 180
        var half = vertical / 2
        if size.aspect < 1 {
            // Taller than it is wide: the horizontal field is the narrower one.
            half = atan(tan(vertical / 2) * size.aspect)
        }
        let distance = Swift.max(radius, 0.001) / tan(Swift.max(half, 0.01)) * margin
        camera.transform = Transform(scale: .one,
                                     rotation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                                     translation: centre + SIMD3(0, 0, distance))
    }

    /// The centre and radius of a set of points, for `frame(centre:radius:)`.
    public static func extent(of points: [SIMD3<Float>]) -> (centre: SIMD3<Float>, radius: Float) {
        guard !points.isEmpty else { return (.zero, 1) }
        let centre = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let radius = points.map { simd_length($0 - centre) }.max() ?? 1
        return (centre, Swift.max(radius, 0.001))
    }

    /// Put one frame's geometry on the stage.
    ///
    /// The mesh is reallocated only when the vertex count changes, which across a trajectory
    /// is once: `TubeGeometry` emits a constant vertex count by construction so the buffer can
    /// be updated in place rather than rebuilt sixty times a second.
    public func show(mesh built: TubeMesh, confidence: [Float], mode: ColourMode,
                     options: ColourOptions) throws {
        guard !built.vertices.isEmpty else { return }
        let packed = TubeMeshPacker.pack(built, residueConfidence: confidence, mode: mode,
                                         options: options)
        if mesh == nil || vertexCapacity != packed.count {
            let low = try LowLevelTubeMesh(template: built)
            mesh = low
            vertexCapacity = packed.count
            materialMode = nil
        }
        if materialMode != mode, let low = mesh {
            protein.components.set(ModelComponent(
                mesh: try low.resource(),
                materials: [ProteinMaterial.material(mode: mode, options: options)]))
            materialMode = mode
        }
        try mesh?.update(vertices: packed)
    }

    /// Draw, and hand back the texture that was drawn into.
    ///
    /// **Asynchronous, and waiting on the renderer's own completion rather than a command
    /// buffer of ours.** `RealityRenderer` owns and commits its own command buffer, so an
    /// external `commit()` and `waitUntilCompleted()` waits for nothing and returns while the
    /// GPU is still drawing - which hands the encoder the *previous* frame, and a film one
    /// frame out of step with its own audio is the sort of thing nobody notices until it is
    /// published. `onComplete` is the only signal that the pixels are there.
    @discardableResult
    public func render() async throws -> MTLTexture {
        let output = try RealityRenderer.CameraOutput(
            .singleProjection(colorTexture: colour))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: output,
                                             onComplete: { _ in continuation.resume() })
            } catch {
                continuation.resume(throwing: Failure.renderFailed(error.localizedDescription))
            }
        }
        return colour
    }

    /// The rendered pixels, as 8-bit RGBA rows.
    ///
    /// For the tests and for anything that wants to look at what was drawn without an
    /// `AVAssetWriter` in the way.
    public func readPixels() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            colour.getBytes(raw.baseAddress!, bytesPerRow: size.width * 4,
                            from: MTLRegionMake2D(0, 0, size.width, size.height),
                            mipmapLevel: 0)
        }
        return pixels
    }
}

#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension OffscreenStage {

    /// The rendered frame as PNG data.
    ///
    /// The poster frame for a film, the still for a share sheet, and the only way to look at
    /// what the offscreen pass drew without an encoder in the way. The texture is linear
    /// `rgba8Unorm`, so the image is tagged linear rather than sRGB: labelling linear pixels
    /// as sRGB is how a render arrives washed out and nobody can say why.
    public func png() -> Data? {
        let pixels = readPixels()
        guard let space = CGColorSpace(name: CGColorSpace.linearSRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size.width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
