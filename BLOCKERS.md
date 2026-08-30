# PhoneFold — BLOCKERS

Questions and decisions that require Marc. Each entry dated, with context, options considered,
and a recommendation. Nothing here is resolved by the agent.

**Open:** the Phase 2 exit gate needs Marc (checklist below), and - added 2026-08-30 -
**which engine gives PhoneFold a real folding trajectory**, at the end of this file.

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

---

## HALT — 2026-08-28 — Phase 2 exit gate needs Marc and a device

The **machine gate is GREEN**: `Tools/verify_phase.sh 2` passes every check, including the
release suite, the colour snapshots, the frame budget, the zero-NaN assertion, and an app
build for both iOS Simulator and macOS.

PLAN.md's Phase 2 human-verifiable criteria cannot be checked by an agent, and none of them
has been ticked. They need real hardware, Instruments, and Marc's eyes.

### Checklist for Marc

- [ ] **60 fps sustained on device with 300 residues, confirmed in Instruments.** Everything
      measured so far is Simulator or Mac. The CPU side leaves 84% of the frame free
      (2.65 ms of 16.7 ms at 314 residues), but the draw cost on a phone is unmeasured.
- [ ] **No visible popping when secondary structure is assigned or reassigned.** The cross
      section morphs with confidence and there is three-frame hysteresis, so it should grow
      rather than snap. Whether it actually reads that way is a judgement.
- [ ] **Thermal state at or below `.fair` after three minutes of continuous playback.**
- [ ] **Marc signs off that it looks like a concert, not a workbench.**

### What is worth knowing before looking at it

- The renderer draws per-residue colour through **mesh parts with stock materials**, not a
  custom shader: `CustomMaterial`'s pipeline fails to compile on the Simulator and the failure
  is silent. On a real device the custom shader may well work, and it is still in the tree
  behind `PHONEFOLD_CUSTOM_SHADER`. Worth trying on hardware, because it would restore proper
  lighting and the emissive rim.
- ~~Playback advances slowly and starts inconsistently.~~ **Fixed (P2-14).** It was paced by
  SwiftUI: the prepared mesh was `@Published`. Five cold launches now reach an identical final
  state. Fixing it exposed a second bug, a backbone drawn in cleanly capped pieces, which was
  a byte-versus-index offset in `LowLevelMesh.Part`.
- ~~Post-processing is not built.~~ **Partly built (P2-05).** There is now an object-space
  halo around the backbone and a composited vignette, on PLAN.md's indigo ground. There is no
  screen-space bloom and no depth of field, and there is a decision about that below.

### Deferred, and still deferred

Phase 0's ProteinMPNN Core ML export, the extra Genie 2 length buckets, and the whole
PathDiffusion gallery (Phase 0c). Reasons in STATE.md.

## Phase 2 — one decision for Marc, at the sign-off

**Screen-space bloom and depth of field: pursue on device, or leave as delivered?**

The stage now has an object-space halo and a composited vignette, and both are verified on the
Simulator. What is *not* there is true HDR bloom and a real depth of field, because both need
the rendered colour and depth textures and every route to them was measured as unavailable
here - the table is in METRICS.md.

`ARView.renderCallbacks.postProcess` is the exception worth naming: it is the one API that
exposes `sourceDepthTexture`, it would deliver both effects properly, and it traps on
assignment on the Simulator. It may work perfectly on hardware. There is no device paired with
this machine, so it could not be tried.

This is a decision rather than a blocker because the work is complete without it, and because
the Phase 2 gate already halts for a device check. Options:

1. **Leave it.** The halo and vignette carry the look, and the code stays one renderer with no
   `#if os` fork. Recommended unless the glow disappoints on a real screen.
2. **Try `ARView` on device.** Needs an iPhone or iPad paired to this Mac. It forks the stage's
   host view - `ARView` does not exist on visionOS, so Phase 5 would keep `RealityView` and the
   two paths would need to stay in step.

