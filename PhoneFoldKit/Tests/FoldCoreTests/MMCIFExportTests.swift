import Testing
import Foundation
import simd
@testable import FoldCore

/// The mmCIF exports. PLAN.md's Phase 4 gate asks that the file parses and that a multi-model
/// trajectory opens in PyMOL, which means the model column has to be right and every row has
/// to have the column count its own header promises.
@Suite("mmCIF export")
struct MMCIFExportTests {

    static func frame(_ index: Int, residues n: Int = 6, offset: Float = 0,
                      confidence: Float = 88) -> FoldFrame {
        let backbone = (0..<n).map { i -> BackboneResidue in
            let ca = SIMD3<Float>(Float(i) * 3.8 + offset, offset, 0)
            return BackboneResidue(n: ca + SIMD3(-1.2, 0, 0), ca: ca,
                                   c: ca + SIMD3(1.2, 0, 0), o: ca + SIMD3(1.6, 1.0, 0))
        }
        return FoldFrame(index: index, recycle: 0, blockIndex: index, backbone: backbone,
                         pLDDT: (0..<n).map { confidence - Float($0) },
                         secondaryStructure: (0..<n).map {
                             _ in SSAssignment(structure: .coil, confidence: 1)
                         },
                         newContacts: [], radiusOfGyration: 10, meanPLDDT: confidence,
                         isInterpolated: false)
    }

    static let acids = "MKTAYI".map { AminoAcid(code: $0) }

    static var header: MMCIFExport.Header {
        MMCIFExport.Header(entryID: "TEST", title: "a test protein",
                           sequence: "MKTAYI", confidenceSource: .pLDDT,
                           disclosure: "Simulated toward a known structure; not a prediction.")
    }

    // MARK: - Round trip

    @Test("a single model round-trips with every atom and its B-factor")
    func singleModelRoundTrips() throws {
        let frame = Self.frame(0)
        let text = MMCIFExport.writeFinal(frame: frame, residues: Self.acids,
                                          header: Self.header)
        let parsed = try MMCIFExport.parse(text)
        #expect(parsed.entryID == "TEST")
        #expect(parsed.modelCount == 1)
        // Four backbone atoms a residue.
        #expect(parsed.atomCount == 6 * 4)

        let model = parsed.models[0]
        #expect(model.filter { $0.name == "CA" }.count == 6)
        // pLDDT lands in the B-factor column, which is what every viewer colours by.
        let alphaCarbons = model.filter { $0.name == "CA" }.sorted { $0.residue < $1.residue }
        for (index, atom) in alphaCarbons.enumerated() {
            #expect(abs(atom.b - (88 - Float(index))) < 0.01)
            #expect(abs(atom.position.x - Float(index) * 3.8) < 0.001)
        }
    }

    @Test("a trajectory becomes numbered models, which is how PyMOL reads states")
    func trajectoryBecomesModels() throws {
        let frames = (0..<5).map { Self.frame($0, offset: Float($0)) }
        let text = MMCIFExport.write(frames: frames, residues: Self.acids, header: Self.header)
        let parsed = try MMCIFExport.parse(text)
        #expect(parsed.modelCount == 5)
        #expect(parsed.atomCount == 5 * 6 * 4)
        // Model numbers are 1-based and in order: `load file.cif` gives one object with five
        // states, and a zero-based or shuffled column gives five objects or a scramble.
        for (index, model) in parsed.models.enumerated() {
            let firstCA = try #require(model.first { $0.name == "CA" && $0.residue == 0 })
            #expect(abs(firstCA.position.x - Float(index)) < 0.001)
        }
    }

    @Test("a trace-only fold writes alpha carbons, not three invented atoms")
    func backboneOnlyWritesWhatExists() throws {
        // A CA-trace provider has no real N, C or O - the frame fills them with the alpha
        // carbon's own position - so writing four atoms per residue would be inventing three.
        let text = MMCIFExport.write(frames: [Self.frame(0)], residues: Self.acids,
                                     header: Self.header, backboneOnly: true)
        let parsed = try MMCIFExport.parse(text)
        #expect(parsed.atomCount == 6)
        #expect(parsed.models[0].allSatisfy { $0.name == "CA" })
    }

    // MARK: - The things that break mmCIF readers

