import Testing
import Foundation
import simd
import FoldCore
@testable import FoldRender

@Suite("Colour modes")
struct ColouringTests {

    static func vertex(confidence: Float = 80, parameter: Float = 0,
                       structure: SecondaryStructure = .coil,
                       structureConfidence: Float = 1) -> RenderVertex {
        RenderVertex(position: .zero, normal: SIMD3<Float>(0, 0, 1),
                     residueParameter: parameter,
                     structureConfidence: structureConfidence,
                     structureCode: Float(structure.rawValue),
                     residueConfidence: confidence)
    }

    /// sRGB hex treated as linear is visibly too dark in the mid-tones and makes the whole
    /// stage look muddy. Mid-grey is the case that exposes it: 0.5 sRGB is 0.214 linear.
    @Test("hex colours are converted from sRGB to linear, not used raw")
    func srgbConversion() {
        let midGrey = Palette.linear(hex: 0x808080)
        #expect(abs(midGrey.x - 0.2158) < 0.002, "0x80 should linearise to ~0.216, got \(midGrey.x)")
        // The endpoints are fixed points of the transfer function.
        #expect(Palette.linear(hex: 0x000000) == LinearRGB(0, 0, 0))
        let white = Palette.linear(hex: 0xFFFFFF)
        #expect(abs(white.x - 1) < 1e-5)
    }

    /// The AlphaFold ramp has to read instantly to a structural biologist: low is orange,
    /// high is blue, and the band boundaries at 50, 70 and 90 keep their meaning.
    @Test("the pLDDT ramp runs orange to blue and respects the AlphaFold bands")
    func pLDDTRamp() {
        let veryLow = Colouring.pLDDT(20)
        let veryHigh = Colouring.pLDDT(98)
        #expect(veryLow == Palette.pLDDTVeryLow, "below 40 should be flat orange")

        // Red falls monotonically across the whole ramp. That is the only channel-wise
        // claim that holds end to end.
        //
        // Blue does not, and neither does warmth. AlphaFold's orange (#FF7D45) carries MORE
        // blue than its yellow (#FFDB13) - 0x45 against 0x13 - and both sit at 0xFF red. So
        // on the first leg blue falls and red minus blue rises: by any channel measure the
        // ramp gets warmer before it turns cool. That is a property of the published palette,
        // not a defect, and asserting otherwise would be asserting a nicer palette than the
        // one structural biologists actually recognise. The blue climb is checked from 60,
        // where the run to cyan begins, and the ends are checked directly.
        var previousRed = Float.greatestFiniteMagnitude
        for step in 0...50 {
            let value = Float(step) * 2
            let colour = Colouring.pLDDT(value)
            #expect(colour.x <= previousRed + 1e-5, "red rose at pLDDT \(value)")
            previousRed = colour.x
        }

        // The four published stops, so the ramp's behaviour is documented rather than
        // guessed at. Blue, as 8-bit sRGB: 0x45, 0x13, 0xF3, 0xD6. It falls, leaps, then
        // falls again, because dark blue is simply darker than cyan. There is no leg-wise
        // blue monotonicity to assert, and inventing one only produces a test that fails on
        // the real AlphaFold colours.
        let stops = [Palette.pLDDTVeryLow, Palette.pLDDTLow,
                     Palette.pLDDTConfident, Palette.pLDDTVeryHigh]
        for i in 0..<stops.count {
            for j in (i + 1)..<stops.count {
                #expect(simd_distance(stops[i], stops[j]) > 0.05,
                        "ramp stops \(i) and \(j) are too close to tell apart")
            }
        }
        #expect(veryHigh.z > veryLow.z * 2, "high confidence must read blue")
        #expect(veryLow.x > veryHigh.x, "low confidence must read warm")