Nothing downstream is waiting on this: it can be revisited any time after Phase 2.

---

## OPEN — 2026-08-30 — the engine that would actually show a fold

Marc: *"The current trajectories are too short and don't show folding. I want to see a
gradation from fully unfolded to fully folded with ordered secondary structure. All compute
done ON DEVICE, no precompute, and a clear gradient from unfolded to folded."*

Nothing is blocked by this: Phase 2's gate is GREEN and the app still plays what it plays.
**No engine has been changed and no bundled trajectory has been touched.** This is a decision
about what PhoneFold folds, and it is Marc's.

Everything below is measured on identical criteria by `Tools/fold_gradient_report.py` -
radius of gyration per frame, CA-only P-SEA secondary-structure content per frame, CA-CA bond
length, contacts - with the full tables in METRICS.md under **Phase 0d**. The literature and
the licences are in MODEL_SURVEY.md.

### The finding that decides it

**No published generative model produces a folding pathway for a named protein.** Fourteen
were checked. Genie 2, RFdiffusion and ProtPardelle *expand* out of a noise ball; FrameDiff,
Chroma and AlphaFlow reorganise at roughly constant size; EigenFold and Proteina go
coarse-to-fine. foldingDiff's own peer-reviewed paper removed the folding claim its preprint
made. The one model that does claim pathways, PathDiffusion, needs an MSA and cannot run on
a phone. Chroma's and Proteina's weights are non-commercial, which is a blocker regardless.

So the choice is not "which diffusion model" - it is **whether PhoneFold shows a generated
protein assembling itself, or a named protein folding.**

### The four options, measured

| | Genie 2 (today) | **CA structure-based (Go)** | foldingDiff | Coil-to-native morph |
|---|---|---|---|---|
| What the chain does | Rg **1.22 -> 10.83 A**: expands out of a blob | Rg **21.3 -> 11.7 A**: collapses onto the fold | Rg 10.1 -> 22.1 A: expands, ends extended | Rg 21.3 -> 11.4 A: collapses |
| Ordered SS, first -> last | 0.00 -> 0.75 | 0.00 -> 0.38 (native 0.43) | 0.00 -> 0.71, all of it in the last tenth | 0.00 -> 0.43 |
| Frames that are polypeptides | **3 / 11** | **11 / 11** | 3 / 11 | 200/200 (torsion), 30/200 (Cartesian) |
| Closest non-bonded approach | - | 3.59 A | - | **0.20 A: chains pass through each other** |
| A named protein? | **no** | **yes** - 9 of 9 folded, RMSD 0.6 - 3.3 A | no | yes, but it is not folding |
| Model on disk | 33.8 MB `.mlpackage` | **912 bytes** (the native CA trace) | 57.9 MB | 912 bytes |
| Peak memory | not measured on device | **1.5 MB** at 76 residues | - | trivial |
| Compute for one fold | 15 s at 64 aa (Core ML, Mac GPU) | **2.3 s** at 76 aa, 28 s at 153 aa (one CPU core) | 18 s at 76 aa (PyTorch CPU) | free |
| Fits a 60 fps frame? | 15.2 ms per denoising step on the Mac GPU, and its blob prefix already measured **19.8 ms/frame** in the app on the contact tracker alone - **it does not** | **1.3 ms/frame** at 76 aa over a 30 s playback; 15.7 ms at 153 aa | untested | yes |
| Licence | Apache-2.0 | **none needed** - written from published equations (Clementi et al. 2000). SMOG2 is GPL and was not touched | MIT | n/a |
| Compute unit | GPU (ANE refuses to compile it) | CPU, no Core ML, no weights | - | CPU |

### 1. Recommended: the CA structure-based model, for the named gallery

