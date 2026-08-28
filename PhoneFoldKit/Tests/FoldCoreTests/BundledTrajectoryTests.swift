import Testing
import Foundation
@testable import FoldCore

/// The twelve ESMFold trajectories on disk are format version 1, written before Genie 2
/// forced a CA-trace mode into the container. A synthetic backward-compatibility test is
/// not enough: these are the actual files the app ships, so decode the real thing.
@Suite("Bundled trajectories on disk")
struct BundledTrajectoryTests {

    static var trajectoryDirectory: URL {
        // Tests run from the package directory; the bundle lives beside it in the repo.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // -> FoldCoreTests
            .deletingLastPathComponent()   // -> Tests
            .deletingLastPathComponent()   // -> PhoneFoldKit
            .deletingLastPathComponent()   // -> repo root
            .appending(path: "Apps/Shared/Resources/Trajectories")
    }

    @Test("every bundled .pftraj decodes and is self-consistent")
    func bundledFilesDecode() throws {
        let dir = Self.trajectoryDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else {
            Issue.record("trajectory directory missing at \(dir.path)")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pftraj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(files.count >= 12, "expected at least 12 bundled trajectories, got \(files.count)")

        for file in files {
            let bundle = try TrajectoryBundleCodec.read(contentsOf: file)
            #expect(bundle.isConsistent, "\(file.lastPathComponent) is not self-consistent")
            #expect(bundle.metadata.residueCount > 0)
            #expect(!bundle.readouts.isEmpty)
            // Nothing shipped in an app bundle may be a test fixture.
            #expect(bundle.metadata.provenance.isShippable,
                    "\(file.lastPathComponent) has unshippable provenance")
            // Every per-residue array must match the sequence length.
            for r in bundle.readouts {
                #expect(r.caPositions.count == bundle.metadata.residueCount)
                #expect(r.confidence.count == bundle.metadata.residueCount)
            }
        }
    }
}
