# PhoneFold — BLOCKERS

Questions and decisions that require Marc. Each entry dated, with context, options considered,
and a recommendation. Nothing here is resolved by the agent.

**Open:** none. The trajectory question was decided on 2026-08-28, see RESOLVED below.

---

## Noted, not blocking

### 2026-08-28 — Free disk space is 41 GB

Not a halt, but worth Marc knowing before Phase 0 task P0-05 runs.

The Phase 0 export work needs, roughly: PyTorch for Apple Silicon (~2.5 GB), the ESMFold
checkpoint (~5 GB, which includes ESM-2 650M), coremltools and its intermediates during
conversion (peaks around 2-3x model size), plus the exported `.mlpackage` artefacts and Xcode
DerivedData. That is comfortably 15-20 GB against 41 GB free.

It should fit. If it does not, the agent halts rather than deleting anything.

---

## RESOLVED 2026-08-28 — ESMFold has no watchable folding trajectory

**This blocks the definition of what PhoneFold shows, so it is Marc's decision, not the
agent's.** Phase 0 tasks P0-01 to P0-04 are done and committed; the generator works and is
verified. Everything below is measured, with the control that proves the measurement.

### What PLAN.md specifies

Phase 0: *"patch the trunk so the structure module emits a coordinate readout every N blocks
(start N = 4, giving 12 frames per recycle from 48 blocks)"*.

### What that actually produces

Implemented and run. The readouts are geometrically broken. Consecutive CA-CA virtual bond
length should be 3.80 A with a spread under 0.1 A; a real polypeptide has no other option.

| Readout point | CA-CA mean +- sd (A) | Is it a polypeptide? |
|---|---|---|
| after block 4 | 5.89 +- 3.97 | no |
| after block 12 | 12.49 +- 3.95 | no |
| after block 24 | 7.39 +- 4.51 | no |
| after block 48 (end of recycle) | 3.84 +- 0.08 | **yes** |

This holds at every one of the structure module's 8 IPA layers, not just the last. The
structure module is trained to run on a *converged* trunk representation; handed a mid-trunk
state it emits incoherent frames. A backbone tube cannot be swept through a chain whose
consecutive residues are 12 A apart.

### The alternative that does work, and what it shows

Read out at the end of each recycle and take all 8 IPA layers: 8 x 4 recycles = 32 frames,
28 of which have valid geometry. **Verified bit-exact against the unpatched model**: max
coordinate difference 0.000e+00 A, max pLDDT difference 0.000e+00, on both ubiquitin and GFP.
The patching is correct; these numbers are ESMFold's own.

| Protein | aa | frames | valid geometry | max RMSD to final | Rg range (A) | pLDDT range |
|---|---|---|---|---|---|---|
| Villin HP36 | 36 | 32 | 28 | **0.76 A** | 9.1-9.8 | 82.2-92.7 |
| Ubiquitin | 76 | 32 | 28 | **0.87 A** | 11.3-12.0 | 79.9-90.8 |
| Trp-cage | 20 | 32 | 28 | **1.30 A** | 6.7-7.5 | 78.3-92.2 |
| Beta-2 AR 7TM | 314 | 32 | 28 | **1.52 A** | 23.4-25.1 | 73.7-87.4 |
| Alpha-synuclein | 140 | 32 | 8 | 14.02 A | 8.0-24.5 | 29.4-38.6 |
| GFP | 238 | 32 | 8 | 20.70 A | 13.2-20.9 | 34.0-44.8 |

Ubiquitin sits at 0.78-1.00 A RMSD to experimental 1UBQ **from IPA layer 0 of recycle 0**,
and its radius of gyration moves 12.05 to 11.41 A against an experimental 11.49 A. All four
recycles are near-identical.

**The protein is already folded before any coordinate exists.** ESMFold does its work in
representation space; the structure module is a readout, not a folding process. Where the
model is confident there is nothing to watch, and where there is motion (GFP,
alpha-synuclein) the model is failing and three-quarters of the frames are not polypeptides.

GFP's mean pLDDT of 43.3 is real, not a bug: it matches the unpatched model exactly.
ESMFold genuinely fails on this beta-barrel without an MSA.

### Why this is a decision and not a bug

The app's headline visual is secondary structure forming and the chain collapsing, and the
score maps contact formation to note onsets. With 0.8 A of total motion there are almost no
contact formation events, so both the picture and the music lose their subject.

PLAN.md's own Phase 4 disclaimer already says *"PhoneFold visualises how a neural network
converges on a structure. It is not a physical folding pathway."* Option A below is exactly
that and nothing more.

### Options