Take a named protein's known structure, build a potential whose minimum is that structure, and
integrate Langevin dynamics from a self-avoiding random coil. Measured on nine of the bundled
proteins: **9 of 9 reach the native state**, 0.6 to 3.3 A RMSD, secondary structure rising
from **zero** to within a few points of the native content, every frame a valid polypeptide,
5 of 5 seeds folding on ubiquitin, and bit-identical replay from a fixed seed.

**Trade-off in one sentence:** it is a real folding pathway for the protein whose name is on
the screen, and it is a *simulation towards a structure that is already known* rather than a
prediction, so the app must say so.

What it also buys, none of which the current engine can offer: TM-score and RMSD readouts have
a reference to be measured against (the Phase 2 counters panel asked for exactly this); the
protein has its real sequence, so hydrophobicity colouring and the Fantasy profile's R/K/D/E
triggers fire at a real fold's 41% rather than a designed backbone's 13%; ProteinMPNN leaves
the live path entirely; and contacts form one at a time in a physical order, which is the
subject the Phase 3 score was written for.

What it costs: **no ANE and no GPU** - it is arithmetic on one CPU core, so PLAN.md's
"on the Neural Engine" drifts further from the truth; the practical ceiling is about **150
residues**, with 314 measured as four failures - the best of them formed the secondary
structure (0.03 -> 0.75 against a native 0.78) and never packed the bundle (TM 0.050); and the app needs the native coordinates,
which is 912 bytes bundled per gallery protein, or a fetch from the PDB or AlphaFold DB for an
arbitrary accession. **That fetch would restore the feature the Genie 2 decision gave up:
type an accession, watch that protein fold, computed on the phone.** A downloaded reference
structure is not a precomputed trajectory - every frame is still computed on the device.

### 2. Keep Genie 2 as the "generate a protein" mode

It is exported, it works, and it is the only thing here that invents a protein. Its trajectory
is a real generative path and a poor fold: it expands rather than collapses, its first 35
steps are a degenerate blob measured at 19.8 ms/frame against a 16.7 ms budget, and 8 of 11
sampled frames are not polypeptides.

**Trade-off:** a genuine trajectory of a protein that never existed, versus a genuine folding
pathway of one that does. They are different acts in the same concert and the app can hold
both - the provider abstraction was built for exactly this.

### 3. foldingDiff: re-examined as asked, and it stays rejected

The earlier rejection was about sample quality; this one is about the trajectory. Across three
fresh seeds it **expands** (final Rg/expected 1.25, 1.52, 1.94 - extended, not folded), only
2-3 frames in 11 are polypeptides, and its ordered structure appears entirely in the last
tenth of the run rather than growing. Its own authors removed the folding claim between the
preprint and the paper.

### 4. The morph: only ever as a labelled transition

Interpolating a coil into the native gives a perfect gradient and impossible physics: minimum
non-bonded CA-CA distance **0.20 A**, with a clash in 190 of 200 frames. Chains pass through
each other on screen. If it is ever used it must be labelled *"morph, not a fold"* in the
frame itself and never carry a provenance that suggests a model produced it. Recommendation:
do not use it.

### What I would pick

**Option 1 for the gallery, keeping option 2 as a second mode.** It is the only thing measured
that satisfies Marc's sentence end to end - unfolded to folded, secondary structure appearing
from nothing, on device, no precompute, and a clear gradient - and it does it for a protein
with a name, at 912 bytes and 1.3 ms of a 16.7 ms frame.

**What would change my mind**

- If the point of the app is that it *predicts* structure, this is the wrong engine: it is
  handed the answer. Genie 2 at least invents something.
- If a Swift implementation on a phone measures far off the C figures here. That is one
  afternoon's work to find out and it has not been done.
- If Marc will not accept a fetched reference structure for arbitrary accessions, the gallery
  is limited to what is bundled.
- If PathDiffusion turns out to run without its MSA pipeline, it is the scientifically
  strongest answer and it would displace this.

**Not blocking anything.** Phase 2's human sign-off is still the open item, and Phase 3 can
start on the current trajectories whatever is decided here.

