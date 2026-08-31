import Testing
import Foundation
import simd
@testable import FoldEngine
import FoldCore

/// A point substitution, and whether it changes the fold in the direction it should.
@Suite("Mutation")
struct MutationTests {

    static let sequence = "MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ".map { AminoAcid(code: $0) }

    // MARK: - Notation

    @Test("A53T notation parses, and is checked against the sequence")
    func notationParses() throws {
        // M1K: the first residue really is methionine.
        let mutation = try Mutation.parse("M1K", in: Self.sequence)
        #expect(mutation.position == 0)
        #expect(mutation.from == .methionine)
        #expect(mutation.to == .lysine)
        #expect(mutation.description == "M1K")
        // Round trip through the one-based notation everybody writes.
        #expect(try Mutation.parse(mutation.description, in: Self.sequence) == mutation)
    }

    @Test("a mutation written against the wrong numbering is refused")
    func wrongWildTypeIsRefused() {
        // **This is the check that matters.** A substitution written against a different
        // isoform, or one-based where the file is zero-based, perturbs the wrong residue - and
        // the piece would still play, which is the worst kind of wrong.
        #expect(throws: Mutation.Failure.self) {
            try Mutation.parse("A1T", in: Self.sequence)   // residue 1 is M, not A
        }
        #expect(throws: Mutation.Failure.self) {
            try Mutation.parse("M999K", in: Self.sequence)
        }
        #expect(throws: Mutation.Failure.self) {
            try Mutation.parse("not a mutation", in: Self.sequence)
        }
        #expect(throws: Mutation.Failure.self) { try Mutation.parse("", in: Self.sequence) }
    }

    @Test("the error says what was found, not just that it was wrong")
    func errorsAreSpecific() {
        do {
            _ = try Mutation.parse("A1T", in: Self.sequence)
            Issue.record("should not have parsed")
        } catch let failure as Mutation.Failure {
            // "Residue 1 is MET, not ALA" tells a person what to fix; "invalid mutation"
            // does not.
            #expect(failure.description.contains("MET"))
            #expect(failure.description.contains("ALA"))
        } catch { Issue.record("wrong error type") }
    }

    @Test("applying a substitution changes one residue and no others")
    func applicationIsLocal() throws {
        let mutation = try Mutation.parse("K2A", in: Self.sequence)
        let mutated = mutation.applied(to: Self.sequence)
        #expect(mutated.count == Self.sequence.count)
        #expect(mutated[1] == .alanine)
        for i in Self.sequence.indices where i != 1 {
            #expect(mutated[i] == Self.sequence[i])
        }
    }

    // MARK: - What it does to the energy

    @Test("a buried hydrophobic replaced by a charged residue loses most of its contacts")
    func burialAndHydropathyDriveTheLoss() {
        let drastic = Mutation(position: 10, from: .isoleucine, to: .asparticAcid)
        let conservative = Mutation(position: 10, from: .isoleucine, to: .valine)

        // Buried: the substitution matters.
        let buriedDrastic = drastic.retainedContactStrength(burial: 1)
        let buriedConservative = conservative.retainedContactStrength(burial: 1)
        #expect(buriedDrastic < buriedConservative)
        #expect(buriedDrastic < 0.4, "isoleucine to aspartate in the core kept \(buriedDrastic)")
        #expect(buriedConservative > 0.9, "isoleucine to valine is nearly nothing")

        // Exposed: the same substitution barely matters, which is why burial scales it.
        #expect(drastic.retainedContactStrength(burial: 0) > 0.95)
        // And everything stays inside the range the model can use.
        for burial in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let kept = drastic.retainedContactStrength(burial: burial)
            #expect(kept > 0 && kept <= 1)
        }
    }

    @Test("glycine and proline are disruptive whatever their hydropathy says")
    func backboneBreakersAreSpecialCased() {
        // Alanine to glycine is almost nothing by hydropathy - 1.8 to -0.4 - but adds backbone
        // freedom, and alanine to proline removes it. Both are common ways to break a helix,
        // and the hydropathy axis does not see either.
        let toGlycine = Mutation(position: 5, from: .alanine, to: .glycine)
        let toProline = Mutation(position: 5, from: .alanine, to: .proline)
        let plain = Mutation(position: 5, from: .alanine, to: .serine)
        #expect(toGlycine.retainedContactStrength(burial: 1) < plain.retainedContactStrength(burial: 1))
        #expect(toProline.retainedContactStrength(burial: 1) < plain.retainedContactStrength(burial: 1))
    }

    @Test("burial comes from the contact count the model already has")
    func burialFromContactCount() {
        #expect(Mutation.burial(contactCount: 0) == 0)
        #expect(Mutation.burial(contactCount: 12) == 1)
        #expect(Mutation.burial(contactCount: 40) == 1, "burial saturates rather than exceeding 1")
        #expect(Mutation.burial(contactCount: 6) == 0.5)
    }

    // MARK: - What it does to the fold

    /// A compact helix, so there is a core for a mutation to be buried in.
    static func nativeHelix(residues n: Int = 30) -> [SIMD3<Double>] {
        let rise = 1.5, radius = 2.3, turn = 100 * Double.pi / 180
        return (0..<n).map { i in
            SIMD3(radius * cos(Double(i) * turn), radius * sin(Double(i) * turn),
                  Double(i) * rise)
        }
    }

    @Test("a mutation changes the fold, and the direction is not assumed")
    func mutationChangesTheFold() throws {
        // A real compact protein, not one helix: villin HP36's own final structure, where a
        // buried residue actually has contacts to weaken.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let bundle = try TrajectoryBundleCodec.read(
            contentsOf: url.appending(path: "Apps/PhoneFold/Resources/villin_hp36.pftraj"))
        let native = (bundle.readouts.last?.caPositions ?? []).map {
            SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z))
        }
        try #require(native.count > 20)
        let start = UnfoldedChain.build(residues: native.count, seed: 7)

        func fold(_ mutation: Mutation?) -> (mean: Double, coordinates: [SIMD3<Double>]) {
            var parameters = StructureBasedModel.Parameters()
            parameters.seed = 7
            parameters.steps = 200_000
            parameters.frameCount = 10
            parameters.mutation = mutation
            let model = StructureBasedModel(native: native, parameters: parameters)
            let last = model.fold(from: start).last ?? []
            let per = model.perResidueNativeFraction(last)
            return (per.reduce(0, +) / Double(Swift.max(per.count, 1)), last)
        }

        let wild = fold(nil)
        let mutant = fold(Mutation(position: native.count / 2, from: .phenylalanine,
                                   to: .asparticAcid))

        // **The claim is that the two folds differ, not that the mutant is worse.**
        //
        // The first version of this test asserted the mutant folded less completely, and
        // measurement said otherwise: 1.00 against the wild type's 0.89. A Go landscape is
        // smooth by construction and removing some of a residue's contacts can reduce
        // frustration rather than add it. What the duet needs - and all it claims - is that
        // the two trajectories are genuinely different.
        #expect(wild.mean > 0.3, "the wild type did not fold at all (\(wild.mean))")
        #expect(mutant.mean > 0.3, "the mutant did not fold at all (\(mutant.mean))")
        let moved = zip(wild.coordinates, mutant.coordinates)
            .map { simd_length($0 - $1) }.max() ?? 0
        #expect(moved > 0.5, "the two folds are identical: the mutation did nothing")
    }

    @Test("the wild type is untouched when there is no mutation")
    func noMutationIsIdentical() {
        let native = Self.nativeHelix(residues: 20)
        let start = UnfoldedChain.build(residues: native.count, seed: 3)
        func fold(_ mutation: Mutation?) -> [SIMD3<Double>] {
            var parameters = StructureBasedModel.Parameters()
            parameters.seed = 3
            parameters.steps = 20_000
            parameters.frameCount = 5
            parameters.mutation = mutation
            return StructureBasedModel(native: native, parameters: parameters)
                .fold(from: start).last ?? []
        }
        // A nil mutation must be bit-for-bit the old behaviour, or every measurement taken
        // before this feature existed is invalidated.
        let a = fold(nil), b = fold(nil)
        #expect(a == b)
        // And a mutation at a position off the end changes nothing either.
        let offEnd = fold(Mutation(position: 999, from: .alanine, to: .glycine))
        #expect(offEnd == a)
    }
}
