import Foundation
import simd
import FoldCore

/// Folds a list of proteins one after another, and survives the ones that fail.
///
/// PLAN.md Phase 5a: "fold them all, produce a film per protein overnight".
///
/// **The whole design follows from the word "overnight".** Nobody watches a batch, so the two
/// things that matter are that one bad record cannot end the run, and that what happened to
/// every record is recoverable in the morning. A runner that throws on the first 404 has folded
/// two proteins and wasted eight hours, and a runner that swallows failures silently is worse,
/// because the missing films look like proteins that were never asked for.
///
/// What to *do* with each fold is a closure rather than a method here: writing a film needs
/// RealityKit and AVFoundation, and `FoldEngine` has no platform code in it and is not going to
/// acquire any for this.
public struct BatchRunner: Sendable {

    /// How a single record ended.
    public enum Outcome: Sendable, Equatable {
        case folded(readouts: Int, residues: Int)
        /// Fetched and folded, but the file's own sequence disagreed with the database's.
        case foldedWithWarning(readouts: Int, residues: Int, warning: String)
        case failed(String)
        case cancelled

        public var isSuccess: Bool {
            switch self {
            case .folded, .foldedWithWarning: true
            case .failed, .cancelled: false
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public let accession: String
        public let label: String?
        public let outcome: Outcome
    }

    public struct Summary: Sendable, Equatable {
        public var results: [Result]
        /// Lines of the input that never became records at all.
        public var rejections: [BatchInput.Rejection]

        public var succeeded: Int { results.count { $0.outcome.isSuccess } }
        public var failed: Int {
            results.count { if case .failed = $0.outcome { true } else { false } }
        }
        public var warned: Int {
            results.count { if case .foldedWithWarning = $0.outcome { true } else { false } }
        }

        /// One line per record, for the log an unattended run leaves behind.
        public var report: String {
            var lines: [String] = []
            for result in results {
                let name = result.label.map { "\(result.accession) (\($0))" } ?? result.accession
                switch result.outcome {
                case .folded(let readouts, let residues):
                    lines.append("ok        \(name): \(residues) residues, \(readouts) readouts")
                case .foldedWithWarning(let readouts, let residues, let warning):
                    lines.append("ok        \(name): \(residues) residues, "
                                 + "\(readouts) readouts - \(warning)")
                case .failed(let reason):
                    lines.append("failed    \(name): \(reason)")
                case .cancelled:
                    lines.append("cancelled \(name)")
                }
            }
            for rejection in rejections {
                let where_ = rejection.line > 0 ? "line \(rejection.line)" : "input"
                lines.append("skipped   \(where_): \(rejection.reason)")
            }
            lines.append("")
            lines.append("\(succeeded) folded, \(failed) failed, \(warned) with a sequence "
                         + "warning, \(rejections.count) not read")
            return lines.joined(separator: "\n")
        }
    }

    /// Turns an accession into a structure. Injected so the runner can be tested without a
    /// network, and so Studio can put a cache in front of it.
    public typealias Resolver = @Sendable (String) async throws -> ReferenceStructure

    public var engine: FoldingEngine
    public var steps: Int?
    public var frameCount: Int

    public init(engine: FoldingEngine = .structureBased, steps: Int? = nil,
                frameCount: Int = 180) {
        self.engine = engine
        self.steps = steps
        self.frameCount = frameCount
    }

    /// Fold everything in `input`, handing each finished trajectory to `deliver`.
    ///
    /// `deliver` is where a film gets written. A throw from it fails that one record and the
    /// batch carries on, for the same reason a failed fetch does: the remaining forty records
    /// are still worth having.
    public func run(_ input: BatchInput,
                    resolve: Resolver,
                    progress: (@Sendable (Int, Int, String) -> Void)? = nil,
                    deliver: (TrajectoryBundle, BatchInput.Item) async throws -> Void)
        async -> Summary {

        var results: [Result] = []
        for (index, item) in input.items.enumerated() {
            if Task.isCancelled {
                results.append(Result(accession: item.accession, label: item.label,
                                      outcome: .cancelled))
                continue
            }
            progress?(index, input.items.count, item.accession)
            results.append(await fold(item, resolve: resolve, deliver: deliver))
        }
        return Summary(results: results, rejections: input.rejections)
    }

    private func fold(_ item: BatchInput.Item,
                      resolve: Resolver,
                      deliver: (TrajectoryBundle, BatchInput.Item) async throws -> Void)
        async -> Result {
        do {
            let reference = try await resolve(item.accession)
            let warning = Self.sequenceWarning(fileSequence: item.sequence,
                                               fetched: reference.sequence)

            let native = reference.caPositions
            let metadata = TrajectoryMetadata(
                name: item.label ?? reference.name,
                sequence: reference.sequence,
                accession: reference.accession,
                provenance: engine.provenance,
                sourceModel: "on-device",
                blocksPerReadout: 1,
                recycles: 1,
                generated: ISO8601DateFormatter().string(from: Date()),
                notes: engine.provenance.disclosure)

            let bundle = try LiveTrajectory.fold(
                engine: engine, native: native, metadata: metadata,
                residues: reference.residues, seed: 1, steps: steps, frameCount: frameCount)

            try await deliver(bundle, item)

            let readouts = bundle.readouts.count
            let residues = reference.residues.count
            if let warning {
                return Result(accession: item.accession, label: item.label,
                              outcome: .foldedWithWarning(readouts: readouts,
                                                          residues: residues,
                                                          warning: warning))
            }
            return Result(accession: item.accession, label: item.label,
                          outcome: .folded(readouts: readouts, residues: residues))
        } catch is CancellationError {
            return Result(accession: item.accession, label: item.label, outcome: .cancelled)
        } catch {
            return Result(accession: item.accession, label: item.label,
                          outcome: .failed("\(error)"))
        }
    }

    /// Compare the sequence the file claims against the one the database returned.
    ///
    /// **A warning rather than a failure, and neither is obviously right.** The fold is of the
    /// accession's real structure either way, so it is not wrong; but if the file's sequence
    /// differs then the file was describing a different isoform or a construct, and the person
    /// who queued the batch believes they folded that. Naming the first differing position is
    /// what makes the difference actionable: "they differ" sends someone to diff two sequences
    /// by hand, and length alone hides a point substitution completely.
    static func sequenceWarning(fileSequence: String, fetched: String) -> String? {
        let file = fileSequence.uppercased().filter(\.isLetter)
        guard !file.isEmpty else { return nil }          // a plain list has nothing to check
        let target = fetched.uppercased().filter(\.isLetter)
        guard file != target else { return nil }

        if file.count != target.count {
            return "the file's sequence is \(file.count) residues, the database's is "
                + "\(target.count); folding the database's"
        }
        for (index, pair) in zip(file, target).enumerated() where pair.0 != pair.1 {
            return "the file's sequence differs at residue \(index + 1) "
                + "(\(pair.0) against \(pair.1)); folding the database's"
        }
        return nil
    }
}
