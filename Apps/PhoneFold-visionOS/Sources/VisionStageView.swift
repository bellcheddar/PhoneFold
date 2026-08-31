import SwiftUI

/// The protein in a volume, with its transport on an ornament.
///
/// PLAN.md: "Ornament-based transport rather than an overlay, so the stage stays clean." An
/// overlay would sit inside the volume and be part of the object; an ornament hangs outside it
/// and belongs to the window, which is what keeps the protein looking like a protein.
struct VisionStageView: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @State private var diagnostic = ""

    var body: some View {
        FoldCanvas(player: player, diagnostic: $diagnostic)
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
    }
}
