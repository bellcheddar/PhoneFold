import Testing
import Foundation
import simd
@testable import FoldCore

@Suite("Reading a real structure file from the PDB")
struct RealStructureFileTests {

    static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The parser was written for our own exports and for the Biotite round-trip. Whether it
    /// reads a file the RCSB actually serves is a different question, and P5-06 depends on the
    /// answer.
    @Test("the mmCIF reader parses 1UBQ as served by the RCSB")
    func realMMCIF() throws {
        let parsed = try MMCIFExport.parse(try Self.fixture("1ubq.cif"))
        #expect(parsed.models.count >= 1)
        let first = try #require(parsed.models.first)
        // Ubiquitin is 76 residues; the file also carries waters, which are HETATM.
        let ca = first.filter { $0.name == "CA" }
        #expect(ca.count == 76, "got \(ca.count) alpha carbons")
        // The first alpha carbon of MET 1, read off the file by eye.
        let firstCA = try #require(ca.first)
        #expect(abs(firstCA.position.x - 26.266) < 0.01, "x was \(firstCA.position.x)")
    }

    /// The two formats have opposite rules and the same file underneath, so reading both and
    /// comparing them is the strongest check available without a third-party parser.
    @Test("PDB and mmCIF of the same entry agree, residue for residue")
    func formatsAgree() throws {
        let cif = try StructureFile.read(try Self.fixture("1ubq.cif"), identifier: "1UBQ")
        let pdb = try StructureFile.read(try Self.fixture("1ubq.pdb"), identifier: "1UBQ")

        #expect(cif.residues.count == 76)
        #expect(pdb.residues.count == 76)
        #expect(cif.residues.map(\.number) == pdb.residues.map(\.number))
        #expect(cif.residues.map(\.name) == pdb.residues.map(\.name))
        #expect(cif.chains == ["A"])

        // Same coordinates, to the precision the files are written at.
        for (a, b) in zip(cif.residues, pdb.residues) {
            #expect(simd_distance(a.ca, b.ca) < 0.001,
                    "residue \(a.number) differs between the two formats")
        }
    }

    /// The trap this parser is written around. In a PDB file the element symbol is right
    /// justified in columns 13 and 14, so an alpha carbon is " CA " and a calcium ion is
    /// "CA  ". Trimming both gives "CA" and turns every calcium into a residue.
    @Test("a calcium ion is not read as an alpha carbon")
    func calciumIsNotCarbonAlpha() throws {
        let pdb = """
            ATOM      1  CA  MET A   1      27.340  24.430   2.614  1.00  9.67           C
            ATOM      2 CA    CA  A   2      10.000  10.000  10.000  1.00 20.00          CA
            """
        let structure = try StructureFile.read(pdb, identifier: "TEST")
        #expect(structure.residues.count == 1, "the calcium must not become a residue")
        #expect(structure.residues.first?.name == "MET")
    }

    /// An NMR ensemble has dozens of models; "the structure" means the first.
    @Test("only the first model is read")
    func firstModelOnly() throws {
        let pdb = """
            MODEL        1
            ATOM      1  CA  MET A   1      27.340  24.430   2.614  1.00  9.67           C
            ENDMDL
            MODEL        2
            ATOM      2  CA  MET A   1       0.000   0.000   0.000  1.00  9.67           C
            ENDMDL
            """
        let structure = try StructureFile.read(pdb, identifier: "TEST")
        #expect(structure.residues.count == 1)
        #expect(abs((structure.residues.first?.ca.x ?? 0) - 27.340) < 0.001)
    }

    /// Two alternate locations for one residue are one residue, not two, or every comparison
    /// downstream is off by one from that point on.
    @Test("alternate locations do not duplicate a residue")
    func alternateLocations() throws {
        let pdb = """
            ATOM      1  CA AMET A   1      27.340  24.430   2.614  0.60  9.67           C
            ATOM      2  CA BMET A   1      27.500  24.500   2.700  0.40  9.67           C
            """
        let structure = try StructureFile.read(pdb, identifier: "TEST")
        #expect(structure.residues.count == 1)
        #expect(abs((structure.residues.first?.ca.x ?? 0) - 27.340) < 0.001, "the A location")
    }

    @Test("a file with no protein is refused with a reason")
    func noAlphaCarbons() throws {
        #expect(throws: StructureFile.Failure.self) {
            _ = try StructureFile.read("HETATM 1  O   HOH A 1  0.0 0.0 0.0", identifier: "X")
        }
    }
}
