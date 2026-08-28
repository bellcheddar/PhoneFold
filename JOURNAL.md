# PhoneFold — JOURNAL

Append-only. One entry per loop iteration: timestamp, task, what changed, test result, commit SHA.

---

## 2026-08-28 — P0-01 — PhoneFoldKit package skeleton

Created the local SPM package with the seven library targets from PLAN.md §3 and one test
target each. Dependency direction encoded in Package.swift: FoldCore depends on nothing;
FoldGeometry, FoldAudio, FoldRender and FoldSync depend on FoldCore; FoldEngine on
FoldCore + FoldGeometry; FoldCapture on FoldCore + FoldRender. FoldRender and FoldAudio do
not reference each other, as specified.

Swift 6 language mode on, platform floors iOS 18 / macOS 15 / watchOS 11 / visionOS 2
(RealityKit LowLevelMesh, which Phase 2 needs, requires iOS 18 and visionOS 2).

**Test result:** `swift build` clean in 1.03 s; `swift test` 7 tests in 7 suites, all passed.
**Invariants:** GREEN.

## 2026-08-28 — P0-02 — FoldCore value types

`AminoAcid` (20 + unknown, Kyte-Doolittle hydropathy, formal charge), `SecondaryStructure`
and `SSAssignment` (three-state with per-residue confidence, clamped), `ContactRange` and
`ContactEvent` (ordered indices, separation classed local / medium / long-range at the
6 and 12 boundaries), `BackboneResidue` and `FoldFrame` exactly as specified in PLAN.md
Phase 1. All `Sendable`, no platform conditionals.

Three states rather than eight: a CA-only assignment cannot honestly separate a 3-10 helix
from an alpha helix early in a trajectory, and the renderer only sweeps three cross sections.

`FoldFrame.isWellFormed` is the predicate Phase 2's zero-NaN gate will use, so it was
negative-tested against NaN, +inf and -inf coordinates, a non-finite metric, and mismatched
per-residue array lengths.

**Test result:** 27 tests in 11 suites, all passed. **Invariants:** GREEN.

## 2026-08-28 — P0-04 — Phase 0 Python environment

`Tools/setup_env.sh` + pinned `Tools/requirements.txt` on Homebrew python3.12 (torch has no
3.14 wheels). Installed and verified: torch 2.9.1 (MPS available), transformers 4.57.1,
coremltools 9.0, numpy 2.1.3, scipy 1.15.3, biotite 1.6.0.

ESMFold comes from `transformers.EsmForProteinFolding`, not `fair-esm[esmfold]`, because
the latter needs OpenFold's CUDA kernels which do not build on Apple Silicon.

Recorded in Tools/README.md: coremltools 9.0 warns that torch 2.9.1 is untested (2.7.0 is
the newest tested). Harmless for P0-05/P0-06, which never import coremltools. If the Core ML
tracer fails in P0-08, dropping to torch 2.7.0 is the first move, before debugging our own
graph surgery.

**Test result:** import check green, MPS available. **Invariants:** GREEN.

## 2026-08-28 — P0-03 — the .pftraj trajectory container

Versioned binary container: 8-byte magic, format version, JSON metadata block, then raw
readouts as float32 backbone coordinates plus pLDDT. Documented in Tools/README.md.

Design decision worth recording: the file stores **only what the model emitted**. Secondary
structure, contacts, metrics and interpolated frames are all derived at load time by
FoldGeometry. Storing them would create a second source of truth that could disagree with
the live path, and would let a bundle ship a P-SEA assignment the shipping P-SEA
implementation would never produce.

`TrajectoryProvenance` has no case for a synthesised trajectory, by construction. The only
non-inference case is `test-fixture`, which must never ship in an app bundle.

Metadata JSON uses sorted keys so encoding is deterministic and a bundle can be hashed into
Models/manifest.json.

Negative-tested the reader against a foreign file, a future format version, three truncation
points, a body one byte short, and metadata disagreeing with the body.

**Test result:** 38 tests in 12 suites, all passed. **Invariants:** GREEN.
