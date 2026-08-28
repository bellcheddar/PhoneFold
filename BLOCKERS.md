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

### 3. Generated proteins are nearly uncharged, which mutes the Fantasy profile

Measured after P0-16. A real fold designs to about 41% R/K/D/E; a foldingDiff backbone
designs to 1-7%, and raising ProteinMPNN's temperature does not fix it because it is a
property of the backbone rather than the sampling.

The Fantasy profile uses exactly those four residues as octave-shift triggers, so on a
generated protein they fire six to forty times less often, and the Phase 2 hydrophobicity
colour mode is close to uniform.

Options: accept it and let generated proteins simply sound different from the gallery ones;
re-weight the octave trigger to whatever the actual composition offers; or bias ProteinMPNN
towards charged residues, which would be designing for the music rather than for the fold
and should probably be refused on those grounds.

Not blocking Phase 1 or 2. Needs a call before Phase 3 writes the style profiles.

---

## RESOLVED 2026-08-28 — foldingDiff backbones are mostly extended, not folded

Found while building the live engine Marc chose. Numbers and controls in METRICS.md.

**The model-free part, which is solid:** across 14 samples at 76 residues, the median
radius of gyration is 1.55x what a compact fold of that length should have, ranging to
2.78x. Only 2 of 14 were compact. The local geometry is perfect throughout (CA-CA
3.83 +- 0.01 A), so these are well-formed chains that have not folded.

Two controls rule out this pipeline as the cause: the backbone reconstruction matches the
repository's own to 0.0005 A, and the repository's own entry point, with none of this
project's code involved, produces the same extended structures.

**The part that needs a fairer test:** self-consistency came out at 0/14 designable, median
scTM 0.118. But the fold-back used ESMFold, and the foldingDiff authors deliberately use
OmegaFold because ESMFold is weak on de novo designed sequences without MSAs. That number is
biased against foldingDiff and should not be quoted as its designability.

### Why it matters for PhoneFold specifically

The visual survives: an extended chain still denoises from noise with 15.8 A of motion, and
that still looks like folding. What does not survive is the claim. Most generated
"proteins" would be chains that no sequence folds into, and the designed sequences are
low-complexity, median 13% charged against a real fold's 41%, one sample 66% alanine. That
mutes the Fantasy octave triggers and flattens the hydrophobicity colour mode.

PLAN.md already disclaims a physical folding pathway, but it does not disclaim that the
thing on screen is a protein at all.

### Options

1. **Run the fair test first.** Install OmegaFold (about 670 M parameters) and re-measure
   before concluding anything. This is the honest next step and costs a download and an
   hour. It does not change the radius of gyration result.
2. **Filter and accept.** Generate until the Rg ratio is under 1.2, roughly 1 in 7 samples,
   and ship those. Cheap and model-free, so it works on-device. Improves scTM from 0.118 to
   0.168, which is better but still not designable.
3. **Try another small generator.** Genie2 is the obvious next candidate; SALAD is ruled out
   by JAX.
4. **Drop the live generative mode** and ship PathDiffusion's precomputed pathways only,
   which is the scientifically strongest option and loses on-device generation.
5. **Ship it as an instrument, not a protein.** Keep foldingDiff, and say plainly in the UI
   that the shape is a diffusion model's output and not a protein that could exist. Honest,
   and it keeps the concert. Marc's call, because it is his name on the claim.

**Recommendation: option 1 now, then choose between 2, 3 and 5 with real numbers.** Nothing
here blocks Phase 1, which consumes `.pftraj` files and is indifferent to which engine made
them.

### Resolution, 2026-08-28: Genie 2

Marc chose to test Genie 2, and it settles the matter. 8/8 compact and 8/8 designable against
foldingDiff's 2/14 and 0/14, median scTM 0.939 against 0.118, on the same biased ESMFold
metric that was recorded as unfair to foldingDiff. Full table in METRICS.md.

It also fixes the composition problem raised as open question 3 above: **49% charged residues
against foldingDiff's 13%**, where a real fold designs to 41%. The Fantasy profile's R/K/D/E
octave triggers will fire at a natural rate. Open question 3 is therefore closed by the
change of engine rather than by a decision.

