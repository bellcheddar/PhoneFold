# PhoneFold — STATE

**Current phase:** 0 (Model Forge)
**Current task:** P0-02
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
| P0-02 | `FoldCore` value types: `FoldFrame`, `BackboneResidue`, `SSAssignment`, `ContactEvent`, `AminoAcid`. `Sendable`, no `#if os`. Unit tested | P0-01 | todo |
| P0-03 | Trajectory bundle format (`.pftraj`): versioned container spec in `Tools/README.md` + Swift reader/writer in `FoldCore` with round-trip tests | P0-02 | todo |
| P0-04 | `Tools/` Python environment: venv on python3.12, pinned `requirements.txt`, `Tools/README.md` documenting exact versions | — | todo |
| P0-05 | Trajectory generator `Tools/make_sample_trajectories.py`: runs real ESMFold, captures a coordinate readout every N blocks, writes `.pftraj`. **Real inference only — no synthesised trajectories** | P0-03, P0-04 | todo |
| P0-06 | Produce the 12 bundled trajectories (ubiquitin, GFP, lysozyme, insulin, myoglobin, GPCR fragment, IDR, designed all-alpha bundle + 4 of Marc's choosing) into `Apps/Shared/Resources/Trajectories/` | P0-05 | todo |
| P0-07 | `SampleTrajectoryProvider` in `FoldEngine`: loads a `.pftraj` and emits `AsyncStream<FoldFrame>` at wall-clock rate. Tests | P0-06 | todo |
| P0-08 | Export ESM-2 650M to Core ML: fp16, ANE layout, enumerated length buckets 64/128/192/256/320/384, 6-bit palettisation | P0-04 | todo |
| P0-09 | Export the stateful trunk step model (`MLState`), coordinate readout every N=4 blocks | P0-08 | todo |
| P0-10 | `Tools/bench_ane.py` + on-device XCTest harness; write results to `METRICS.md` | P0-09 | todo |
| P0-11 | Accuracy regression: 20 proteins, TM-score / GDT-TS / mean pLDDT delta vs full precision. Halt if TM-score loss > 0.05 | P0-09 | todo |
| P0-12 | `Models/manifest.json` with hashes, source checkpoint, toolchain versions, buckets, measured deltas | P0-11 | todo |
| P0-13 | Mac fp16 unpalettised variant, buckets to 640 | P0-11 | todo |

### Phase 0 exit gate

Machine-verifiable:
- [ ] `.mlpackage` files load and predict in an XCTest on the Simulator without crashing
- [ ] Accuracy regression table written to `METRICS.md`, all deltas within tolerance
- [ ] Sample trajectory bundle present and loading in `Apps/Shared/Resources/`

Human-verifiable (**halt**):
- [ ] ANE residency confirmed on device in Instruments
- [ ] Real-device frames per second acceptable to Marc across all six length buckets
- [ ] Marc approves the accuracy trade-off before it is baked in

---

## Phase 1 — Fold engine and frame stream

Not yet decomposed. Decompose on entry to Phase 1.

## Phases 2-5

Not yet decomposed. Decompose on entry to the phase.
