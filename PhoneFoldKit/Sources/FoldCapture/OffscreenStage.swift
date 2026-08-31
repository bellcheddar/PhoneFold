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
    private let cameraEntity = Entity()
    private var lights: [Entity] = []
    private var mesh: LowLevelTubeMesh?
    private var vertexCapacity = 0
    private var materialMode: ColourMode?
    private var bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)?

    /// The same camera the live stage uses, so the film orbits the way the app does.
    ///
    /// **The type, not a copy of its numbers.** The orbit rate, the resting tilt, the distance
    /// and the sign conventions all live in `StageCamera`, and a second implementation of them
    /// here would be a second thing to keep in step - which the lens and the lighting had each
    /// already got wrong once.
    public var camera = StageCamera()

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
        cameraEntity.components.set(lens)
        renderer.entities.append(cameraEntity)
        renderer.entities.append(protein)
        renderer.activeCamera = cameraEntity

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

    /// How large the protein is made, in scene units.
    ///
    /// 1.15 across its bounding diagonal, which is the live stage's own normalisation. With the
    /// same figure, the same field of view and the same camera distance, the export frames the
    /// protein exactly as the app does - rather than approximately, which is what a separate
    /// framing rule gives however carefully it is written.
    public static let proteinExtent: Float = 1.15

    /// Advance the automatic orbit, and put the camera where it says.
    ///
    /// The stage turns the *protein* against a camera fixed on +Z, which is what the live one
    /// does, so a film made this way rotates in the same direction at the same rate.
    public func advance(by deltaTime: Float) {
        camera.advance(deltaTime: deltaTime)
        applyTransforms()
    }

    /// Place the camera and the protein from the current bounds and camera state.
    ///
    /// The arithmetic is the live stage's, verbatim.
    private func applyTransforms() {
        cameraEntity.transform = Transform(
            scale: .one, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            translation: SIMD3<Float>(0, 0, camera.distance))
        guard let bounds else { return }
        let extent = simd_length(bounds.maximum - bounds.minimum)
        let scale = extent > 0.001 ? Self.proteinExtent / extent : 1
        let centre = (bounds.maximum + bounds.minimum) * 0.5
        let rotation = camera.subjectRotation
        protein.transform = Transform(
            scale: SIMD3<Float>(repeating: scale), rotation: rotation,
            translation: rotation.act(-(centre + camera.target) * scale))
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

        var minimum = built.vertices[0].position
        var maximum = minimum
        for vertex in built.vertices {
            minimum = simd_min(minimum, vertex.position)
            maximum = simd_max(maximum, vertex.position)
        }
        bounds = (minimum, maximum)
        applyTransforms()
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

    /// The texture that was last drawn into, without drawing again.
    ///
    /// Named plainly because the alternative - `render()` returning it - would make "give me
    /// the pixels" and "draw a frame" the same call, and a film writer that asked for the
    /// texture would silently render an extra frame per frame.
    public var texture: MTLTexture { colour }

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
