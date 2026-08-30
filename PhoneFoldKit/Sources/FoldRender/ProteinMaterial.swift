import Foundation
import RealityKit
import CoreGraphics

/// The protein's one material, and the ramp texture it samples through `uv0`.
///
/// **Shared rather than app-local, because Phase 4 exports video.** PLAN.md's Phase 4 gate asks
/// that "exported video and live playback are audibly and visually identical", and the surest
/// way to fail that is for the offscreen renderer to build its own material. Two constructions
/// of the same thing drift: one gets a roughness change, the other does not, and the difference
/// only shows up in a file somebody has already shared. There is one construction and both
/// paths call it.
public enum ProteinMaterial {

    /// The ramp as a `TextureResource`, or nil if it could not be built.
    ///
    /// **Rows are reversed on the way into the image.** `ColourRamp` numbers its rows by
    /// `SecondaryStructure.rawValue` - coil 0, helix 1, sheet 2 - and RealityKit samples the
    /// texture's V axis the other way up, so a sheet vertex asking for row 2 read row 0 and
    /// came out coil slate. Helix sits in the middle row and was unaffected either way, which
    /// is why the symptom was "the strand has no colour" rather than "the colours are wrong":
    /// on screen the sheet simply vanished into the coil.
    public static func rampTexture(mode: ColourMode, fadingTo target: ColourMode? = nil,
                                   t: Float = 0,
                                   options: ColourOptions) -> TextureResource? {
        let width = ColourRamp.width
        let height = ColourRamp.height
        let logical = ColourRamp.texels(mode: mode, fadingTo: target, t: t, options: options)
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: logical.count)
        for row in 0..<height {
            let source = row * stride
            let destination = (height - 1 - row) * stride
            pixels.replaceSubrange(destination..<(destination + stride),
                                   with: logical[source..<(source + stride)])
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }
        return try? TextureResource.generate(
            from: image, withName: "phonefold-ramp",
            options: .init(semantic: .color, mipmapsMode: .none))
    }

    /// The material for a given colour mode.
    ///
    /// Cheap enough to rebuild on a mode change - the texture is 1024 by 3 texels, so this is
    /// a few milliseconds once - and far too expensive to rebuild per frame. Callers cache it
    /// against the mode they built it for.
    public static func material(mode: ColourMode, fadingTo target: ColourMode? = nil,
                                t: Float = 0,
                                options: ColourOptions) -> RealityKit.Material {
        var material = SimpleMaterial()
        material.roughness = 0.9
        material.metallic = 0
        if let texture = rampTexture(mode: mode, fadingTo: target, t: t, options: options) {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            // A ramp that will not build should not take the protein down with it: a slate
            // protein is a worse picture than a coloured one and a far better one than none.
            material.color = .init(tint: .init(red: 0.42, green: 0.55, blue: 0.65, alpha: 1))
        }
        return material
    }
}
