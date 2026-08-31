# PhoneFold — STATE

**Current phase:** 3 (The score). Phase 0's engines are done and Phase 2's machine gate stays GREEN.
**Current task:** P4-06. Phase 3's machine gate is GREEN; what remains of it is Marc's ears (BLOCKERS.md) and the Phase 2 sign-off. Marc answered the wizard on 2026-08-30: keep Genie 2 as a third mode, Simulate as the default, gallery references unchanged, and **do all four** of the next-work options - so Phase 3, the Phase 2 sign-off, engine hardening and polish are all in scope. Polish is done (P2-15).
**Last updated:** 2026-08-30

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

### Phase 0d — which engine actually shows a fold (investigation, 2026-08-30)

Marc asked for a real unfolded-to-folded gradation computed on the device. This was a survey
and a prototype, not an engine change: **nothing in the app was modified and no bundled
trajectory was touched.** The decision is written up for Marc in `BLOCKERS.md`; the
measurements are in `METRICS.md` under Phase 0d and the literature in `MODEL_SURVEY.md`.

| ID | Task | Deps | Status |
|---|---|---|---|
| P0-27 | Survey fourteen generative candidates against the trajectory question, with licences | — | done: none produces a folding pathway for a named protein |
| P0-28 | `Tools/fold_gradient_report.py` + `fold_metrics.py`: judge any trajectory on direction, monotonicity, secondary structure formed and CA-CA sanity | — | done |
| P0-29 | Re-examine foldingDiff on trajectory shape rather than sample quality | P0-28 | done: it expands, and its ordered structure appears only in the last tenth |
| P0-30 | Prototype a CA structure-based (Go) model, numpy + C, with force controls | P0-28 | done: 9 of 9 named proteins fold, 0.6-3.3 A RMSD |
| P0-31 | Measure the interpolation morph baseline so it is compared, not argued | P0-28 | done: 0.20 A closest approach, clashes in 190 frames of 200 |
| P0-32 | Ranked recommendation in `BLOCKERS.md` | P0-27..31 | done — Marc chose all three engines |
| P0-33 | Port the structure-based model to Swift, validated against the C by forces | P0-30 | done: worst relative force disagreement below 1e-9, 18.93 us/step against the C's 19.15 |
| P0-34 | The morph engine, in torsion space | P0-31 | done: bonds hold 3.68-3.89 A where Cartesian collapses them to 0.55 |
| P0-35 | `FoldingEngine`: three engines, each owning its provenance and disclosure | P0-33, P0-34 | done |
| P0-36 | Fetch a reference structure from AlphaFold by accession | P0-35 | done: URL asked for, not built — `model_v4` is 404 today |
| P0-37 | The engine picker, and a fold computed on the device | P0-35 | done: trp-cage folds live, 87% native contacts |
| P0-38 | Neighbour list for the non-native repulsion | P0-33 | done: 45.3 s to 20.9 s for a complete fold, same destination |
| P0-39 | Investigate longer runs against arrival at the reference | P0-38 | done: **cooling beats running longer** — 0.86 A to 0.23 A for free |
| P0-40 | Accession field: type one, watch that protein fold | P0-36, P0-37 | done: haemoglobin alpha, 142 residues, 99% native contacts |
| P0-41 | Genie 2's cosine schedule and Frenet frames in Swift | P0-35 | done: matched to float32's own precision |
| P0-42 | Genie 2's reverse process driving Core ML on the device | P0-41 | done: mean CA-CA 3.94 A; some seeds diverge, retried, **workaround not a fix** |
| P0-43 | All three engines live in the app | P0-37, P0-42 | done |
| P2-15 | Polish: the counter strip clipped on a phone, trace labels sat on their traces, Genie 2 could not re-roll | P0-43 | done — and fixed a double-start that reported "cancelled" over a healthy run |

### Phase 3 — the score

The mapping is the competitive argument, so it is built pure and tested before any audio
hardware: a wrong note is a bug you can assert on, and a wrong note through a speaker is a
matter of opinion.

| id | task | depends | status |
|---|---|---|---|
| P3-01 | Musical primitives: scales, modes, pitch, and a deterministic seed from the sequence | — | done |
| P3-02 | Style profiles as declarative JSON, loaded and validated | P3-01 | done |
| P3-03 | The sonification mapping: PLAN's table, trajectory features to musical events | P3-01, P3-02 | done |
| P3-04 | The musical clock: fixed tempo, jitter buffer, never blocks on inference | P3-03 | done |
| P3-05 | Audio output: **synthesised voices, spatial from the start** — Marc's call, 2026-08-30 | P3-04 | done |
| P3-06 | Wire the score into the app: conductor, sound toggle, one shared clock | P3-05 | done |
| P3-07 | MIDI event log and export, round-tripped | P3-03 | done |
| P3-08 | The remaining four styles: Jazz, Rock, Pop, Surf | P3-02, P3-03, P3-05 | done |
| P3-09 | Live style switching, beat-quantised, never a restart | P3-08 | done |
| P3-10 | CoreHaptics on iPhone and Watch: contact transients, core rumble, convergence | P3-06 | done |
| P3-11 | Style picker, sound toggle and MIDI export in the app; Tay et al. citation in About | P3-08, P3-07 | done |
| P3-12 | Swing applied to note placement | P3-08 | done |

