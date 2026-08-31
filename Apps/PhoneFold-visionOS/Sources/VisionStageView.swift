import SwiftUI
import FoldRender

/// The protein in a volume, with its transport on an ornament.
///
/// PLAN.md: "Ornament-based transport rather than an overlay, so the stage stays clean." An
/// overlay would sit inside the volume and be part of the object; an ornament hangs outside it
/// and belongs to the window, which is what keeps the protein looking like a protein.
struct VisionStageView: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @State private var diagnostic = ""

    /// How wide the protein looks in the volume, and how far in front of the listener the
    /// volume sits, both in metres.
    ///
    /// The volume is declared 0.6 m on a side and the stage frames the protein to fill it, so
    /// 0.6 is what the eye sees. The distance is the one number here that is a guess rather
    /// than a measurement: a volume is placed by the person wearing the headset and the app is
    /// not told where it ended up, so this is arm's length, which is where one is usually put.
    /// It is in `BLOCKERS.md` as something only the headset settles.
    static let span: Float = 0.6
    static let distance: Float = 1.0

    var body: some View {
        FoldCanvas(player: player, diagnostic: $diagnostic)
            // PLAN.md Phase 5c: on a desk the protein has a *place*, and the sound has to come
            // from it. Audio arriving from inside your own skull for something you are looking
            // at over there is wrong in a way that is hard to name and impossible to ignore.
            .onAppear {
                player.spatialPlacement = .inAVolume(distance: Self.distance, span: Self.span)
            }
            // Back to the Phase 3 placement when the volume closes, so a fold that continues
            // in the immersive space is not still singing from a desk that has gone.
            .onDisappear { player.spatialPlacement = .aroundTheListener }
            // Off unless asked for, exactly as on the phone. It is the only way to see from
            // outside whether the hand has a box to pinch: `simctl launch --console-pty`
            // returns nothing for this app, so a number on the glass and a screenshot is the
            // channel that works.
            .overlay(alignment: .topLeading) {
                if Diagnostics.isEnabled {
                    Text(diagnostic)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .glassBackgroundEffect()
                        .padding(8)
                }
            }
            .ornament(attachmentAnchor: .scene(.bottom)) {
                VisionTransport()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .glassBackgroundEffect()
            }
    }
}

/// How big the protein stands in the concert hall, shared between the space and the window.
///
/// **The control cannot live with the stage.** PLAN asks for "ornament-based transport rather
/// than an overlay", and that is right for the volume - but an `ImmersiveSpace` has no window,
/// and an ornament with nothing to hang from simply does not appear. It compiled, it ran, and
/// the first screenshot of the concert hall had no control in it anywhere. So the walk control
/// belongs to the control window, which stays open in the shared space beside the room, and the
/// two ends share this.
@MainActor
final class VisionStage: ObservableObject {
    static let shared = VisionStage()

    @Published private(set) var roomScale = RoomScale()

    /// The colour mode to put back on the way out. Walking in switches to hydrophobicity,
    /// because a core you cannot see the hydrophobicity of is just the middle of something -
    /// and a mode the app changed and never changed back is a mode the user has lost.
    private var colourModeOutside: ColourMode?

    var isInside: Bool { roomScale.isInsideCore }

    func setScale(_ multiplier: Float) {
        roomScale = RoomScale(multiplier: multiplier)
    }

    func walkIn() {
        let player = PhoneFoldModel.shared.player
        if colourModeOutside == nil { colourModeOutside = player.colourMode }
        player.colourMode = .hydrophobicity
        roomScale = .walkedIn
    }

    func walkOut() {
        if let mode = colourModeOutside {
            PhoneFoldModel.shared.player.colourMode = mode
            colourModeOutside = nil
        }
        roomScale = RoomScale()
    }
}

/// The immersive version: the same stage with nothing around it, and the one place you can
/// stand inside the protein.
///
/// PLAN.md Phase 5c: "**Walk into the core:** scale the protein up until you are standing
/// inside it as the hydrophobic core packs around you. Absurd, memorable, and scientifically
/// legible."
///
/// **The scale is arithmetic rather than taste**, which is the "legible" half: `RoomScale`
/// carries two fractions measured on the bundled structures - how deep a hydrophobic core is,
/// and how a structure's radius relates to the diagonal the stage frames it by - and derives
/// the smallest scale at which the core has actually closed around a person. It comes out at
/// x2.6, about three metres of protein. Below that you are inside the *structure* looking at
/// its core from outside, which is a different and much less interesting experience.
struct VisionImmersiveView: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @ObservedObject private var stage = VisionStage.shared
    @State private var diagnostic = ""

    /// Roughly eye level for a standing adult. **An `ImmersiveSpace`'s origin is the floor at
    /// the wearer's feet**, not the middle of a box the way a window or a volume is, so a stage
    /// left at zero is a protein sunk into the carpet - which is exactly what the first run of
    /// this looked like: the space opened, the button changed, and the room was empty.
    static let eyeLevel: Float = 1.4

    /// Where the stage stands: in front of you outside it, around your head once you are in.
    ///
    /// Walking in is the protein coming to *you* rather than you being teleported into it.
    /// visionOS gives an app no way to move the wearer, and it should not: moving someone's
    /// viewpoint without them walking is the shortest route to making them ill.
    private var placement: SIMD3<Float> {
        stage.isInside ? SIMD3(0, Self.eyeLevel, 0) : SIMD3(0, Self.eyeLevel, -1.6)
    }

    var body: some View {
        FoldCanvas(player: player, diagnostic: $diagnostic, roomScale: stage.roomScale,
                   stagePlacement: placement)
            // The concert hall keeps the Phase 3 placement - the protein at room scale around
            // the listener - because here that is not a compromise, it is the thing PLAN asked
            // for. What it gains over the phone is that the sound now turns with the stage.
            .onAppear {
                player.spatialPlacement = .aroundTheListener
                // See `VisionControlView`'s autostart: nothing can press this from outside.
                if ProcessInfo.processInfo.environment["PHONEFOLD_VISION_WALK_IN"] == "1" {
                    stage.walkIn()
                }
            }
            .onDisappear { stage.walkOut() }
    }
}

/// The walk control, shown in the control window while the concert hall is open.
struct WalkIntoTheCoreControls: View {
    @ObservedObject private var stage = VisionStage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(stage.isInside ? "Step back out" : "Walk into the core") {
                    withAnimation(.easeInOut(duration: 2.5)) {
                        stage.isInside ? stage.walkOut() : stage.walkIn()
                    }
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 1) {
                    // The measured numbers, on the glass: they are the reason the scale is what
                    // it is, and "3.0 m across" is the only honest way to say how big a thing
                    // you are about to be inside.
                    Text(String(format: "%.1f m across", stage.roomScale.widthInMetres))
                        .font(.caption).monospacedDigit()
                    Text(String(format: stage.isInside
                                ? "core radius %.1f m - you are in it"
                                : "core radius %.1f m",
                                stage.roomScale.coreRadiusInMetres))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Slider(value: Binding(get: { Double(stage.roomScale.multiplier) },
                                  set: { stage.setScale(Float($0)) }),
                   in: 1...Double(RoomScale.maximumMultiplier))
                .accessibilityLabel("How big the protein stands in the room")
        }
    }
}
