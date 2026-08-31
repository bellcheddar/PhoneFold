import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import FoldCore
import FoldGeometry
import FoldRender
import FoldCapture

/// Render the app icon from a real fold.
///
/// PLAN.md Phase 4's P4-16. **The icon is a frame of the app doing its job**, rendered by the
/// same offscreen stage that makes the films, with the same lighting rig and the same
/// secondary-structure palette. Drawing a protein-like shape by hand would be a picture of what
/// the app does; this is the thing itself, and it costs less than the drawing would.
///
/// An icon is looked at from 40 px upwards, so what matters is the silhouette. The controls
/// below - which protein, which frame, how far the camera sits and how it is turned - are
/// chosen by rendering candidates and looking at them, which is what `--all` is for.
///
///     swift run make-icon --trajectory Apps/Shared/Resources/Trajectories/ubiquitin.pftraj \
///         --out assets/icon/master.png

struct Options {
    var trajectory = "Apps/Shared/Resources/Trajectories/trp_cage.pftraj"
    var out = "assets/icon/master.png"
    var size = 1024
    var yaw: Float = 0
    var pitch: Float = 0.18
    var distance: Float = 1.28
    var mode: ColourMode = .secondaryStructure
    var all = false
    /// Write the protein on a transparent ground instead of on the stage's own.
    var transparent = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: make-icon [options]

