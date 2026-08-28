# PhoneFold — STATE

**Current phase:** 2 (Aurora Stage, the renderer). Phase 1 is complete, gate GREEN. Phase 0 has deferred items, listed below.
**Current task:** P2-11 (snapshot tests), then cache per-bucket materials
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
| P1-04 | `FoldGeometry`: Kabsch superposition of each frame onto the previous, so the molecule stops tumbling | — | done |
| P1-05 | Interpolation to 60 fps: Catmull-Rom in time over aligned frames, interpolated frames flagged | P1-04 | done |
| P1-06 | P-SEA secondary structure, CA-only, with ~3-frame temporal hysteresis and per-residue confidence | — | done |
| P1-07 | Contact map and `ContactEvent` emission on inward 8 A crossing, tagged by separation and hydrophobicity | — | done |
| P1-08 | Per-frame metrics: radius of gyration, contact order, fraction buried hydrophobic, compactness, mean and minimum confidence | P1-07 | done |
| P1-09 | `actor FoldEngine` exposing a backpressured `FoldFrameSequence`, with `SampleTrajectoryProvider` reading `.pftraj` | P1-05, P1-06, P1-07, P1-08 | done |
| P1-10 | Backpressure (pull-based, so frames cannot be dropped), cancellation, thermal and low-power degradation by lowering the frame rate rather than stuttering | P1-09 | done |
| P1-11 | DSSP reference fixtures for 10 PDB structures (mkdssp 4.4.5) | P1-06 | done |
| P1-12 | Training set: fetch non-redundant PDB chains, compute CA features and mkdssp labels, **excluding every evaluation entry** | P1-11 | done |
| P1-13 | Train a small CA-only secondary-structure classifier, export weights as JSON | P1-12 | done |
| P1-14 | `LearnedSSE` in `FoldGeometry`: load weights and evaluate. Viterbi measured and rejected. **86.9% on the held-out ten** | P1-13 | done |

**P1-02 is deferred:** on-device accession lookup existed so a user could fold their own
protein live. The chosen engine generates novel proteins and the named gallery is
precomputed, so nothing in the app consumes it. `Tools/fetch_sequences.py` already does this
offline, with the provenance checks that matter. It returns the moment live arbitrary
folding does.

**P1-03 is dropped:** the ESM-2 tokeniser existed to feed ESMFold. Genie 2 is sequence-agnostic
and ProteinMPNN carries its own alphabet, so nothing in the shipping pipeline tokenises a
sequence for a language model.

### Phase 1 exit gate

Machine-verifiable — **all met, gate GREEN 2026-08-28**:
- [x] `swift test` green on macOS (138 tests) and iOS Simulator (138 tests, zero failures)
- [x] CA-only secondary structure agrees with a DSSP reference on 10 held-out PDB structures at >=85% per-residue — **86.9%**. P-SEA's 79.4% stays under test as a baseline
- [x] A bundled trajectory plays end to end from the sample provider; all 13 do
- [x] Frame stream sustains 60 fps for a 314-residue input — **1.65 ms/frame in release**, 10% of the 16.7 ms budget
- [x] Zero data races under Thread Sanitizer with Swift 6 strict concurrency
- [x] No `#if os(...)` anywhere in FoldCore, FoldEngine or FoldGeometry

Human-verifiable: **none.** The phase completed unattended, as PLAN.md predicted.

## Phases 2-5

Not yet decomposed. Decompose on entry to the phase.

## Phase 2 — Aurora Stage, the renderer

**Goal (PLAN.md):** the thing people film and post. Secondary structure formation is the
visual headline. Built multiplatform from the start so Phase 5 is additive.

