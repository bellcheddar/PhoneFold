# PhoneFold — STATE

**Current phase:** 1 (fold engine and frame stream). Phase 0 has deferred items, listed below.
**Current task:** P1-04
**Last updated:** 2026-08-28

Status vocabulary: `todo` / `doing` / `blocked` / `done`.
A task must be small enough that one loop iteration can finish it, build, test and commit.
If it cannot, split it before starting.

---

## Phase 0 — Model Forge

Per PLAN.md §Phase 0, the sample-trajectory fallback is built **first** so that Phases 1-5
are never blocked on the hardest problem in the project.

| ID | Task | Deps | Status |
|---|---|---|---|
| P0-01 | `PhoneFoldKit` SPM package skeleton: 7 library targets + 7 test targets, `swift build` and `swift test` green on macOS | — | done |
| P0-02 | `FoldCore` value types: `FoldFrame`, `BackboneResidue`, `SSAssignment`, `ContactEvent`, `AminoAcid`. `Sendable`, no `#if os`. Unit tested | P0-01 | done |
| P0-03 | Trajectory bundle format (`.pftraj`): versioned container spec in `Tools/README.md` + Swift reader/writer in `FoldCore` with round-trip tests | P0-02 | done |
| P0-03b | Python `.pftraj` writer (`Tools/pftraj.py`) + a cross-language fixture proving the Swift reader decodes exactly what Python wrote | P0-03 | done |
| P0-04 | `Tools/` Python environment: venv on python3.12, pinned `requirements.txt`, `Tools/README.md` documenting exact versions | — | done |
| P0-05 | Trajectory generator `Tools/make_sample_trajectories.py`: runs real ESMFold, captures a coordinate readout every N blocks, writes `.pftraj`. **Real inference only — no synthesised trajectories** | P0-03, P0-04 | done |
| P0-06 | Produce the 12 bundled trajectories (ubiquitin, GFP, lysozyme, insulin, myoglobin, GPCR fragment, IDR, designed all-alpha bundle + 4 of Marc's choosing) into `Apps/Shared/Resources/Trajectories/` | P0-05 | done |
| P0-07 | `SampleTrajectoryProvider` in `FoldEngine`: loads a `.pftraj` and emits `AsyncStream<FoldFrame>` at wall-clock rate. Tests | P0-06 | todo |
| P0-08 | ~~Export ESM-2 650M to Core ML~~ | — | **dropped** |
| P0-09 | ~~Export the stateful ESMFold trunk step model~~ | — | **dropped** |

ESMFold is no longer the engine. P0-08, P0-09 and P0-13 are dropped; the ESMFold work that
survives is the twelve trajectories in P0-06, kept as an interim fixture so Phases 1 to 5 are
never blocked, and the trunk-patching harness, which is reused by PathDiffusion.

### Phase 0b — the Genie 2 live engine

| ID | Task | Deps | Status |
|---|---|---|---|
| P0-14 | Add `foldingdiff-denoising` and `pathdiffusion-pathway` to `TrajectoryProvenance` in both `FoldCore` and `Tools/pftraj.py`; extend the cross-language fixture test | P0-03b | done |
| P0-15 | `Tools/make_foldingdiff_trajectories.py`: sample a backbone, capture every denoising step, write `.pftraj`. Real sampling only | P0-14 | done (superseded by P0-24) |
| P0-16 | ProteinMPNN inverse folding (CA-only weights for Genie 2) so the trajectory carries a designed sequence the score can use | P0-15 | done |
| P0-24 | `Tools/make_genie2_trajectories.py`: sample with Genie 2, capture every denoising step, write `.pftraj` | P0-14 | done |
| P0-25 | CA-only support: `.pftraj` format version 2 adds an atoms-per-residue word; version 1 files still decode | P0-24 | done |
| P0-26 | Add `genie2-denoising` to `TrajectoryProvenance` on both sides | P0-14 | done |
| P0-17 | Export Genie 2 to Core ML: 15.73 M parameters, fp16, lengths to 256 | P0-24 | done (length 64; more buckets outstanding) |
| P0-18 | Export ProteinMPNN to Core ML: split the encoder (one shot) from the per-residue decoder step (autoregressive), loop in Swift | P0-16 | **deferred** |
| P0-19 | `Tools/bench_ane.py` + on-device XCTest harness; results to `METRICS.md` | P0-17, P0-18 | part done (Mac measured; on-device is a human gate) |

### Phase 0c — the PathDiffusion named gallery

| ID | Task | Deps | Status |
|---|---|---|---|
| P0-20 | Stand up PathDiffusion: clone, weights, dependency audit on Apple Silicon. Halt if it needs CUDA-only kernels | — | todo |
| P0-21 | MSA pipeline for the twelve bundled sequences only. Check disk before downloading databases | P0-20 | todo |
| P0-22 | Generate the twelve named folding pathways, replacing the interim ESMFold bundle | P0-21, P0-14 | todo |
| P0-23 | `Models/manifest.json`: hashes, source checkpoints, toolchain versions, measured trajectory statistics for both engines | P0-19, P0-22 | todo |

### Deferred Phase 0 items, and why

PLAN.md Phase 0 is explicit: *"Start Phase 0 with the sample trajectory provider, then attempt
the export. That way Phases 1 to 5 are never blocked on the hardest problem in the project."*
The same logic applies to what is left.

| Item | Why it can wait |
|---|---|
| P0-18, ProteinMPNN to Core ML | `sample()` is autoregressive with a Python loop over residues, so it needs splitting into a one-shot encoder and a per-step decoder with the loop in Swift. The designed sequence is only consumed by the **Phase 3** score; Phases 1 and 2 need coordinates only |
| Genie 2 length buckets beyond 64 | Mechanical repetition of a working export. Conversion takes ~9 minutes per bucket and would tie up the machine |
| P0-20 to P0-22, PathDiffusion | Needs MSA databases measured in tens of gigabytes against 33 GB free. Wants its own session, and the interim ESMFold bundle keeps the gallery populated meanwhile |

Everything Phase 1 needs already exists: thirteen `.pftraj` files on disk, a working reader,
and a Genie 2 trajectory in both the CA-trace and full-backbone layouts.

### Phase 0 exit gate (revised for the two-engine design)

Machine-verifiable:
- [ ] foldingDiff and ProteinMPNN `.mlpackage` files load and predict in an XCTest on the Simulator without crashing
- [ ] Trajectory statistics for both engines written to `METRICS.md`
- [ ] Twelve PathDiffusion pathways present and loading in `Apps/Shared/Resources/`
- [ ] A live foldingDiff sample round-trips: generate, inverse-fold, write `.pftraj`, read in Swift

Human-verifiable (**halt**):
- [ ] ANE residency confirmed on device in Instruments
- [ ] Real-device frames per second acceptable to Marc
- [ ] Marc watches a foldingDiff trajectory and agrees it looks like a fold

---

## Phase 1 — Fold engine and frame stream

**Goal (PLAN.md):** a headless, fully tested, platform-agnostic pipeline turning a sequence
into a smooth 60 fps stream of enriched `FoldFrame` values. No UI. Human-verifiable criteria:
**none.** The loop should complete this phase unattended.

| ID | Task | Deps | Status |
|---|---|---|---|
| P1-01 | `FoldCore.ProteinSequence`: FASTA parsing (multi-record, wrapped lines, ambiguity codes, `*` and `-` stripping) with helpful validation errors | — | done |
| P1-02 | UniProt fetch from `rest.uniprot.org` | P1-01 | **deferred: no consumer** |
| P1-03 | ~~ESM-2 tokeniser in pure Swift~~ | — | **dropped** |
| P1-04 | `FoldGeometry`: Kabsch superposition of each frame onto the previous, so the molecule stops tumbling | — | todo |
| P1-05 | Interpolation to 60 fps: quaternion slerp on residue frames, linear on translations, Catmull-Rom in time. Interpolated frames flagged | P1-04 | todo |
| P1-06 | P-SEA secondary structure, CA-only, with ~3-frame temporal hysteresis and per-residue confidence | — | todo |
| P1-07 | Contact map and `ContactEvent` emission on inward 8 A crossing, tagged by separation and hydrophobicity | — | todo |
| P1-08 | Per-frame metrics: radius of gyration, contact order, fraction buried hydrophobic, mean and minimum confidence | P1-07 | todo |
| P1-09 | `actor FoldEngine` exposing `AsyncStream<FoldFrame>`, with `SampleTrajectoryProvider` reading `.pftraj` | P1-05, P1-06, P1-07, P1-08 | todo |
| P1-10 | Backpressure (bounded buffer, never drop frames), cancellation, thermal and low-power degradation by reducing readouts rather than stuttering | P1-09 | todo |
| P1-11 | DSSP reference fixtures for 10 PDB structures, for the P-SEA agreement gate | P1-06 | todo |

**P1-02 is deferred:** on-device accession lookup existed so a user could fold their own
protein live. The chosen engine generates novel proteins and the named gallery is
precomputed, so nothing in the app consumes it. `Tools/fetch_sequences.py` already does this
offline, with the provenance checks that matter. It returns the moment live arbitrary
folding does.

**P1-03 is dropped:** the ESM-2 tokeniser existed to feed ESMFold. Genie 2 is sequence-agnostic
and ProteinMPNN carries its own alphabet, so nothing in the shipping pipeline tokenises a
sequence for a language model.

### Phase 1 exit gate

Machine-verifiable:
- [ ] `swift test` green on macOS and iOS Simulator
- [ ] P-SEA agrees with a DSSP reference on 10 PDB structures at >=85% per-residue (CA-only)
- [ ] A bundled trajectory plays end to end from the sample provider
- [ ] Frame stream sustains 60 fps output with interpolation for a 300-residue input
- [ ] Zero data races under Thread Sanitizer with Swift 6 strict concurrency
- [ ] No `#if os(...)` anywhere in FoldCore, FoldEngine or FoldGeometry

Human-verifiable: **none.**

## Phases 2-5

Not yet decomposed. Decompose on entry to the phase.
