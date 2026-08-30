# PhoneFold `Tools/`

Phase 0 (Model Forge) is Python work. Everything here produces artefacts the Swift side
consumes; nothing here ships in an app bundle.

## Environment

```bash
./Tools/setup_env.sh          # creates Tools/.venv and installs Tools/requirements.txt
source Tools/.venv/bin/activate
```

**Python 3.12 (Homebrew), not the system 3.14.** PyTorch publishes no 3.14 wheels.

### Installed and verified 2026-08-28

| Package | Version | Note |
|---|---|---|
| torch | 2.9.1 | MPS backend available on this M1 Max |
| transformers | 4.57.1 | supplies `EsmForProteinFolding` |
| accelerate | 1.10.1 | |
| coremltools | 9.0 | |
| numpy | 2.1.3 | |
| scipy | 1.15.3 | |
| biotite | 1.6.0 | mmCIF I/O and the structure comparison in the accuracy regression |

### Why ESMFold comes from `transformers`, not `fair-esm`

`fair-esm[esmfold]` depends on OpenFold, whose fused attention kernels are written in CUDA
and do not build on Apple Silicon. The `transformers` implementation
(`EsmForProteinFolding`) is pure PyTorch, runs on CPU and MPS, and is the same set of
weights (`facebook/esmfold_v1`). It is also the graph that has to be traced for the Core ML
export in P0-08 and P0-09, so tracing the implementation we already run avoids a second
source of divergence.

### Known risk: torch 2.9.1 against coremltools 9.0

coremltools prints, on import:

```
Torch version 2.9.1 has not been tested with coremltools. You may run into unexpected
errors. Torch 2.7.0 is the most recent version that has been tested.
```

This does not affect trajectory generation (P0-05, P0-06), which never touches coremltools.
**If the Core ML conversion in P0-08 or P0-09 fails in the tracer, the first move is to drop
to `torch==2.7.0` before debugging anything else**, rather than assuming the failure is in
our graph surgery. Recorded here so that a later loop iteration does not have to rediscover it.

## Model and dataset caches

HuggingFace weights land in `~/.cache/huggingface`, deliberately outside the repo:
`~/Documents` is iCloud-backed and Optimize Mac Storage evicts large files from it. Nothing
under `Tools/.cache` or `Models/` should be assumed resident — check before a long run.

Free disk was 37 GB at the time of writing. `facebook/esmfold_v1` is roughly 5 GB.

## Scripts

| Script | Purpose |
|---|---|
| `setup_env.sh` | Create the venv and install the pinned stack |
| `verify_phase.sh <0-5> [--invariants-only]` | Machine-verifiable gate checks. `--invariants-only` is what each loop task must satisfy; the unflagged form is the phase exit gate |

### The Phase 0d engine investigation (2026-08-30)

Prototypes and measurement tools for the question *"which engine actually shows a protein
folding"*. Nothing here is wired into the app; the decision is in `BLOCKERS.md` and the
numbers are in `METRICS.md` under Phase 0d.

| Script | Purpose |
|---|---|
| `fold_metrics.py` | Shared measurements: Rg and the compact expectation, CA-only P-SEA secondary-structure content, Kabsch RMSD, TM-score, CA-CA bonds, fraction of native contacts, monotonicity |
| `fold_gradient_report.py` | Judges any trajectory (`.pftraj` or `.npz`) on whether it goes from unfolded to folded: direction, monotonicity, secondary structure formed, frames that are actually polypeptides |
| `go_model_fold.py` | Reference CA structure-based (Go) model in numpy: topology, energy, analytic forces, Langevin, and `--selftest`, which checks every force term against central finite differences |
| `go_model_fold.c` | The same potential in scalar C, ~7x faster than numpy and the honest proxy for what Swift would run on device. `--forces` prints forces for cross-checking, `--bench` times the force evaluation |
| `go_model_run.py` | Driver: builds a self-avoiding random coil, runs the C engine, reports Q, Rg, RMSD, TM and secondary-structure content, writes `.npz` |
| `go_model_budget.py` | Turns a run into the on-device question: steps to fold, compute seconds, and milliseconds per frame at a given playback length |
| `morph_baseline.py` | The interpolation baseline (Cartesian and torsion space) and its failure modes, so the comparison in BLOCKERS.md is measured rather than argued |

`go_model_fold.c` is compiled on demand by `go_model_run.py` into `go_model_fold_bin`
(`clang -O2 ... -lm`). The binary is a build artefact and is not committed.

## The `.pftraj` trajectory container

A bundled sample trajectory. Little-endian throughout; every Apple platform PhoneFold
targets is little-endian and this is not an interchange format for anyone else.

```
offset  size            field
0       8               magic, ASCII "PFTRAJ01"
8       4    uint32     format version (currently 1)
12      4    uint32     JSON metadata length in bytes, M
16      M               TrajectoryMetadata as UTF-8 JSON, sorted keys
16+M    4    uint32     residue count, N
+4      4    uint32     readout count, F
then F records, each:
        4    uint32     recycle
        4    uint32     blockIndex
        N*12 float32    backbone, residue-major, atom order N, CA, C, O, xyz each
        N    float32    pLDDT, AlphaFold 0...100 scale
```

Uncompressed, because the app memory-maps these and streams them against the audio clock;
a decode stall would be audible.

### What is deliberately NOT in the file

Secondary structure, contact events, radius of gyration, mean pLDDT and every interpolated
frame. All of those are **derived at load time by `FoldGeometry`**.

Storing them would create a second source of truth that could silently disagree with the
live path, and would let a bundle ship a P-SEA assignment the shipping P-SEA implementation
would never produce. The bundle stores only what the model actually emitted.

### Provenance is a required field

`TrajectoryProvenance` has exactly three cases: `esmfold-trunk-readout`,
`coreml-trunk-step` and `test-fixture`. There is no case for a synthesised or interpolated
trajectory, because PLAN.md section 0.6 forbids a file that would need one. A `test-fixture`
bundle must never be shipped in an app bundle or shown to a user as a fold; the Phase 0 gate
checks for this.

Key sorting in the metadata JSON is fixed (`.sortedKeys`), so encoding is deterministic and
a bundle can be hashed into `Models/manifest.json`.
