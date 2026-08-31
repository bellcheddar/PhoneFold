import Testing
import simd
@testable import FoldGeometry

/// PLAN.md Phase 5c: "look-and-pinch on a residue to pin a label and solo its note."
///
/// A headset decides whether the pinch *feels* accurate. Whether it picks the right residue is
/// arithmetic, and it is here.
@Suite("Which residue was pinched")
struct ResiduePickingTests {

    /// A short stretch of chain along x at the usual 3.8 A CA-CA spacing.
    static var chain: [SIMD3<Float>] {
        (0..<8).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
    }

    @Test("a pinch on a residue picks that residue")
    func exactHit() {
        #expect(ResiduePicking.residue(at: SIMD3(3.8 * 3, 0, 0), in: Self.chain) == 3)
        #expect(ResiduePicking.residue(at: SIMD3(0, 0, 0), in: Self.chain) == 0)
        #expect(ResiduePicking.residue(at: SIMD3(3.8 * 7, 0, 0), in: Self.chain) == 7)
    }

    @Test("a pinch near a residue picks the nearest one")
    func nearestWins() {
        // Between residues 4 and 5, a shade closer to 4.
        #expect(ResiduePicking.residue(at: SIMD3(3.8 * 4 + 1.5, 0, 0), in: Self.chain) == 4)
        #expect(ResiduePicking.residue(at: SIMD3(3.8 * 4 + 2.5, 0, 0), in: Self.chain) == 5)
    }

    /// The one that stops a label appearing where nobody pointed. A protein is mostly empty
    /// space at this scale and a pinch into a hollow is a pinch at nothing.
    @Test("a pinch into empty space picks nothing rather than the least far residue")
    func missesAreNil() {
        #expect(ResiduePicking.residue(at: SIMD3(0, 40, 0), in: Self.chain) == nil)
        #expect(ResiduePicking.residue(at: SIMD3(-30, 0, 0), in: Self.chain) == nil)
        // Just outside the tolerance, on an axis with nothing on it.
        #expect(ResiduePicking.residue(at: SIMD3(0, 6.5, 0), in: Self.chain) == nil)
        #expect(ResiduePicking.residue(at: SIMD3(0, 5.5, 0), in: Self.chain) == 0)
    }

    /// A symmetric structure genuinely puts two residues the same distance from a pinch.
    /// Answering with whichever the loop reached last would make the label flicker.
    @Test("a tie is broken by the earlier residue, every time")
    func tiesAreStable() {
        let pair = [SIMD3<Float>(-2, 0, 0), SIMD3<Float>(2, 0, 0)]
        #expect(ResiduePicking.residue(at: .zero, in: pair) == 0)
        #expect(ResiduePicking.residue(at: .zero, in: pair.reversed()) == 0)
    }

    @Test("an empty structure and a nonsense point both pick nothing")
    func degenerate() {
        #expect(ResiduePicking.residue(at: .zero, in: []) == nil)
        #expect(ResiduePicking.residue(at: SIMD3(.nan, 0, 0), in: Self.chain) == nil)
        #expect(ResiduePicking.residue(at: SIMD3(.infinity, 0, 0), in: Self.chain) == nil)
        #expect(ResiduePicking.residue(at: .zero, in: Self.chain, tolerance: 0) == nil)
    }

    /// The tolerance is a real number with a reason: 6 A clears the tube's own radius with
    /// slack, and stays under the ~4.8 A between neighbouring strands of a beta sheet plus
    /// that slack, so a pinch between two strands does not silently take one.
    @Test("the tolerance does not reach across a sheet")
    func toleranceIsHonest() {
        #expect(ResiduePicking.defaultTolerance > 2, "a tube is about 2 A in radius")
        #expect(ResiduePicking.defaultTolerance < 9.6, "twice the spacing between strands")
    }
}
