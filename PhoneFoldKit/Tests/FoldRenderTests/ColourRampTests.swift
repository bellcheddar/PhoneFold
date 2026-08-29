import Testing
import Foundation
import simd
import FoldCore
@testable import FoldRender

/// The ramp texture has to agree with `Colouring`, because it replaces it on screen.
@Suite("Colour ramp")
struct ColourRampTests {

    static let options = ColourOptions(residueCount: 76)

    static func texel(_ pixels: [UInt8], row: Int, u: Float) -> SIMD3<Int> {
        let column = Int((u * Float(ColourRamp.width - 1)).rounded())
        let offset = (row * ColourRamp.width + column) * 4
        return SIMD3<Int>(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    static func distance(_ a: SIMD3<Int>, _ hex: Int) -> Int {
        let want = SIMD3<Int>((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF)
        return abs(a.x - want.x) + abs(a.y - want.y) + abs(a.z - want.z)
    }

    /// Every structure must reach its own colour at full confidence. A row that never gets
    /// there means that structure is invisible on screen, which is exactly how a missing
    /// strand shows up.
    @Test("Each structure's row reaches its palette colour")
    func rowsReachTheirColours() {
        let pixels = ColourRamp.texels(mode: .secondaryStructure, options: Self.options)
        for structure in [SecondaryStructure.coil, .helix, .sheet] {
            let row = Int(structure.rawValue)
            let full = Self.texel(pixels, row: row, u: 1)
            let expected = Colouring.colour(
                ColourRamp.sample(u: 1, row: row, residueCount: 76),
                mode: .secondaryStructure, options: Self.options)
            let want = SIMD3<Int>(Int(ColourRamp.encode(expected.x)),
                                  Int(ColourRamp.encode(expected.y)),
                                  Int(ColourRamp.encode(expected.z)))
            #expect(Self.distance(full, (want.x << 16) | (want.y << 8) | want.z) <= 3,
                    "\(structure) row is \(full), Colouring says \(want)")
        }
        // And they must be different from each other, or the mode says nothing.
        let helix = Self.texel(pixels, row: Int(SecondaryStructure.helix.rawValue), u: 1)
        let sheet = Self.texel(pixels, row: Int(SecondaryStructure.sheet.rawValue), u: 1)
        let coil = Self.texel(pixels, row: Int(SecondaryStructure.coil.rawValue), u: 1)
        #expect(Self.distance(helix, (sheet.x << 16) | (sheet.y << 8) | sheet.z) > 100)
        #expect(Self.distance(helix, (coil.x << 16) | (coil.y << 8) | coil.z) > 100)
        #expect(Self.distance(sheet, (coil.x << 16) | (coil.y << 8) | coil.z) > 100)
    }

    /// A vertex must look up the texel that holds its own colour. If the coordinate and the
    /// texture disagree the protein is still drawn, just in the wrong colours.
    @Test("A vertex's coordinate finds its own colour, in every mode")
    func coordinateAgreesWithColouring() {
        let residues = [AminoAcid](repeating: .leucine, count: 76)
        let options = ColourOptions(residueCount: 76, residues: residues)
        for mode in [ColourMode.confidence, .secondaryStructure, .rainbow, .hydrophobicity] {
            let pixels = ColourRamp.texels(mode: mode, options: options)
            for structure in [SecondaryStructure.coil, .helix, .sheet] {
                for step in 0...10 {
                    let u = Float(step) / 10
                    var vertex = ColourRamp.sample(u: u, row: Int(structure.rawValue),
                                                   residueCount: 76)
                    let expected = Colouring.colour(vertex, mode: mode, options: options)
                    vertex.rampCoordinate = ColourRamp.coordinate(for: vertex, mode: mode,
                                                                  options: options)
                    let row = Int((vertex.rampCoordinate.y * Float(ColourRamp.height)
                                   - 0.5).rounded())
                    let found = Self.texel(pixels, row: row, u: vertex.rampCoordinate.x)
                    let want = SIMD3<Int>(Int(ColourRamp.encode(expected.x)),
                                          Int(ColourRamp.encode(expected.y)),
                                          Int(ColourRamp.encode(expected.z)))
                    let d = abs(found.x - want.x) + abs(found.y - want.y) + abs(found.z - want.z)
                    #expect(d <= 6, "\(mode) \(structure) at u=\(u): ramp \(found), Colouring \(want)")
                }
            }
        }
    }

    /// The whole point: no staircase.
    ///
    /// A staircase is *many* steps of a similar size - the screenshot that started this had 26
    /// of them along one strand ribbon, about 10 apart on this scale. What the ramp does have
    /// is a handful of small slope changes where the AlphaFold pLDDT palette turns a corner:
    /// its worst is 8, at u = 0.60, and that palette is piecewise on purpose, because the
    /// bands are what make it readable at a glance. So this checks both, and the count is the
    /// one that matters.
    @Test("The ramp has no staircase in it")
    func rampIsContinuous() {
        for mode in [ColourMode.confidence, .secondaryStructure, .rainbow, .hydrophobicity] {
            let pixels = ColourRamp.texels(mode: mode, options: Self.options)
            var worst = 0
            var noticeable = 0
            for row in 0..<ColourRamp.height {
                for column in 1..<ColourRamp.width {
                    let a = (row * ColourRamp.width + column - 1) * 4
                    let b = (row * ColourRamp.width + column) * 4
                    let step = abs(Int(pixels[a]) - Int(pixels[b]))
                        + abs(Int(pixels[a + 1]) - Int(pixels[b + 1]))
                        + abs(Int(pixels[a + 2]) - Int(pixels[b + 2]))
                    worst = Swift.max(worst, step)
                    if step > 4 { noticeable += 1 }
                }
            }
            #expect(worst <= 10, "\(mode) steps by \(worst) between neighbouring texels")
            // Set from what separates the two things, not from the number that came out.
            // A mode has 3 rows of 1024 texels. The quantiser this replaced used 48 levels,
            // so a staircase puts a step at every level boundary: on the order of 47 per row,
            // 141 per mode, or 4.6% of the texels. The palette's own corners are a handful:
            // 18 in the worst mode, 0.6%. One percent sits between them with room either way.
            let budget = ColourRamp.width * ColourRamp.height / 100
            #expect(noticeable <= budget,
                    "\(mode) has \(noticeable) noticeable steps of \(budget) allowed: a staircase, not a palette corner")
        }
    }
}