**A. Ship the refinement trajectory.** What works today. 32 valid frames, honest, bit-exact
with the model. The app becomes "watch a prediction sharpen": the structure firms up, pLDDT
climbs 80 to 91, colour resolves orange to blue. The AlphaFold-ramp money shot still lands.
Almost no contact-formation events on confident targets, so the score leans on pLDDT,
radius of gyration and recycle boundaries rather than note onsets. Zero extra work.

**B. Mid-trunk readouts anyway, with a different visual language.** Genuinely dramatic
motion, but frames are not polypeptides, so no backbone tube: it would have to be a point
cloud or exploding fragments. Defensible as "the network's internal state" but needs a much
stronger disclaimer and a Phase 2 rewrite.

**C. Change the model to a diffusion folder (Boltz-2).** A denoising path from noise to
structure is a real trajectory, with every intermediate a plausible structure and 20-200 of
them. This delivers the app's premise properly, and Marc already knows Boltz through
BoltzMaker. Cost: Phase 0 becomes weeks rather than days, ANE export is much harder, and
live on-device folding on iPhone is probably off the table, making Cinema Mode the main path.

**D. Reframe the app around confidence rather than folding.** Least work, still novel, but
gives up the headline.

### Recommendation

**A now, C evaluated later.** Take A to unblock Phases 1 to 5: `FoldFrame`, the renderer, the
score and the exports are all indifferent to where frames come from, which is the entire
point of the provider abstraction in PLAN.md Phase 1. Then evaluate Boltz-2 denoising as an
additional `FoldFrameProvider` once the app exists. The `.pftraj` container and the
`SampleTrajectoryProvider` boundary make that swap cheap; deciding it now would block
everything on the hardest problem in the project, which is exactly what PLAN.md Phase 0 says
not to do.

**Marc must choose before Phase 2 renders anything**, because B changes the renderer
completely. Phase 1 can proceed under any of A, B or D unchanged.

### Resolution, 2026-08-28

Marc chose the hybrid, after a model survey (MODEL_SURVEY.md) and measurement (METRICS.md):

- **Live, on-device: foldingDiff.** 14.5 M parameters in a 57.9 MB checkpoint, 1000
  denoising steps, 15.29 A of motion against ESMFold's 0.87 A. The app generates a *novel*
  protein and folds it. Capped at 128 residues by the published weights.
- **Named gallery: PathDiffusion.** Real folding pathways for the twelve bundled proteins,
  precomputed offline because its MSA pipeline cannot run on a phone.

What this gives up, explicitly: **PhoneFold no longer folds an arbitrary user-supplied
accession live.** Accession input and the mutation duet apply to the precomputed gallery
only. This is a deliberate trade, not an oversight.

ESMFlow was the alternative that would have preserved live arbitrary folding. It was not
chosen; its partial download has been removed to keep disk free for PathDiffusion's MSA
databases.

---

## OPEN — 2026-08-28 — two consequences of the foldingDiff decision that need a call

Neither blocks Phase 1. Both must be settled before Phase 3 writes the score.

### 1. foldingDiff produces no sequence, and the score needs one

foldingDiff generates a **backbone only**. It has no residue identities. But the Phase 3
sonification table depends on them in three places: hydrophobicity of both contact partners
(the long-range hydrophobic contact is the bass note and the haptic transient), R/K/D/E as
the Fantasy profile's octave-shift triggers, and the Kyte-Doolittle colour mode in Phase 2.

The standard companion is **ProteinMPNN inverse folding**, which is what the foldingDiff
paper itself uses to assess designability. It is about 1.7 M parameters, PyTorch, and would
add roughly 7 MB to the bundle: negligible next to foldingDiff's 58 MB, and it fits the ANE
trivially. Recommendation: adopt it, and run it once on the final backbone so the whole
trajectory carries one consistent designed sequence.

### 2. foldingDiff has no pLDDT

It is a generator, not a predictor, so there is no confidence to report. The score maps
mean pLDDT to low-pass cutoff, detune and reverb, per-residue pLDDT to note velocity, and a
pLDDT plateau to the closing cadence. In live mode there is nothing behind any of those.

The honest substitute is the **denoising timestep** itself: it is literally how resolved the
structure is, it moves monotonically, and it drives exactly the same musical axis. It must
not be called pLDDT anywhere in the UI or the code.

That implies an API change in `FoldCore`: `FoldFrame.pLDDT` becomes a per-residue
`confidence` carrying a `ConfidenceSource` (`.pLDDT` for predictor-sourced trajectories,
`.denoisingProgress` for generated ones), so the About panel and the readouts can say which
one they are showing. Recommendation: make this change at the start of Phase 1, before
anything consumes the field.