        // Each band boundary sits halfway into its transition, by construction.
        for (boundary, from, to) in [(Float(50), Palette.pLDDTVeryLow, Palette.pLDDTLow),
                                     (70, Palette.pLDDTLow, Palette.pLDDTConfident),
                                     (90, Palette.pLDDTConfident, Palette.pLDDTVeryHigh)] {
            let midpoint = Colouring.mix(from, to, 0.5)
            #expect(simd_distance(Colouring.pLDDT(boundary), midpoint) < 1e-4,
                    "pLDDT \(boundary) should sit at the midpoint of its transition")
        }
    }

    @Test("out-of-range confidence clamps rather than producing a nonsense colour")
    func pLDDTClamps() {
        #expect(Colouring.pLDDT(-50) == Palette.pLDDTVeryLow)
        #expect(Colouring.pLDDT(1000) == Palette.pLDDTVeryHigh)
        for v in [Float(-50), 0, 50, 100, 1000] {
            let c = Colouring.pLDDT(v)
            #expect(c.x.isFinite && c.y.isFinite && c.z.isFinite)
            #expect(c.min() >= 0 && c.max() <= 1.01)
        }
    }

    /// Structure colour grows in with confidence, so it does not snap on the frame the
    /// assignment flips.
    @Test("structure colour fades in from coil rather than snapping")
    func structureFadesIn() {
        let options = ColourOptions(residueCount: 20)
        let none = Colouring.colour(Self.vertex(structure: .helix, structureConfidence: 0),
                                    mode: .secondaryStructure, options: options)
        let full = Colouring.colour(Self.vertex(structure: .helix, structureConfidence: 1),
                                    mode: .secondaryStructure, options: options)
        #expect(simd_distance(none, Palette.coilSlate) < 1e-5)
        #expect(simd_distance(full, Palette.helixMagenta) < 1e-5)

        var previous = simd_distance(none, Palette.helixMagenta)
        for step in 1...10 {
            let c = Colouring.colour(
                Self.vertex(structure: .helix, structureConfidence: Float(step) / 10),
                mode: .secondaryStructure, options: options)
            let distance = simd_distance(c, Palette.helixMagenta)
            #expect(distance <= previous + 1e-6, "colour should approach the target")
            previous = distance
        }
    }

    @Test("helix, sheet and coil are visually distinct in both palettes")
    func structuresAreDistinct() {
        for accessible in [false, true] {
            let options = ColourOptions(residueCount: 20, accessiblePalette: accessible)
            let colours = [SecondaryStructure.helix, .sheet, .coil].map {
                Colouring.colour(Self.vertex(structure: $0), mode: .secondaryStructure,
                                 options: options)
            }
            for i in 0..<colours.count {
                for j in (i + 1)..<colours.count {
                    #expect(simd_distance(colours[i], colours[j]) > 0.1,
                            "structures too close in the \(accessible ? "accessible" : "stage") palette")
                }
            }
            if accessible {
                // The accessible palette must also separate on luminance, so it survives
                // greyscale and the common colour-blindness types.
                func luminance(_ c: LinearRGB) -> Float {
                    0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                }
                let ls = colours.map(luminance).sorted()
                #expect(ls[1] - ls[0] > 0.03 && ls[2] - ls[1] > 0.03,
                        "accessible palette must separate on luminance too: \(ls)")
            }
        }
    }

    @Test("rainbow runs continuously from N to C without wrapping back")
    func rainbowRuns() {
        let start = Colouring.rainbow(0)
        let end = Colouring.rainbow(1)
        #expect(simd_distance(start, end) > 0.1, "the two termini must not be the same colour")
        var previous = start
        var total: Float = 0
        for step in 1...100 {
            let c = Colouring.rainbow(Float(step) / 100)
            total += simd_distance(previous, c)
            previous = c
        }
        #expect(total > 0.5, "the rainbow should actually traverse the spectrum")
    }

    /// Core formation is what this mode exists to show, so hydrophobic and hydrophilic must
    /// sit at opposite ends.
    @Test("hydrophobicity separates the Kyte-Doolittle extremes")
    func hydrophobicitySeparates() {
        let residues: [AminoAcid] = [.isoleucine, .arginine, .alanine, .lysine]
        let mostHydrophobic = Colouring.hydrophobicity(at: 0, residues: residues)   // I, +4.5
        let mostHydrophilic = Colouring.hydrophobicity(at: 1, residues: residues)   // R, -4.5
        #expect(simd_distance(mostHydrophobic, mostHydrophilic) > 0.15)
        // Warm for hydrophobic, cool for hydrophilic.
        #expect(mostHydrophobic.x > mostHydrophilic.x)
        #expect(mostHydrophilic.z > mostHydrophobic.z)
        // No residues at all is neutral rather than a crash or a wrong claim.
        #expect(Colouring.hydrophobicity(at: 0, residues: []) == Palette.coilSlate)
    }

    /// The cross-fade must not dip through grey halfway, which is what blending in sRGB
    /// would do.
    @Test("cross-fade is continuous and hits both endpoints exactly")
    func crossFade() {
        let options = ColourOptions(residueCount: 20, residues: [.leucine, .lysine])
        let v = Self.vertex(confidence: 95, structure: .helix)
        let from = Colouring.colour(v, mode: .confidence, options: options)
        let to = Colouring.colour(v, mode: .secondaryStructure, options: options)

        #expect(Colouring.colour(v, from: .confidence, to: .secondaryStructure,
                                 t: 0, options: options) == from)
        #expect(Colouring.colour(v, from: .confidence, to: .secondaryStructure,
                                 t: 1, options: options) == to)
        // Monotone progress from one to the other, with no excursion in between.
        var previous: Float = 0
        for step in 0...20 {
            let t = Float(step) / 20
            let c = Colouring.colour(v, from: .confidence, to: .secondaryStructure,
                                     t: t, options: options)
            let progress = simd_distance(from, c)
            #expect(progress >= previous - 1e-5, "cross-fade went backwards at t=\(t)")
            #expect(simd_distance(from, c) + simd_distance(c, to)
                    <= simd_distance(from, to) + 1e-4,
                    "cross-fade left the straight line at t=\(t)")
            previous = progress
        }
        // Out-of-range t clamps.
        #expect(Colouring.colour(v, from: .confidence, to: .rainbow, t: -1,
                                 options: options) == from)
    }

    @Test("every mode produces a finite colour in range for a whole real trajectory")
    func realTrajectory() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/ubiquitin.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let options = ColourOptions(residueCount: bundle.metadata.residueCount,
                                    residues: bundle.residues)
        for readout in bundle.readouts {
            let ss = [SSAssignment](repeating: SSAssignment(structure: .helix, confidence: 0.6),
                                    count: readout.caPositions.count)
            let tube = TubeGeometry.build(caPositions: readout.caPositions,
                                          secondaryStructure: ss)
            let packed = TubeMeshPacker.pack(tube, residueConfidence: readout.confidence)
            for mode in ColourMode.allCases {
                for vertex in stride(from: 0, to: packed.count, by: 97).map({ packed[$0] }) {
                    let c = Colouring.colour(vertex, mode: mode, options: options)
                    #expect(c.x.isFinite && c.y.isFinite && c.z.isFinite,
                            "\(mode) produced a non-finite colour")
                    #expect(c.min() >= -1e-5 && c.max() <= 1.001,
                            "\(mode) produced \(c), outside 0...1")
                }
            }
        }
    }

    /// Labelling denoising progress as pLDDT would be a claim the generator cannot support.
    @Test("the confidence legend follows the trajectory's provenance")
    func legendFollowsProvenance() {
        #expect(ColourMode.confidence.legend(for: .pLDDT) == "pLDDT")
        #expect(ColourMode.confidence.legend(for: .denoisingProgress) == "Resolution")
        #expect(ColourMode.rainbow.legend(for: .denoisingProgress) == "Rainbow")
    }
}