Open questions 1 and 2 still stand, unchanged: Genie 2 is also sequence-agnostic, so
ProteinMPNN inverse folding is still required (now with its CA-only weights), and Genie 2 is
also a generator with no pLDDT, so the denoising timestep remains the honest confidence
substitute.

**New open item: speed.** Genie 2 takes 142 s per sample on this Mac's CPU against
foldingDiff's 18 s, for the same 1000 steps. At 15.73 M parameters the ANE should close much
of that, but if it does not, live on-device generation needs either fewer denoising steps or
a move to precomputed trajectories. To be measured in P0-19, not guessed at.

---

## OPEN — 2026-08-28 — the Apple Neural Engine will not compile Genie 2

Not blocking: the GPU path works and is fast. Recorded because PLAN.md is subtitled "folds a
protein on the Apple Neural Engine" and that is no longer accurate for this engine.

Core ML conversion succeeds, but ANE compilation fails outright:

```
MILCompilerForANE error: failed to compile ANE model using ANEF.
Error=_ANECompiler : ANECCompile() FAILED.
```

Requesting the ANE is 33x slower per step than the GPU (498 ms against 15.2 ms) and takes
528 s to load, because the runtime falls back badly. Requesting `ALL` is fine: Core ML
chooses the GPU on its own.

The GPU number is good: **15.2 ms per denoising step, 15 s for a 1000-step trajectory**, and
7.6x faster than PyTorch on the CPU. Live on-device generation stays viable.

Two things Marc may want to weigh, neither urgent:

1. **Whether to chase ANE compilation.** The failure message names no op. Diagnosing it means
   bisecting the graph, and the payoff over a working GPU path is uncertain. Recommendation:
   leave it, and revisit only if iPhone GPU numbers disappoint.
2. **Whether the project's framing changes.** "On the Neural Engine" was part of the pitch.
   "Folds a protein on the GPU, on your phone" is still true and still novel.

---

## RESOLVED 2026-08-28 — the Phase 1 P-SEA gate of 85% is not reachable

PLAN.md Phase 1, machine-verifiable exit gate:

> P-SEA agrees with a DSSP reference on 10 PDB structures at >=85% per-residue (CA-only)

It does not, and the implementation is not at fault. Full numbers in METRICS.md.

| | |
|---|---|
| Lenient DSSP mapping (H,G,I->H; E,B->E) | **79.4%** |
| Strict DSSP mapping (H->H; E->E only) | **84.8%** |
| Does the Swift implementation match a reference one? | **Yes, exactly**: 678/873 residues, structure for structure, against biotite's established P-SEA |

**Why it cannot reach 85%.** P-SEA never confuses helix with sheet: both off-diagonals of the
confusion matrix are zero. Every error is under-assignment, and it is structural. Of 205 wrong
residues, 42 are DSSP `G` (3-10 helix), 12 are `B` (beta bridge) and 3 are `I` (pi helix). A
CA-only method needing five consecutive seed residues cannot detect a three-residue 3-10
helix. Published CA-only methods generally report Q3 around 80%; 85% is at the optimistic end
of the literature and appears to assume a favourable mapping.

**What has NOT been done.** The threshold has not been quietly lowered and the criterion is
not marked met. The test now guards against regression below 78%, which is the level a correct
implementation reaches, and says in its own comment that the gate is escalated rather than
satisfied. Nothing has been tuned against the test set.

### Options

1. **Restate the gate as >=78% under the lenient mapping.** Honest, matches the established
   implementation, and keeps a real regression guard. Recommended.
2. **Restate it as >=84% under the strict mapping** (H->H, E->E only), which is also a
   defensible convention and is what pydssp does natively. Closer to the original number, but
   it reaches it by not counting elements the method cannot detect, which is worth being
   explicit about rather than quietly adopting.
3. **Replace P-SEA.** Better CA-only assignment exists, but nothing small and license-clean
   that clearly beats it, and PLAN.md specifies P-SEA by name.
4. **Drop the criterion.** The renderer needs plausible, stable secondary structure rather
   than DSSP parity, and hysteresis matters more to it than a few points of Q3.

