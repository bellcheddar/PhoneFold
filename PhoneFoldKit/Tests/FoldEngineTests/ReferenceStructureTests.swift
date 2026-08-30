import Testing
import Foundation
import simd
import FoldCore
@testable import FoldEngine

/// Parsing a reference structure, offline and deterministic.
///
/// The fixture is a real excerpt of AlphaFold's own mmCIF for P69905 (haemoglobin alpha),
/// trimmed to twelve residues, so this tests the format that actually ships rather than one
/// invented to suit the parser.
@Suite("Reference structure")
struct ReferenceStructureTests {

    static func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/alphafold_excerpt.cif")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Alpha carbons come out in order, with their residues and pLDDT")
    func parsesAlphaCarbons() throws {
        let residues = try MMCIFParser.alphaCarbons(try Self.fixture())
        #expect(residues.count == 12, "got \(residues.count) alpha carbons")
        // Haemoglobin alpha begins MVLSPADKTNVK.
        let sequence = String(residues.map { MMCIFParser.oneLetter($0.name) })
        #expect(sequence == "MVLSPADKTNVK", "sequence came out as \(sequence)")
        // In sequence order, and one per residue.
        #expect(residues.map(\.sequenceNumber) == Array(1...12))
        // The first CA of this file, read from the real line.
        #expect(abs(residues[0].position.x - 2.296) < 1e-9)
        #expect(abs(residues[0].position.y - 10.344) < 1e-9)
        #expect(abs(residues[0].position.z - 14.712) < 1e-9)
        // B-factor is pLDDT in an AlphaFold model, and must be in range.
        #expect(abs(residues[0].bFactor - 65.38) < 1e-4)
        #expect(residues.allSatisfy { $0.bFactor > 0 && $0.bFactor <= 100 })
        // Consecutive alpha carbons are one peptide bond apart.
        for i in 0..<(residues.count - 1) {
            let d = simd_length(residues[i + 1].position - residues[i].position)
            #expect(d > 3.6 && d < 4.0, "CA-CA \(i)-\(i+1) is \(d) A")
        }
    }

    /// The parser must take its column positions from the header, not from a fixed order.
    ///
    /// AlphaFold's files moved from `model_v4` to `model_v6` during this project, and a parser
    /// that counts fields from the left is one release away from reading the occupancy as a
    /// coordinate. This shuffles the declared order and requires the same answer.
    @Test("Column order is read from the header, not assumed")
    func columnOrderIsNotAssumed() throws {
        let original = try MMCIFParser.alphaCarbons(try Self.fixture())

        // Rebuild the fixture with two columns swapped, header and data together.
        let lines = try Self.fixture().split(whereSeparator: \.isNewline).map(String.init)
        var headers: [String] = []
        for line in lines where line.hasPrefix("_atom_site.") { headers.append(line) }
        let xIndex = headers.firstIndex { $0.contains("Cartn_x") }!
        let occupancyIndex = headers.firstIndex { $0.contains("occupancy") }!

        var rebuilt: [String] = []
        for line in lines {
            if line.hasPrefix("_atom_site.") {
                continue
            } else if line.hasPrefix("ATOM") {
                var fields = line.split(separator: " ").map(String.init)
                fields.swapAt(xIndex, occupancyIndex)
                rebuilt.append(fields.joined(separator: " "))
            } else {
                rebuilt.append(line)
            }
        }
        var swappedHeaders = headers
        swappedHeaders.swapAt(xIndex, occupancyIndex)
        let text = (["data_test", "loop_"] + swappedHeaders + rebuilt).joined(separator: "\n")

        let reparsed = try MMCIFParser.alphaCarbons(text)
        #expect(reparsed.count == original.count)
        for (a, b) in zip(reparsed, original) {
            #expect(simd_distance(a.position, b.position) < 1e-9,
                    "a shuffled column order changed the coordinates")
        }
    }

    @Test("A file with no alpha carbons is refused rather than returning nothing")
    func emptyFileIsRefused() {
        #expect(throws: MMCIFParser.Failure.self) {
            _ = try MMCIFParser.alphaCarbons("data_nothing\n#\n")
        }
    }

    /// A reference structure must be foldable: the engines take its coordinates as a target.
    @Test("A parsed reference drives an engine end to end")
    func referenceDrivesAnEngine() throws {
        let residues = try MMCIFParser.alphaCarbons(try Self.fixture())
        let reference = ReferenceStructure(
            accession: "P69905", name: "Haemoglobin subunit alpha",
            sequence: String(residues.map { MMCIFParser.oneLetter($0.name) }),
            caPositions: residues.map(\.position), pLDDT: residues.map(\.bFactor))
        #expect(reference.residueCount == 12)
        #expect(reference.residues.count == 12)

        let metadata = TrajectoryMetadata(
            name: reference.name, sequence: reference.sequence,
            accession: reference.accession,
            provenance: FoldingEngine.morph.provenance, sourceModel: "on-device",
            blocksPerReadout: 1, recycles: 1, generated: "2026-08-30T00:00:00Z")
        let bundle = try LiveTrajectory.fold(
            engine: .morph, native: reference.caPositions, metadata: metadata,
            residues: reference.residues, frameCount: 20)
        #expect(bundle.isConsistent)
        #expect(bundle.readouts.count == 20)
        #expect(bundle.metadata.accession == "P69905")
    }
}

/// The live client, against the real AlphaFold service.
///
/// **Opt-in, via `PHONEFOLD_NETWORK_TESTS=1`.** A test that reaches the internet is not a unit
/// test: it fails on a train, it fails when EBI is down, and a phase gate that goes red for
/// reasons unconnected to the code stops being read. The parser above covers the logic
/// offline; this covers the assumption that the service still answers the way it did.
@Suite("AlphaFold client", .enabled(if:
    ProcessInfo.processInfo.environment["PHONEFOLD_NETWORK_TESTS"] == "1"))
struct AlphaFoldClientTests {

    @Test("Fetches a real reference structure by accession", .timeLimit(.minutes(2)))
    func fetchesHaemoglobin() async throws {
        let client = AlphaFoldClient()
        let reference = try await client.reference(for: "P69905")
        #expect(reference.accession == "P69905")
        #expect(reference.residueCount == 142, "got \(reference.residueCount) residues")
        #expect(reference.sequence.hasPrefix("MVLSPADKTNVK"))
        #expect(reference.sequence.count == reference.caPositions.count)
        #expect(reference.pLDDT.allSatisfy { $0 > 0 && $0 <= 100 })
        // A real folded protein, not an extended chain.
        let centre = reference.caPositions.reduce(SIMD3<Double>.zero, +)
            / Double(reference.residueCount)
        let rg = (reference.caPositions.map { simd_length_squared($0 - centre) }.reduce(0, +)
                  / Double(reference.residueCount)).squareRoot()
        #expect(rg > 8 && rg < 25, "haemoglobin alpha should be compact, Rg was \(rg)")
    }

    @Test("An accession with no prediction is reported as such", .timeLimit(.minutes(2)))
    func unknownAccessionIsReported() async {
        let client = AlphaFoldClient()
        await #expect(throws: AlphaFoldClient.Failure.self) {
            _ = try await client.reference(for: "NOTANACCESSION")
        }
    }
}