    @Test("every atom row has exactly the columns its header promises")
    func rowsMatchTheHeader() throws {
        let text = MMCIFExport.write(frames: [Self.frame(0)], residues: Self.acids,
                                     header: Self.header)
        let lines = text.split(separator: "\n").map(String.init)
        let headerCount = lines.filter { $0.hasPrefix("_atom_site.") }.count
        #expect(headerCount == MMCIFExport.atomSiteColumns)
        let atomRows = lines.filter { $0.hasPrefix("ATOM ") }
        #expect(!atomRows.isEmpty)
        for row in atomRows {
            let fields = row.split(separator: " ", omittingEmptySubsequences: true)
            // A row with the wrong count is the classic mmCIF failure, and it is silent: most
            // readers take the first n and leave the rest of the file misaligned.
            #expect(fields.count == headerCount, "row has \(fields.count) fields: \(row)")
        }
    }

    @Test("a title with spaces does not derail the parse")
    func titlesAreQuoted() throws {
        // An unquoted value containing a space changes the column count of its row, which is
        // how a file with a perfectly ordinary protein name stops parsing.
        let header = MMCIFExport.Header(entryID: "P0DTC2",
                                        title: "spike glycoprotein, chain A")
        let text = MMCIFExport.write(frames: [Self.frame(0)], residues: Self.acids,
                                     header: header)
        let parsed = try MMCIFExport.parse(text)
        #expect(parsed.atomCount == 24)
        #expect(parsed.entryID == "P0DTC2")
    }

    @Test("an entry id with whitespace is made safe rather than written as it stands")
    func entryIDIsSanitised() {
        // A data block name may not contain whitespace, and readers disagree about what to do
        // with one that does: some truncate, some refuse the file.
        let header = MMCIFExport.Header(entryID: "my protein", title: "x")
        #expect(header.entryID == "my_protein")
    }

    @Test("the file says what its B-factor column actually means")
    func confidenceSourceIsRecorded() throws {
        // Three of the four engines do not report pLDDT, and a number under the wrong name is
        // worse than no number: a reader colouring by "confidence" would be reading native
        // contact fraction or denoising progress and calling it a prediction's confidence.
        for source in ConfidenceSource.allCases {
            let header = MMCIFExport.Header(entryID: "T", title: "t", confidenceSource: source)
            let text = MMCIFExport.write(frames: [Self.frame(0)], residues: Self.acids,
                                         header: header)
            #expect(text.contains("B_iso_meaning"))
            #expect(text.contains(source.displayName))
        }
    }

    @Test("the provenance travels with the structure")
    func provenanceIsWritten() throws {
        let text = MMCIFExport.write(frames: [Self.frame(0)], residues: Self.acids,
                                     header: Self.header)
        // A structure that leaves the app without its provenance is one someone will later
        // mistake for a prediction.
        #expect(text.contains("provenance"))
        #expect(text.contains("not a prediction"))
        // And it still parses with that text field in it.
        #expect(try MMCIFExport.parse(text).atomCount == 24)
    }

    @Test("rubbish is refused, and says what was wrong")
    func malformedIsRefused() {
        #expect(throws: MMCIFExport.Malformed.noAtomSite) {
            try MMCIFExport.parse("data_X\n_entry.id X\n#\n")
        }
        // A row shorter than its header - an unquoted value with a space - must be a refusal
        // rather than a silently short-read atom.
        let short = """
        data_X
        loop_
        _atom_site.group_PDB
        _atom_site.label_atom_id
        _atom_site.label_seq_id
        _atom_site.Cartn_x
        _atom_site.Cartn_y
        _atom_site.Cartn_z
        _atom_site.B_iso_or_equiv
        _atom_site.pdbx_PDB_model_num
        ATOM CA 1 1.0 2.0
        #
        """
        #expect(throws: MMCIFExport.Malformed.self) { try MMCIFExport.parse(short) }
    }

    @Test("a long sequence is folded rather than written as one enormous line")
    func longSequencesAreFolded() throws {
        let sequence = String(repeating: "ACDEFGHIKL", count: 40)   // 400 residues
        let header = MMCIFExport.Header(entryID: "LONG", title: "long", sequence: sequence)
        let text = MMCIFExport.write(frames: [Self.frame(0)], residues: Self.acids,
                                     header: header)
        let longest = text.split(separator: "\n").map(\.count).max() ?? 0
        // Some readers still assume 80 columns, and a 400-character line is a file they
        // truncate rather than reject.
        #expect(longest <= 80, "longest line is \(longest) characters")
        #expect(try MMCIFExport.parse(text).atomCount == 24)
    }
}
