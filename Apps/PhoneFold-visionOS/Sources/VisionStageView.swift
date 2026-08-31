import SwiftUI

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

/// The immersive version: the same stage with nothing around it.
struct VisionImmersiveView: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @State private var diagnostic = ""

    var body: some View {
        FoldCanvas(player: player, diagnostic: $diagnostic)
            // The concert hall keeps the Phase 3 placement - the protein at room scale around
            // the listener - because here that is not a compromise, it is the thing PLAN asked
            // for. What it gains over the phone is that the sound now turns with the stage.
            .onAppear { player.spatialPlacement = .aroundTheListener }
    }
}