## OPEN — 2026-08-30 — Genie 2 cannot fold toward a reference, and was asked to

Marc's instruction was three selectable engines — Genie 2, Gō and Morph — and, for **all** of
them, to "aim to finish on the target reference structure from the AlphaFold DB". Two of the
three do exactly that. Genie 2 cannot, and this is a property of the model rather than a
configuration:

- It is **unconditional**: it samples a backbone from Gaussian noise. There is no target to
  fold toward and no place to put one. Genie 2 *does* support motif scaffolding upstream, but
  that conditions on a fragment to build around, not on a whole structure to converge to, and
  it is not in the exported model.
- The export is **fixed at 64 residues**. A different length needs a new export from the
  checkpoint, and no length would make it target a structure.
- Its trajectory runs the other way from a fold: measured, the radius of gyration **climbs**
  from 1.7 A as the noise ball opens out, where the structure-based engine's descends.

So the app currently presents it as a third act rather than a third fold: "Generate", labelled
*"Genie 2 invents a backbone from noise. Not a named protein"*, and the finished trajectory
carries *"Generated — this protein has never existed"*.

**The options, in the order I would rank them:**

1. **Keep it as it is.** Two engines fold toward a reference, one generates. The distinction is
   visible in the picker, in the disclosure and in the radius-of-gyration trace itself. This is
   what is built and it is coherent.
2. **Drop Genie 2.** If the app's claim is strictly "watch a named protein fold", a generative
   engine muddies it, and the 64-residue ceiling makes it a curiosity rather than a feature.
   The code would stay in the repository and out of the picker.
3. **Replace it with something conditionable.** PathDiffusion claims genuine folding pathways
   for named proteins and would be the scientifically strongest answer — but it needs an MSA
   pipeline that cannot run on device, which is why Phase 0d rejected it. Nothing else surveyed
   both targets a structure and runs on a phone.

**Not blocking anything.** All three engines work today; this is about what the app should
claim, which is Marc's call and not a technical one.

## Phase 3: how long is a fold? (2026-08-30)

**Decided provisionally, and Marc may want to move it.**

The app used to play every trajectory in about 12 seconds (`FoldPlayer.pace`, `targetSeconds:
12`), which Marc asked for during Phase 2 when a trajectory was eight ESMFold readouts. A live
fold is now 180 readouts, and a 180-readout piece of music at the Fantasy style's 66 to 132 BPM
runs **82 to 164 seconds**. Both numbers are defensible and they cannot both stand: at 12
seconds the music is cut off after about a tenth of itself, and the animation shows fifteen
readouts a second.

What is in the build now: **the animation follows the music.** With sound on, a readout stays on
screen for one beat at the style's midpoint tempo, so a live fold takes about **two minutes**
and a gallery reference about **ten seconds** (they get two beats a readout, because eight
readouts at one beat each is six seconds and not a phrase). With sound off, the old 12-second
pace is unchanged.

Measured, Fantasy style: trp-cage under the structure-based model 91.1 s; villin HP36 morph
121.9 s; lysozyme gallery 9.8 s.

**The knob** is `ScoreConductor.secondsPerReadout` and `Sonifier.beatsPerMoment(forReadouts:)`.
Faster means either a higher tempo range in the style file, which changes the character, or
fewer musical events per readout, which throws contacts away. Slower is free.

Marc: two minutes to watch a protein fold with its music, or something shorter?

## Phase 3: what needs Marc's ears

The machine gate covers determinism, clipping, loudness and audio-thread allocation. It cannot
cover any of this:

- [ ] The Fantasy style sounds like Fantasy, and like music, rather than like a sonification
- [ ] The spatial mix reads as a protein collapsing around the listener, on headphones
- [ ] An intrinsically disordered protein (alpha-synuclein) audibly never resolves
- [ ] The two-minute duration above is right, or is not
