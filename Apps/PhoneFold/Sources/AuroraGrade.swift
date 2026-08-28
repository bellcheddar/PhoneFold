import SwiftUI

/// The stage's grade: a cartoon outline around the backbone, and a vignette over it.
///
/// **What is not here, and why.** PLAN.md asks Phase 2 for "HDR bloom on emissives, mild
/// depth of field, vignette, Aurora grade". Bloom and depth of field are screen-space
/// effects, and every API that could reach the stage's pixels was tried and measured:
///
/// - `CustomMaterial`: will not build a pipeline on the Simulator. `fsSurfacePbr` reports
///   "Constant buffer count [16] exceeds limit [14]", the technique never compiles, and the
///   mesh silently does not draw. Verified by bisection against `SimpleMaterial`.
/// - `ARView.renderCallbacks.postProcess`: the only API that hands over the rendered colour
///   *and depth* textures, which is exactly what bloom and a true depth of field want.
///   Assigning it traps on the Simulator - `EXC_BREAKPOINT` inside
///   `ARView.renderCallbacks.setter`, no assertion text in the log, process gone. Confirmed
///   by an A/B of that single line: unset, the app runs; set, it dies. It may well work on
///   hardware, and there is no hardware here to find out on.
/// - SwiftUI `layerEffect` and `colorEffect`: SwiftUI cannot apply a shader over a
///   `RealityView` and substitutes its unsupported-effect placeholder.
///
/// So the glow is done in object space instead, as a halo shell welded to the tube's own
/// normals, and the vignette by compositing, which needs no shader at all.
///
/// **And one thing deliberately not done.** A tone curve over the stage would lift the
/// shadows and add contrast, and it would also distort the pLDDT ramp, whose steps are the
/// reason PLAN.md picked it: it is a data scale that structural biologists read at a glance,
/// not decoration. The stage is graded around the protein - background, halo, vignette - and
/// the protein's own colours are left true.
struct AuroraGrade: Equatable {

    /// How dark the corners of the stage go.
    var vignette: Double = 0.55
    /// How far the outline stands off the cartoon, in angstroms.
    ///
    /// An absolute distance rather than a fraction of the coil radius: coil is now a thin
    /// cord, so a fraction of it is far too fine to read as an outline beside a ribbon more
    /// than four times as wide.
    var outlineWidth: Double = 0.16
    /// How solid the outline is.
    var outlineOpacity: Double = 0.85

    static let none = AuroraGrade(vignette: 0, outlineWidth: 0, outlineOpacity: 0)

    /// Cheaper: the halo goes, the vignette stays.
    ///
    /// The vignette is one composited gradient and costs nothing worth measuring. The halo is
    /// a second pass over the tube's geometry every frame, so that is what a hot or low-power
    /// device gives up.
    var reduced: AuroraGrade {
        var reduced = self
        reduced.outlineWidth = 0
        reduced.outlineOpacity = 0
        return reduced
    }

    /// What the current thermal state and power mode allow.
    ///
    /// PLAN.md's rule is that degradation must never delay the fold, so the grade sheds its
    /// cost before the frame rate is touched.
    static func forCurrentConditions() -> AuroraGrade {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: .none
        case .serious: AuroraGrade().reduced
        default: ProcessInfo.processInfo.isLowPowerModeEnabled ? AuroraGrade().reduced
                                                               : AuroraGrade()
        }
    }
}

extension View {
    /// Vignette the stage.
    ///
    /// Composited rather than shaded, because SwiftUI will not run a shader over a
    /// `RealityView`. The gradient is sized from the view rather than given a fixed radius so
    /// it lands the same on an iPhone and on a Mac window, and it starts a third of the way
    /// out so the protein itself is never dimmed.
    @ViewBuilder
    func auroraVignette(_ grade: AuroraGrade) -> some View {
        if grade.vignette <= 0 {
            self
        } else {
            overlay {
                GeometryReader { proxy in
                    let diagonal = hypot(proxy.size.width, proxy.size.height) * 0.5
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.35),
                            .init(color: Color(hex: 0x05040E).opacity(grade.vignette),
                                  location: 1),
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: max(diagonal, 1))
                }
                .allowsHitTesting(false)
            }
        }
    }
}
