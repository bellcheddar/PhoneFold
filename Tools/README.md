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