      --trajectory <path>  the .pftraj whose final frame is drawn
      --out <path>         where to write the PNG (default assets/icon/master.png)
      --size <n>           square edge in pixels (default 1024)
      --yaw <radians>      turn the protein about the vertical
      --pitch <radians>    tip it toward the viewer (default 0.18, the stage's own)
      --distance <units>   camera distance; smaller fills more of the frame
      --colour <mode>      secondaryStructure | confidence | rainbow | hydrophobicity
      --all                render a contact sheet of candidates instead of one icon
      --transparent        the protein alone, on a transparent ground, for a layered icon

    """.utf8))
    exit(2)
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    func value() -> String {
        guard let next = arguments.first else { usage() }
        arguments.removeFirst()
        return next
    }
    switch argument {
    case "--trajectory": options.trajectory = value()
    case "--out": options.out = value()
    case "--size": options.size = Int(value()) ?? 1024
    case "--yaw": options.yaw = Float(value()) ?? 0
    case "--pitch": options.pitch = Float(value()) ?? 0.18
    case "--distance": options.distance = Float(value()) ?? 1.28
    case "--colour": options.mode = ColourMode(rawValue: value()) ?? .secondaryStructure
    case "--all": options.all = true
    case "--transparent": options.transparent = true
    case "-h", "--help": usage()
    default: usage()
    }
}

/// **No background of its own.** The first version drew a deep radial gradient and composited
/// the render over it, and the gradient was never visible for one line's worth of reason: the
/// offscreen stage clears to an opaque (13, 13, 38) and the render covers the canvas entirely.
/// Every pixel of the corner reads exactly that colour, which is how it was found.
///
/// It is not worth fixing, because it should not be there. That colour *is* the app's stage -
/// the ground every fold in PhoneFold is watched against - so an icon on a gradient would be an
/// icon showing something the app never shows. The icon is a frame of the app, background
/// included.

/// The protein against one known background, as linear 8-bit RGBA.
@MainActor
func pixels(_ options: Options, background: CGColor) async throws -> [UInt8] {
    let bundle = try TrajectoryBundleCodec.read(
        contentsOf: URL(fileURLWithPath: options.trajectory))
    guard let final = bundle.readouts.last else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "the trajectory has no frames"])
    }
    let stage = try OffscreenStage(size: .init(width: options.size, height: options.size),
                                   background: background)
    let ca = final.caPositions
    let mesh = TubeGeometry.build(caPositions: ca,
                                  secondaryStructure: PSEA.assign(caPositions: ca))
    try stage.show(mesh: mesh, confidence: final.confidence, mode: options.mode,
                   options: ColourOptions(residueCount: bundle.residues.count,
                                          residues: bundle.residues))
    stage.camera.drag(deltaX: options.yaw / 0.006, deltaY: (options.pitch - 0.18) / 0.006)
    stage.camera.magnify(scale: 1.5 / options.distance)
    stage.advance(by: 0.0001)
    _ = try await stage.render()
    return stage.readPixels()
}

/// The protein on a transparent ground, solved exactly rather than keyed.
///
/// **Two renders, black and white, and algebra.** visionOS wants a layered icon and refuses a
/// flat one - "must have at least 2 layers with applicable content" - so the protein has to be
/// separable from its background. Keying out the stage's flat colour is the obvious approach
/// and it fringes: the ribbons are shaded, so their dark faces are near the background and a
/// threshold either eats them or keeps a halo.
///
/// Compositing is `C = F + (1 - a) * B` for a known background `B`, so rendering against black
/// and against white gives `C_white - C_black = (1 - a) * (W - B) = 1 - a`, and `a` falls out
/// with no threshold anywhere. The premultiplied colour is then `C_black` itself.
@MainActor
func transparentPixels(_ options: Options) async throws -> [UInt8] {
    let black = try await pixels(options, background: CGColor(red: 0, green: 0, blue: 0,
                                                              alpha: 1))
    let white = try await pixels(options, background: CGColor(red: 1, green: 1, blue: 1,
                                                              alpha: 1))
    var out = [UInt8](repeating: 0, count: black.count)
    for i in stride(from: 0, to: black.count, by: 4) {
        // The channel with the most signal decides alpha; on a neutral background all three
        // agree, and taking the minimum difference is the least noisy of the three.
        var difference = 255
        for c in 0..<3 {
            difference = Swift.min(difference, Int(white[i + c]) - Int(black[i + c]))
        }
        let alpha = 255 - Swift.max(0, Swift.min(255, difference))
        out[i] = black[i]; out[i + 1] = black[i + 1]; out[i + 2] = black[i + 2]
        out[i + 3] = UInt8(alpha)
    }
    return out
}

/// One icon, rendered and composited.
@MainActor
func render(_ options: Options) async throws -> CGImage {
    // The stage's own camera, turned to taste - see `pixels`. Nothing here reaches past its
    // interface: the framing that makes a 20-residue peptide and a 300-residue domain the same
    // size on the stage is the framing that makes them the same size in an icon.
    let pixels = options.transparent
        ? try await transparentPixels(options)
        : try await pixels(options, background: OffscreenStage.defaultBackground)
    // Linear, and tagged linear: the texture is `rgba8Unorm` and labelling linear pixels as
    // sRGB is how a render arrives washed out with nobody able to say why. `OffscreenStage`
    // makes the same point about its own `png()`.
    let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: options.size, height: options.size,
                              bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: options.size * 4, space: space,
                              bitmapInfo: CGBitmapInfo(
                                  rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent)
    else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not build the image"])
    }
    // **Redrawn into sRGB, and this is not a formality.** The texture is linear and the image
    // above is tagged linear, which is right for `OffscreenStage.png()` and wrong for an app
    // icon: an asset catalogue and App Store Connect both want sRGB, and a linear-tagged icon
    // is a visibly darker icon wherever the profile is ignored. Drawing through an sRGB
    // context is what performs the conversion. It was doing so by accident until the
    // background gradient came out and took the context with it - the corner went from
    // (13, 13, 38) to (1, 1, 5), which is the same picture three stops down.
    guard let context = CGContext(data: nil, width: options.size, height: options.size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (options.transparent
                                               ? CGImageAlphaInfo.premultipliedLast
                                               : CGImageAlphaInfo.noneSkipLast).rawValue) else {
        throw NSError(domain: "make-icon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "could not build the sRGB context"])
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: options.size, height: options.size))
    guard let converted = context.makeImage() else {
        throw NSError(domain: "make-icon", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "could not convert to sRGB"])
    }
    return converted
}

@MainActor
func write(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "could not open \(path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "could not write \(path)"])
    }
    print("wrote \(path)  \(image.width)x\(image.height)")
}

if options.all {
    // A contact sheet, because an icon is chosen by looking rather than by reasoning.
    let candidates: [(String, String, Float, Float, ColourMode)] = [
        ("myoglobin-near", "myoglobin", 0, 0.80, .secondaryStructure),
        ("myoglobin-turned", "myoglobin", 1.1, 0.80, .secondaryStructure),
        ("alpha3d-near", "alpha3d", 0, 0.80, .secondaryStructure),
        ("alpha3d-turned", "alpha3d", 1.4, 0.80, .secondaryStructure),
        ("protein_g_b1-near", "protein_g_b1", 0, 0.80, .secondaryStructure),
        ("protein_g_b1-turned", "protein_g_b1", 1.4, 0.80, .secondaryStructure),
        ("ubiquitin-near", "ubiquitin", 0, 0.80, .secondaryStructure),
        ("ubiquitin-turned", "ubiquitin", 1.4, 0.80, .secondaryStructure),
        ("villin-near", "villin_hp36", 0.7, 0.80, .secondaryStructure),
        ("myoglobin-rainbow", "myoglobin", 0, 0.80, .rainbow),
        ("alpha3d-rainbow", "alpha3d", 1.4, 0.80, .rainbow),
        ("protein_g_b1-rainbow", "protein_g_b1", 1.4, 0.80, .rainbow),
    ]
    for (name, stem, yaw, distance, mode) in candidates {
        var one = options
        one.trajectory = "Apps/Shared/Resources/Trajectories/\(stem).pftraj"
        one.yaw = yaw
        one.distance = distance
        one.mode = mode
        one.size = 512
        try write(try await render(one), to: "assets/icon/candidates/\(name).png")
    }
} else {
    try write(try await render(options), to: options.out)
}
