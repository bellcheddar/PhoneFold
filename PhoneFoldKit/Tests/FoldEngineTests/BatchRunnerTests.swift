import Testing
import Synchronization
import Foundation
import simd
@testable import FoldCore
@testable import FoldEngine

@Suite("Batch runner: what an unattended run does when something goes wrong")
struct BatchRunnerTests {

    /// A small helix, enough for the structure-based model to have something to fold toward.
    static func reference(_ accession: String, residues: Int = 20,
                          sequence: String? = nil) -> ReferenceStructure {
        var ca: [SIMD3<Double>] = []
        for i in 0..<residues {
            let t = Double(i) * 1.75
            ca.append(SIMD3(2.3 * cos(t), 2.3 * sin(t), Double(i) * 1.5))
        }
        return ReferenceStructure(
            accession: accession,
            name: "Test \(accession)",
            sequence: sequence ?? String(repeating: "A", count: residues),
            caPositions: ca,
            pLDDT: [Float](repeating: 90, count: residues))
    }

    /// Few steps: these tests are about control flow, not about folding quality.
    static let runner = BatchRunner(engine: .morph, frameCount: 12)

    @Test("Every record folds and is delivered once")
    func allSucceed() async throws {
        let input = BatchInput.parse("P69905\nP68871")
        let delivered = Mutex<[String]>([])
        let summary = await Self.runner.run(
            input,
            resolve: { Self.reference($0) },
            deliver: { _, item in delivered.withLock { $0.append(item.accession) } })

        #expect(summary.succeeded == 2)
        #expect(summary.failed == 0)
        #expect(delivered.withLock { $0 } == ["P69905", "P68871"])
    }

    /// The reason the runner exists in this shape: a batch that dies on record two has folded
    /// one protein and wasted the night.
    @Test("A failed lookup fails one record and the rest still run")
    func oneFailureDoesNotEndTheRun() async throws {
        let input = BatchInput.parse("P69905\nP68871\nP0DTD1")
        let summary = await Self.runner.run(
            input,
            resolve: { accession in
                if accession == "P68871" {
                    throw AlphaFoldClient.Failure.notFound(accession: accession)
                }
                return Self.reference(accession)
            },
            deliver: { _, _ in })

        #expect(summary.results.count == 3)
        #expect(summary.succeeded == 2)
        #expect(summary.failed == 1)
        let failed = try #require(summary.results.first { !$0.outcome.isSuccess })
        #expect(failed.accession == "P68871")
    }

    /// Writing the film is where the disk fills up at 3 a.m.
    @Test("A throw from deliver fails only that record")
    func deliveryFailureIsContained() async throws {
        let input = BatchInput.parse("P69905\nP68871")
        struct DiskFull: Error {}
        let summary = await Self.runner.run(
            input,
            resolve: { Self.reference($0) },
            deliver: { _, item in if item.accession == "P69905" { throw DiskFull() } })

        #expect(summary.succeeded == 1)
        #expect(summary.failed == 1)
    }

    // MARK: - The sequence check

    @Test("A matching sequence produces no warning")
    func sequenceAgrees() async throws {
        let sequence = String(repeating: "A", count: 20)
        let input = BatchInput.parse(">sp|P69905|HBA_HUMAN\n\(sequence)")
        let summary = await Self.runner.run(
            input, resolve: { Self.reference($0, sequence: sequence) }, deliver: { _, _ in })
        #expect(summary.warned == 0)
        #expect(summary.succeeded == 1)
    }

    /// A point substitution is exactly what a length check would miss, and it is the case that
    /// matters: it means the file described a variant and the fold is of the wild type.
    @Test("A one-residue difference is named by position")
    func pointDifference() {
        let warning = BatchRunner.sequenceWarning(
            fileSequence: "MVLSPADKTN", fetched: "MVLSPADRTN")
        let text = try! #require(warning)
        #expect(text.contains("residue 8"))
        #expect(text.contains("K"))
        #expect(text.contains("R"))
    }

    @Test("A length difference is reported as a length difference")
    func lengthDifference() {
        let warning = BatchRunner.sequenceWarning(fileSequence: "MVLS", fetched: "MVLSPADK")
        let text = try! #require(warning)
        #expect(text.contains("4 residues"))
        #expect(text.contains("8"))
    }

    @Test("A plain accession list carries no sequence, so it cannot disagree")
    func noSequenceNoWarning() {
        #expect(BatchRunner.sequenceWarning(fileSequence: "", fetched: "MVLSPADK") == nil)
    }

    @Test("A mismatch warns but still folds")
    func mismatchStillFolds() async throws {
        let input = BatchInput.parse(">sp|P69905|HBA_HUMAN\n" + String(repeating: "G", count: 20))
        let summary = await Self.runner.run(
            input,
            resolve: { Self.reference($0, sequence: String(repeating: "A", count: 20)) },
            deliver: { _, _ in })
        #expect(summary.succeeded == 1, "the structure is still the accession's")
        #expect(summary.warned == 1)
    }

    // MARK: - The morning after

    /// What an unattended run leaves behind is the only thing anyone sees.
    @Test("The report accounts for every record, including the unreadable ones")
    func reportIsComplete() async throws {
        let input = BatchInput.parse("P69905\nnot-an-accession\nP68871")
        let summary = await Self.runner.run(
            input,
            resolve: { accession in
                if accession == "P68871" { throw AlphaFoldClient.Failure.notFound(accession: accession) }
                return Self.reference(accession)
            },
            deliver: { _, _ in })

        let report = summary.report
        #expect(report.contains("ok"))
        #expect(report.contains("failed"))
        #expect(report.contains("skipped"))
        #expect(report.contains("not-an-accession"))
        #expect(report.contains("1 folded, 1 failed"))
    }

    @Test("Progress is reported once per record, in order")
    func progress() async throws {
        let input = BatchInput.parse("P69905\nP68871")
        let seen = Mutex<[Int]>([])
        _ = await Self.runner.run(
            input,
            resolve: { Self.reference($0) },
            progress: { index, total, _ in
                seen.withLock { $0.append(index) }
                #expect(total == 2)
            },
            deliver: { _, _ in })
        #expect(seen.withLock { $0 } == [0, 1])
    }
}
