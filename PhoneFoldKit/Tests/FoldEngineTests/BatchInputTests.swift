import Testing
import Foundation
@testable import FoldEngine

@Suite("Batch input: what an overnight run is asked to fold")
struct BatchInputTests {

    // MARK: - Accession recognition

    @Test("UniProt's own accession shapes are accepted")
    func realAccessions() {
        for accession in ["P69905", "Q9Y6K9", "O00303", "A0A022YWF9", "P0DTD1", "P69905-2"] {
            #expect(BatchInput.isAccession(accession), "\(accession) is a real accession")
        }
    }

    /// The point of using UniProt's published pattern rather than "six alphanumerics": every
    /// one of these appears in a real FASTA header, and a loose pattern turns each into a
    /// network round trip that 404s and looks like the database's fault.
    @Test("Header words that are not accessions are rejected")
    func notAccessions() {
        for token in ["HBA_HUMAN", "sp", "tr", "Haemoglobin", "MVLSPADKTN", "1UBQ", ""] {
            #expect(!BatchInput.isAccession(token), "\(token) is not a UniProt accession")
        }
    }

    /// The second identifier kind. `1UBQ` is not a UniProt accession and is a perfectly good
    /// PDB id, which is what the bundled trajectories are keyed by and what a structural
    /// biologist usually has to hand.
    @Test("PDB entry ids are recognised as their own kind")
    func pdbIdentifiers() {
        for token in ["1UBQ", "6VXX", "1UBQ_1", "6VXX_A", "7A4M-1"] {
            #expect(BatchInput.isPDBIdentifier(token), "\(token) is a PDB id")
            #expect(BatchInput.kind(of: token) == .pdb)
        }
        for token in ["UBQ1", "ABCD", "HBA_HUMAN", "P69905", ""] {
            #expect(!BatchInput.isPDBIdentifier(token), "\(token) is not a PDB id")
        }
    }

    /// The two kinds resolve from different places, so the parser has to say which it saw.
    @Test("A mixed list keeps each record's kind")
    func mixedKinds() {
        let input = BatchInput.parse("P69905\n1UBQ_1")
        #expect(input.items.map(\.kind) == [.uniProt, .pdb])
    }

    // MARK: - FASTA

    @Test("A UniProt FASTA yields accession, entry name and sequence")
    func uniProtFASTA() throws {
        let text = """
            >sp|P69905|HBA_HUMAN Haemoglobin subunit alpha OS=Homo sapiens
            MVLSPADKTNVKAAWGKVGAHAGEYGAEALERMFLSFPTTKTYFPHFDLSHGSAQVKGHGK
            KVADALTNAVAHVDDMPNALSALSDLHAHKLRVDPVNFKLLSHCLLVTLAAHLPAEFTPAV
            >sp|P68871|HBB_HUMAN Haemoglobin subunit beta
            MVHLTPEEKSAVTALWGKVNVDEVGGEALGRLLVVYPWTQRFFESFGDLSTPDAVMGNPKV
            """
        let input = BatchInput.parse(text)
        #expect(input.rejections.isEmpty)
        #expect(input.items.count == 2)
        #expect(input.items[0].accession == "P69905")
        #expect(input.items[0].label == "HBA_HUMAN")
        #expect(input.items[0].sequence.hasPrefix("MVLSPADKTN"))
        #expect(input.items[0].sequence.count == 122, "both sequence lines are joined")
        #expect(input.items[1].accession == "P68871")
    }

    @Test("A bare accession header works, with or without a description")
    func bareHeaders() {
        let input = BatchInput.parse(">P69905\nMVLS\n>P68871 Haemoglobin subunit beta\nMVHL")
        #expect(input.items.map(\.accession) == ["P69905", "P68871"])
        #expect(input.items[0].label == nil)
    }

    /// The failure this is designed to name out loud. A FASTA of designed sequences has no
    /// accession anywhere, and PhoneFold has no sequence-to-structure model to fall back on.
    @Test("A FASTA with no accessions is rejected with the reason, not silently emptied")
    func fastaWithoutAccessions() {
        let input = BatchInput.parse(">design_01 round 3\nMVLSPADK\n>design_02\nMVHLTPEE")
        #expect(input.items.isEmpty)
        #expect(input.rejections.count == 2)
        #expect(input.rejections[0].reason.contains("no UniProt accession or PDB id"))
        #expect(input.rejections[0].line == 1, "the header's own line number")
    }

    @Test("Digits and whitespace in the sequence body are dropped")
    func sequenceIsResiduesOnly() {
        let input = BatchInput.parse(">sp|P69905|HBA_HUMAN\n  1 MVLS PADK  \n 61 TNVK \n")
        #expect(input.items.first?.sequence == "MVLSPADKTNVK")
    }

    // MARK: - Plain lists

    @Test("One accession per line, with comments and blanks")
    func plainList() {
        let input = BatchInput.parse("""
            # tonight's batch
            P69905

            P68871   # haemoglobin beta
            """)
        #expect(input.items.map(\.accession) == ["P69905", "P68871"])
        #expect(input.rejections.isEmpty)
        #expect(input.items[0].sequence.isEmpty, "a list carries no sequence to check")
    }

    @Test("A list line that is not an accession is rejected with its line number")
    func listRejection() {
        let input = BatchInput.parse("P69905\nhaemoglobin\nP68871")
        #expect(input.items.count == 2)
        #expect(input.rejections.count == 1)
        #expect(input.rejections[0].line == 2)
        #expect(input.rejections[0].reason.contains("haemoglobin"))
    }

    @Test("Lowercase accessions are accepted and normalised")
    func lowercase() {
        #expect(BatchInput.parse("p69905").items.first?.accession == "P69905")
    }

    // MARK: - Duplicates

    /// An overnight batch that folds the same protein twice has wasted an hour of the night,
    /// and a list pasted together from two sources overlaps more often than not.
    @Test("Repeats are dropped, the first is kept, and the drop is reported")
    func duplicates() {
        let input = BatchInput.parse("P69905\nP68871\nP69905")
        #expect(input.items.map(\.accession) == ["P69905", "P68871"])
        #expect(input.rejections.count == 1)
        #expect(input.rejections[0].reason.contains("repeated"))
    }

    // MARK: - The gate's own shape

    /// PLAN's machine gate for 5a: "batch mode processes a 5-record FASTA headlessly."
    @Test("A five-record FASTA parses to five items")
    func fiveRecords() {
        let text = ["P69905", "P68871", "P0DTD1", "Q9Y6K9", "O00303"]
            .map { ">sp|\($0)|TEST_\($0) a record\nMVLSPADKTNVKAAWGKVGAHAGEYGAEALERMFLSFPTTK" }
            .joined(separator: "\n")
        let input = BatchInput.parse(text)
        #expect(input.items.count == 5)
        #expect(input.rejections.isEmpty)
    }

    @Test("An empty file is empty rather than an error")
    func empty() {
        #expect(BatchInput.parse("").items.isEmpty)
        #expect(BatchInput.parse("\n\n  \n").items.isEmpty)
    }
}
