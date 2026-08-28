import Testing
import Foundation
@testable import FoldCore

@Suite("FASTA parsing")
struct FASTAParsingTests {

    @Test("a bare sequence with no header parses")
    func bareSequence() throws {
        let s = try FASTA.parseOne("MKVFGRCELA")
        #expect(s.letters == "MKVFGRCELA")
        #expect(s.header.isEmpty)
        #expect(s.count == 10)
    }

    @Test("wrapped lines are joined")
    func wrappedLines() throws {
        let s = try FASTA.parseOne(">test\nMKVFG\nRCELA\nAAMKR\n")
        #expect(s.letters == "MKVFGRCELAAAMKR")
        #expect(s.header == "test")
    }

    @Test("carriage returns from Windows files are handled")
    func crlf() throws {
        let s = try FASTA.parseOne(">test\r\nMKVFG\r\nRCELA\r\n")
        #expect(s.letters == "MKVFGRCELA")
        #expect(s.header == "test")
    }

    @Test("lower case is upper-cased")
    func lowerCase() throws {
        #expect(try FASTA.parseOne("mkvfgrcela").letters == "MKVFGRCELA")
    }

    @Test("gaps, stops and whitespace are stripped",
          arguments: ["MKV-FGR-CELA", "MKV.FGR.CELA", "MKVFGRCELA*", "MKV FGR\tCELA"])
    func stripping(input: String) throws {
        #expect(try FASTA.parseOne(input).letters == "MKVFGRCELA")
    }

    /// A sequence with a B in it should still fold. Ambiguity codes are kept and resolve to
    /// AminoAcid.unknown rather than being rejected or silently deleted.
    @Test("ambiguity codes are kept, not rejected")
    func ambiguityCodes() throws {
        let s = try FASTA.parseOne("MKBZJXUOA")
        #expect(s.letters == "MKBZJXUOA")
        #expect(s.residues[2] == .unknown)   // B
        #expect(s.residues[0] == .methionine)
    }

    @Test("multi-record files return every record")
    func multiRecord() throws {
        let all = try FASTA.parse(">one\nMKVF\n>two\nGRCE\n>three\nLAAA\n")
        #expect(all.count == 3)
        #expect(all.map(\.header) == ["one", "two", "three"])
        #expect(all.map(\.letters) == ["MKVF", "GRCE", "LAAA"])
    }

    @Test("blank lines between records are ignored")
    func blankLines() throws {
        let all = try FASTA.parse("\n\n>one\n\nMKVF\n\n\n>two\nGRCE\n\n")
        #expect(all.map(\.letters) == ["MKVF", "GRCE"])
    }

    // Error cases. These messages are shown to a user, so they are asserted, not just the
    // error kind: PLAN.md asks for helpful validation errors.

    @Test("empty input is rejected")
    func emptyInput() {
        #expect(throws: FASTAError.empty) { try FASTA.parse("") }
        #expect(throws: FASTAError.empty) { try FASTA.parse("   \n\n  ") }
    }

    @Test("a header with no residues is rejected by name")
    func headerWithoutResidues() {
        #expect(throws: FASTAError.noResidues(header: "lonely")) {
            try FASTA.parse(">lonely\n")
        }
        #expect(FASTAError.noResidues(header: "lonely").description
                == "The record \"lonely\" has a header but no residues under it.")
    }

    @Test("digits and punctuation are rejected, and named in the message")
    func unexpectedCharacters() throws {
        #expect(throws: (any Error).self) { try FASTA.parse(">x\nMKV1FGR\n") }
        do {
            _ = try FASTA.parse(">x\nMKV1FGR@\n")
            Issue.record("should have thrown")
        } catch let error as FASTAError {
            guard case .unexpectedCharacters(let chars, let header) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(chars == ["1", "@"])
            #expect(header == "x")
            #expect(error.description.contains("\"1\""))
            #expect(error.description.contains("\"@\""))
        }
    }

    /// A common real mistake: pasting a nucleotide sequence. It parses as a protein of
    /// alanine, cysteine, glycine and threonine, which is legitimate but almost never meant.
    /// This documents that we do NOT reject it, so the behaviour is deliberate.
    @Test("a DNA sequence parses as protein, deliberately")
    func dnaParsesAsProtein() throws {
        let s = try FASTA.parseOne("ATGGCGTAAC")
        #expect(s.letters == "ATGGCGTAAC")
    }
}

@Suite("Sequence validation and formatting")
struct SequenceValidationTests {

    @Test("length limits are enforced with a readable message")
    func lengthLimits() {
        let tiny = ProteinSequence(letters: "MKV")
        #expect(throws: FASTAError.tooShort(count: 3, minimum: 8)) {
            try FASTA.validate(tiny, maximum: 256)
        }
        #expect(FASTAError.tooShort(count: 3, minimum: 8).description
                == "A protein needs at least 8 residues to fold; this has 3.")

        let huge = ProteinSequence(letters: String(repeating: "A", count: 400))
        #expect(throws: FASTAError.tooLong(count: 400, maximum: 256)) {
            try FASTA.validate(huge, maximum: 256)
        }
    }

    @Test("a sequence at each boundary is accepted")
    func boundaries() throws {
        try FASTA.validate(ProteinSequence(letters: String(repeating: "A", count: 8)),
                           maximum: 256)
        try FASTA.validate(ProteinSequence(letters: String(repeating: "A", count: 256)),
                           maximum: 256)
    }

    @Test("UniProt headers yield accession, protein name and organism")
    func uniProtHeader() {
        let s = ProteinSequence(
            header: "sp|P37840|SYUA_HUMAN Alpha-synuclein OS=Homo sapiens OX=9606 GN=SNCA PE=1 SV=1",
            letters: "MDVFMKGLSK")
        #expect(s.accession == "P37840")
        #expect(s.proteinName == "Alpha-synuclein")
        #expect(s.organism == "Homo sapiens")
    }

    @Test("a non-UniProt header yields nil rather than nonsense")
    func plainHeader() {
        let s = ProteinSequence(header: "my protein", letters: "MDVFMKGLSK")
        #expect(s.accession == nil)
        #expect(s.organism == nil)
    }

    @Test("formatting wraps at 60 columns and round-trips")
    func formatting() throws {
        let letters = String(repeating: "MKVFGRCELA", count: 15)   // 150 residues
        let original = ProteinSequence(header: "round trip", letters: letters)
        let text = FASTA.format(original)
        let lines = text.split(separator: "\n")
        #expect(lines[0] == ">round trip")
        #expect(lines[1].count == 60)
        #expect(lines.count == 4)                                   // header + 60 + 60 + 30
        let reparsed = try FASTA.parseOne(text)
        #expect(reparsed.letters == original.letters)
        #expect(reparsed.header == original.header)
    }

    @Test("a real bundled sequence round-trips through FASTA")
    func realSequenceRoundTrip() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/ubiquitin.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: dir)
        let sequence = ProteinSequence(header: "ubiquitin", letters: bundle.metadata.sequence)
        #expect(sequence.count == 76)
        let reparsed = try FASTA.parseOne(FASTA.format(sequence))
        #expect(reparsed.letters == bundle.metadata.sequence)
    }
}