**Marc's decisions, 2026-08-30.** Voices are **synthesised**, not sampled: no SoundFont, so
PLAN's licence halt cannot arise and there is nothing to redistribute. **Fantasy is built all
the way through first** and the other four follow the pattern. **Spatial audio is built in from
the start** rather than layered on — Marc overrode the recommendation, so the environment node
shapes the voice architecture instead of being retrofitted, and every note carries the residue
whose coordinate places it. He wants to hear it **as soon as it first makes a sound**, which is
the end of P3-05.

| P0-44 | macOS sandbox entitlement for network access, needed for an App Store build | P0-36 | done — both keys in the signed binary, no sandbox denials; the fetch itself wants one look on an unlocked screen |

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
| P2-05 | Materials: per-residue colour via mesh parts and stock materials. Grade delivered as an object-space halo plus a composited vignette; screen-space bloom and depth of field are not reachable here - five APIs measured in METRICS.md, and the only one that would work needs a physical device | P2-02 | done |
| P2-06 | Camera: auto-orbit, drag, pinch, pan, double-tap reframe, follow-the-action. `StageCamera` fully tested | P2-02 | done |
| P2-07 | A minimal iOS/macOS app target that plays a bundled trajectory, so the renderer can actually be run and filmed | P2-02 | done |
| P2-08 | Readouts: counters, stacked structure chart, radius of gyration trace, timeline with contact ticks. Charts need P2-13 before they accumulate enough samples to show | P2-07 | mostly done |
| P2-09 | **Marc's addition:** compute meter. Reports measured frame cost against the 60 fps budget and the configured compute unit; iOS exposes no public GPU/ANE utilisation API, so it does not claim one | P2-07 | done |
| P2-10 | **Marc's addition:** the folding-progress counters panel | P2-08 | done |
| P2-13 | Move frame production off the main actor (**done**, and it fixed the Release rendering bug); per-bucket materials cached | P2-08 | done |
| P2-14 | Playback: stop driving the 3D view through SwiftUI state at 60 fps, and throttle the HUD. Marc asked for this before the sign-off. Also fixed the backbone drawing in pieces: `LowLevelMesh.Part.indexOffset` is a byte offset, not an index count | P2-13 | done |
| P2-11 | Snapshot tests of all four colour modes against reference images | P2-03 | done |
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


## Phase 4 — big screen, capture, and the iPhone ship

Ordered so that everything a machine can finish comes before anything needing a device, an
Apple TV or Marc's account. The exports are first because they are pure functions over data
that already exists, and because three of the four gate criteria are about them.

| id | task | depends | status |
|---|---|---|---|
| P4-01 | mmCIF export: final model with pLDDT in the B-factor column, and a multi-model trajectory | — | done |
| P4-02 | Offscreen render pass at export resolution, driven by the same frame stream | — | done |
| P4-03 | `AVAssetWriter` video plus audio; H.264 and HEVC | P4-02 | done |
| P4-04 | Export presets (1920x1080, 1080x1920, 4K) and the optional burned-in overlay | P4-03 | done |
| P4-05 | Export UI: progress, background safety, save to Photos with permissions | P4-03 | done |
| P4-06 | Onboarding: three cards, and the permanent disclaimer in About | — | todo |
| P4-07 | Sample gallery notes: what to listen for in each of the twelve | — | todo |
| P4-08 | Accessibility: VoiceOver, Dynamic Type, Reduce Motion, colour-blind-safe palette | — | todo |
| P4-09 | Mutation duet: wild type and mutant in one key, pLDDT delta driving dissonance | P3-09 | todo |
| P4-10 | External display scene, `AVRoutePickerView`, connect and disconnect mid-fold | — | todo |
| P4-11 | Live Activity and Dynamic Island | — | todo |
| P4-12 | App icon (`marcs-vibe-icon`), privacy manifest, no analytics | — | todo |
| P4-13 | Leak check across 20 consecutive folds | P4-03 | todo |

**Needs Marc, not a machine:** AirPlay to a real Apple TV, the exported-video comparison, cold
launch on device, and signing and TestFlight. Those are the phase's human halt.

**Marc's answers, 2026-08-31:**
- **Exports:** the film goes to **Photos**; MIDI and mmCIF go through the **share sheet**, since
  Photos cannot hold them. Needs `NSPhotoLibraryAddUsageDescription`.
- **Order:** *do all of the items.* Sequenced ship-blocking first (P4-05, P4-06, P4-08, P4-12),
  then the differentiator (P4-09), then the lecture theatre (P4-10, P4-11), because that is the
  order in which a thing becomes submittable and then becomes good.
- **Genie 2:** dig for the root cause rather than shipping the seed-retry as the final answer.
  Added as P4-14.
- **Sign-offs:** keep deferring. The backlog stays in `BLOCKERS.md` and Marc will say when.

| id | task | depends | status |
|---|---|---|---|
| P4-14 | Genie 2 divergence: find the root cause, not a workaround | — | todo |
