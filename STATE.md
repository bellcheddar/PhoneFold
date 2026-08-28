# PhoneFold — STATE

**Current phase:** 0 (Model Forge)
**Current task:** P0-14
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

### Phase 0b — the foldingDiff live engine

| ID | Task | Deps | Status |
|---|---|---|---|
| P0-14 | Add `foldingdiff-denoising` and `pathdiffusion-pathway` to `TrajectoryProvenance` in both `FoldCore` and `Tools/pftraj.py`; extend the cross-language fixture test | P0-03b | todo |
| P0-15 | `Tools/make_foldingdiff_trajectories.py`: sample a backbone, capture every denoising step, write `.pftraj`. Real sampling only | P0-14 | todo |
| P0-16 | ProteinMPNN inverse folding on the final backbone so the trajectory carries a designed sequence the score can use (see BLOCKERS.md) | P0-15 | todo |
| P0-17 | Export foldingDiff to Core ML: 14.5 M parameters, fp16, ANE layout, length buckets to 128 | P0-15 | todo |
| P0-18 | Export ProteinMPNN to Core ML | P0-16 | todo |
| P0-19 | `Tools/bench_ane.py` + on-device XCTest harness; results to `METRICS.md` | P0-17, P0-18 | todo |

### Phase 0c — the PathDiffusion named gallery

| ID | Task | Deps | Status |
|---|---|---|---|
| P0-20 | Stand up PathDiffusion: clone, weights, dependency audit on Apple Silicon. Halt if it needs CUDA-only kernels | — | todo |
| P0-21 | MSA pipeline for the twelve bundled sequences only. Check disk before downloading databases | P0-20 | todo |
| P0-22 | Generate the twelve named folding pathways, replacing the interim ESMFold bundle | P0-21, P0-14 | todo |
| P0-23 | `Models/manifest.json`: hashes, source checkpoints, toolchain versions, measured trajectory statistics for both engines | P0-19, P0-22 | todo |

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

Not yet decomposed. Decompose on entry to Phase 1.

## Phases 2-5

Not yet decomposed. Decompose on entry to the phase.
