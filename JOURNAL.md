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

## 2026-08-28 — P0-03b — Python .pftraj writer and cross-language proof

`Tools/pftraj.py` writes the container the Swift reader consumes, refusing an empty
sequence, no readouts, a wrong-shaped array or any non-finite value. 7 pytest cases.

The check that actually matters is cross-language: `Tools/make_fixture.py` writes a fixture
with values exactly representable in float32, and `CrossLanguageCodecTests.swift` reads it
back asserting exact equality on every coordinate and pLDDT of 4 frames x 9 residues.
Negative-tested by flipping one bit of the last pLDDT value in the fixture, which failed the
suite with `21.78125 == 21.75` and passed again on restore. Byte compatibility is now a
tested property, not an assumption.

**Test result:** Swift 42 tests in 13 suites pass; Python 7 pytest cases pass.
**Invariants:** GREEN.

## 2026-08-28 — P0-05, P0-06 — the twelve sample trajectories

`Tools/fetch_sequences.py` resolves all twelve proteins from accessions (RCSB polymer
entities and UniProt), never from pasted strings, and asserts an expected length as a hard
failure. That check earned its keep immediately: GFP from 1EMA came back 236 residues rather
than 238, because crystallised GFP collapses the Thr-Tyr-Gly chromophore into a single CRO
residue, which reaches a folding model as X in the middle of the barrel. GFP now comes from
UniProt P42212 instead. The Pin1 WW domain range 6-39 was verified by eye against both
signature tryptophans.

`Tools/make_sample_trajectories.py` patches EsmFoldingTrunk.forward to read coordinates out
mid-fold. **Verified bit-exact against the unpatched model**: 0.000e+00 difference in both
coordinates and pLDDT on ubiquitin and GFP.

Two bugs found and fixed by measurement rather than by review:

1. Per-residue pLDDT was averaged over all 37 atom slots, including the ~20 that do not
   exist for a given residue. Ubiquitin read 77.4 instead of 90.5. Both are plausible
   pLDDTs, which is precisely why it survived until it was checked against the model's own
   number. Now read at the CA, as AlphaFold defines it.
2. PLAN.md's specified readout every 4 trunk blocks produces frames that are not
   polypeptides (CA-CA 5-18 A against an ideal 3.80). Changed to the end of each recycle,
   where the structure module is trained to run, taking all 8 IPA layers.

All twelve generated: 32 frames each, 2.2 MB total, 20 to 314 residues, spanning all-alpha,
all-beta, mixed and disordered.

**HALT.** Measuring the result raised a question that changes what the app shows, which is
Marc's decision, not the agent's. Written up with evidence in BLOCKERS.md.

## 2026-08-28 — model survey, and the change of engine

ESMFold produced no watchable trajectory (BLOCKERS.md). Surveyed six diffusion models
(MODEL_SURVEY.md) and measured foldingDiff against ESMFold on identical criteria.

The structural finding: SALAD and foldingDiff are **unconditional generators** with no
sequence input, so neither can fold a named protein. SALAD is also JAX, with no Core ML path.

foldingDiff measured at 76 residues: 15.29 A of motion against ESMFold's 0.87 A, Rg sweeping
5.7 to 20.8 A, CA-CA staying 2.3 to 3.8 A throughout so a backbone tube sweeps through every
frame, converging to 3.823 +- 0.007 A. 14.5 M parameters, 57.9 MB.

Marc chose the hybrid: foldingDiff live on-device, PathDiffusion precomputed for the named
gallery. Live folding of an arbitrary user accession is deliberately given up.

## 2026-08-28 — P0-14 — provenance for two engines

Added `foldingdiff-denoising` and `pathdiffusion-pathway` to `TrajectoryProvenance` on both
sides, and a `ConfidenceSource` enum so denoising progress is never labelled pLDDT: that
would be a scientific claim foldingDiff cannot support. `isGenerated` lets the UI say that a
foldingDiff protein has never existed. The Python writer now rejects an unknown provenance
rather than writing a file FoldCore would fail to decode.

**Test result:** Swift 47 tests in 14 suites pass; Python 7 pass plus a rejection check.
**Invariants:** GREEN.

## 2026-08-28 — P0-15 — foldingDiff trajectory generator

`Tools/make_foldingdiff_trajectories.py` samples a backbone and writes every strided
denoising step as `.pftraj`. 76 residues, 1000 steps in 18 s, 201 frames kept, 0.80 MB.

Three gaps are recorded rather than papered over. The sequence is written as `X`, which is
what it genuinely is until ProteinMPNN runs. The per-residue value is denoising progress,
uniform across residues because that is all the model provides, and the provenance records
it as `denoising-progress` so nothing can mistake it for pLDDT. The carbonyl oxygen is not
emitted by the model and is placed by idealised geometry from the model's own sampled psi.

The O placement was verified by the check that would catch a sign error: **O...N(i+1) is
2.255 +- 0.007 A**, where a flipped torsion gives about 1.7 A. O-C-N(i+1) came out at
122.55 degrees against an ideal 123. Model-derived geometry is clean throughout: N-CA 1.460,
CA-C 1.540, C-N+1 1.340, CA-CA 3.823 +- 0.007.

**Invariants:** GREEN.

## 2026-08-28 — Genie 2 adopted; P0-24, P0-25, P0-26

Marc asked for Genie 2 to be tested after foldingDiff's backbones proved mostly extended. It
wins decisively: 8/8 compact and 8/8 designable at 76 residues against foldingDiff's 2/14 and
0/14, median scTM 0.939 against 0.118, and 49% charged residues against 13%. Full table in
METRICS.md.

P0-26: `genie2-denoising` added to `TrajectoryProvenance` on both sides.

P0-25: Genie 2 emits a CA trace and nothing else, so `.pftraj` gained format version 2 with
an atoms-per-residue word. Storing constructed N and C atoms to fill a four-atom record would
be inventing coordinates and presenting them as model output. `TrajectoryReadout.backbone` is
now optional and `caPositions` is always present. Version 1 files still decode, verified
against the twelve real ESMFold files on disk rather than only a synthetic fixture.

P0-24: `Tools/make_genie2_trajectories.py` re-derives the reverse diffusion loop to record
intermediate frames, which upstream discards. Verified against upstream: all 1000 randn_like
draws identical, final structure to a Kabsch RMSD of 0.00048 A.

One mistake worth recording. The first comparison of my sampler against theirs used a raw
coordinate difference and reported 85 A, which looked like a serious bug. It was a rigid-body
offset: upstream centres the structure in its PDB writer. Structures are compared after
superposition, never coordinate-wise.

The trajectory is what the app needs: 201 frames, Rg 1.0 to 10.8 A, 10.72 A of motion, ending
at a compact fold. ESMFold's equivalent was 0.87 A.

**Test result:** Swift 53 tests in 16 suites pass; Python 7 pass. **Invariants:** GREEN.