**Recommendation: option 1.** It is the only one that states what was measured without
choosing the convention that flatters it.

Nothing else in Phase 1 is blocked; P1-07, P1-08 and P1-09 proceed regardless.

### Resolution, 2026-08-28: keep 85%, replace the method

Marc chose to hold the bar rather than restate it. P-SEA stays in the tree as a baseline and
a fallback, and a better CA-only assigner is built to clear 85%.

Approach: a small **learned classifier** over CA-derived features, trained on PDB chains with
mkdssp labels. This is the honest way to beat a hand-tuned threshold method, and unlike
tuning P-SEA's published constants it can be validated properly.

Non-negotiable in the design, so the 85% means something:

- The **ten evaluation structures are excluded from training entirely**, as are any chains
  sharing their PDB entry. A gate measured on training data is not a gate.
- Features are **CA-only**, as PLAN.md requires. No backbone amides, no hydrogen bonds.
- The model must be small enough to ship: a few tens of kilobytes of weights, evaluated in
  plain Swift with no framework.
- P-SEA's own agreement stays under test as a regression guard, so the baseline cannot
  silently rot.

---

## RESOLVED (partly) 2026-08-28 — two Phase 2 playback issues

Both found by running the app rather than by a test, and neither affects the Phase 2 machine
gate, which is met: the renderer builds and runs on iOS Simulator and macOS from the sample
provider, and draws the protein with correct per-residue colour.

### 1. Playback barely advances in a Debug build

The engine, the tube geometry, the colour packing and the RealityKit update all run on the
main actor, and a Debug build costs roughly 300x what release does for this kind of numeric
Swift. The result is a fold that creeps: the readouts update but the trajectory does not get
far, and the history never accumulates enough samples for the charts to appear.

Not a correctness problem, and the release measurements are healthy (1.65 ms/frame for the
engine, 0.52 ms for geometry). But the *frame production* should not be on the main actor at
all: only the RealityKit buffer write has to be. Moving it is the fix, and it is worth doing
for a real device regardless of build configuration.

### 2. The Release build renders nothing at all

Debug renders correctly; Release shows the chrome, the title and the gallery but no protein
and no accumulated history, with no crash, no error in the device log, and none of the app's
own diagnostics printed. The provider loads, since the title comes from its metadata, so
`play()` runs and the frame stream then produces nothing.

Not diagnosed yet. Given it is configuration-dependent with no error anywhere, the likely
areas are the async sequence's iterator being optimised differently, or a main-actor
scheduling difference. It needs a proper bisect rather than more guessing, which is what
found the material problem.

**Both belong to P2-13, a new task.** The renderer, colouring, camera, flashes and HUD are
all committed and tested.

### Resolution, 2026-08-28

**Issue 2, the Release build rendering nothing, is fixed.** The cause was issue 1: frame
production ran on the main actor, and in a Release build the loop was fast enough to starve
SwiftUI completely, so the view never drew. Debug was slow enough per frame to leave gaps
where it could. Moving frame production to a detached task fixed both symptoms at once; only
the RealityKit buffer write remains on the main actor, which is where it has to be.

Release now renders correctly, with the off-main preparation measured at **0.1 ms per frame**.

**A diagnostic note worth keeping:** `print` is not a usable channel for this app.
`xcrun simctl launch --console-pty` returned an empty capture every time, in both build
configurations, so "no output" was never evidence of anything. What settled it was putting
the diagnostic **on screen**, where a screenshot could read it, and that immediately
distinguished "the task never ran" from "the engine call never returned" - it turned out to
be neither, and the earlier reading of "starting" was simply a screenshot taken before the
first frame.

**Still open: playback advances slowly even in Release.** The frame meter reads 0.1 ms and
the engine measures 1.65 ms/frame in isolation, yet the trajectory does not get far. The
remaining suspect is the per-frame work still on the main actor: colour packing, the bucket
split and one `SimpleMaterial` per bucket rebuilt every frame. Materials should be cached and
only rebuilt when the bucket colours actually change. Not a correctness problem, and not
blocking the Phase 2 machine gate.