| ID | Task | Deps | Status |
|---|---|---|---|
| P2-01 | `FoldRender`: backbone tube geometry. Catmull-Rom spline through CA, swept with a cross section that morphs with per-residue secondary structure confidence | — | done |
| P2-02 | `LowLevelMesh` writer so vertex buffers are rewritten in place per frame. Never rebuild `MeshResource` | P2-01 | done |
| P2-03 | The four colour modes: confidence (AlphaFold ramp), secondary structure, rainbow N to C, Kyte-Doolittle hydrophobicity, with animated cross-fade | P2-01 | done |
| P2-04 | Contact flashes: a short-lived emissive line and particle burst at the midpoint, brighter and longer for long-range contacts | P2-02 | done |
| P2-05 | Materials: per-residue colour via mesh parts and stock materials (CustomMaterial's pipeline fails on the Simulator, see METRICS.md). Bloom, depth of field, vignette and the Aurora grade outstanding | P2-02 | part |
| P2-06 | Camera: auto-orbit, drag, pinch, pan, double-tap reframe, follow-the-action. `StageCamera` fully tested | P2-02 | done |
| P2-07 | A minimal iOS/macOS app target that plays a bundled trajectory, so the renderer can actually be run and filmed | P2-02 | done |
| P2-08 | Readouts: counters, stacked structure chart, radius of gyration trace, timeline with contact ticks. Charts need P2-13 before they accumulate enough samples to show | P2-07 | mostly done |
| P2-09 | **Marc's addition:** compute meter. Reports measured frame cost against the 60 fps budget and the configured compute unit; iOS exposes no public GPU/ANE utilisation API, so it does not claim one | P2-07 | done |
| P2-10 | **Marc's addition:** the folding-progress counters panel | P2-08 | done |
| P2-13 | Move frame production off the main actor (**done**, and it fixed the Release rendering bug). Caching per-bucket materials still outstanding | P2-08 | mostly done |
| P2-11 | Snapshot tests of all four colour modes against reference images | P2-03 | todo |
| P2-12 | Assert zero geometry NaNs across a full sample trajectory | P2-01 | done |

**Order changed 2026-08-28:** P2-07, the app target, is brought forward ahead of P2-05
(materials and post-processing) and P2-06 (camera). Post-processing is a Metal pipeline whose
only real acceptance test is looking at it, and the phase gate itself is *"renderer builds and
runs on iOS Simulator and macOS from the sample provider"*. Building the grade before there is
anything to run it in would be writing shaders blind.

### Phase 2 exit gate

Machine-verifiable:
- [x] Renderer builds and runs on iOS Simulator and macOS from the sample provider — verified by screenshot, not by an exit code
- [ ] Snapshot tests of all four colour modes against reference images
- [ ] No frame-time regression above 20% versus the recorded baseline in `METRICS.md`
- [x] Zero geometry NaNs across a full sample trajectory — asserted over three real trajectories and four degenerate-input classes

Human-verifiable (**halt**):
- [ ] 60 fps sustained on device with 300 residues, confirmed in Instruments
- [ ] No visible popping when secondary structure is assigned or reassigned
- [ ] Thermal state at or below `.fair` after 3 minutes of continuous playback
- [ ] Marc signs off that it looks like a concert, not a workbench

### Phase 2 — added by Marc, 2026-08-28: show the progress of folding

The theme is **use metrics to show the progress of folding**, live, while it is happening.

- **A GPU / ANE utilisation meter** during folding, showing which compute unit is doing the
  work. Pointed: the ANE compiler refuses Genie 2 and the live engine runs on the GPU, so the
  meter makes that visible rather than a footnote in METRICS.md.
- **A counters panel** during folding, covering compactness, radius of gyration, TM-score,
  secondary structure content, RMSD, hydrogen bonds, total energy and an energy landscape.
  Marc noted the list is not closed: treat it as a category.

Already available from `FoldGeometry` and `FoldFrame`, so these are wiring rather than new
science: radius of gyration, compactness against the `2.2 * N^0.38` expectation, relative
contact order, contact count, buried hydrophobic fraction, helix/sheet/coil fractions, and
mean and minimum confidence.

**Needs a decision before promising the rest.** Hydrogen bonds and total energy need more
than a CA trace and Genie 2 emits CA only. TM-score and RMSD need a reference structure, which
a *generated* protein does not have: they fit the PathDiffusion named gallery, not live
generative mode. Raise this on entry to Phase 2 rather than quietly dropping them.
