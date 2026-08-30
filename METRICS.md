# PhoneFold — METRICS

Every number here comes from an actual measurement. Estimates are never recorded.
**Simulator-derived figures are marked explicitly as such**: Simulator numbers are meaningless
for ANE work.

No measurements yet.

## Phase 0 — sample trajectory generation

Measured 2026-08-28 on the M1 Max, CPU (not MPS), torch 2.9.1, transformers 4.57.1,
`facebook/esmfold_v1`, fp32. Readouts at the end of each recycle, all 8 structure-module
IPA layers, 4 recycles: 32 frames per protein.

**These are generation-time figures on a Mac. They say nothing about on-device or ANE
performance**, which is measured in P0-10 and is a human-verifiable gate.

### Control: the patched trunk reproduces the unpatched model exactly

| Protein | max CA coordinate difference | max pLDDT difference |
|---|---|---|
| Ubiquitin | 0.000e+00 A | 0.000e+00 |
| GFP | 0.000e+00 A | 0.000e+00 |

### Generated trajectories

| Protein | aa | frames | final mean pLDDT | generation (s) | file (MB) |
|---|---|---|---|---|---|
| Trp-cage TC5b | 20 | 32 | 91.1 | 2.7 | 0.0 |
| Villin HP36 | 36 | 32 | 92.1 | 3.5 | 0.1 |
| Pin1 WW domain | 34 | 32 | 92.5 | 3.6 | 0.1 |
| Protein G B1 | 56 | 32 | 88.3 | 5.4 | 0.1 |
| Alpha-3D | 73 | 32 | 78.9 | 7.6 | 0.1 |
| Ubiquitin | 76 | 32 | 90.5 | 7.6 | 0.1 |
| Proinsulin | 86 | 32 | 55.2 | 9.5 | 0.1 |
| Lysozyme | 129 | 32 | 95.1 | 20.5 | 0.2 |
| Alpha-synuclein | 140 | 32 | 33.3 | 24.8 | 0.2 |
| Myoglobin | 153 | 32 | 93.5 | 30.6 | 0.3 |
| GFP | 238 | 32 | 43.3 | 68.6 | 0.4 |
| Beta-2 AR 7TM | 314 | 32 | 85.6 | 127.9 | 0.5 |

Total bundle size 2.2 MB.

Two low scores are the model's own and are reproduced exactly by the unpatched model:
alpha-synuclein at 33.3 is correct behaviour for an intrinsically disordered protein and is
the intended teaching example; GFP at 43.3 is a genuine single-sequence failure on a
beta-barrel, not a defect in this pipeline.

### How much the trajectories actually move

See BLOCKERS.md for what this means for the project.

```
protein                      aa frames  valid  max RMSD       Rg range   pLDDT range
------------------------------------------------------------------------------------------
Alpha-synuclein             140     32      8    14.02A    8.0-24.5     29.4-38.6   
Alpha-3D, a de novo three-   73     32     30     1.13A   12.4-13.3     71.8-82.0   
Beta-2 adrenergic receptor  314     32     28     1.52A   23.4-25.1     73.7-87.4   
Green fluorescent protein   238     32      8    20.70A   13.2-20.9     34.0-44.8   
Hen egg white lysozyme      129     32     32     0.94A   13.6-14.5     82.4-95.5   
Sperm whale myoglobin       153     32     32     1.12A   15.0-16.0     80.8-94.0   
Human proinsulin             86     32      8    10.83A   10.3-17.8     48.7-56.8   
Protein G B1 domain          56     32     30     2.86A    9.7-10.8     63.9-90.7   
Trp-cage TC5b                20     32     28     1.30A    6.7-7.5      78.3-92.2   
Ubiquitin                    76     32     28     0.87A   11.3-12.0     79.9-90.8   
Villin headpiece subdomain   36     32     28     0.76A    9.1-9.8      82.2-92.7   
Pin1 WW domain               34     32     29     0.77A    9.2-9.9      80.6-92.9   
```

## Phase 0 — candidate model comparison

Same measurements for every model, so they are judged on identical criteria rather than on
impressions. Measured on the M1 Max, CPU, 2026-08-28. All at 76 residues.

| Model | params | steps | max RMSD across trajectory | Rg range (A) | sequence-conditioned |
|---|---|---|---|---|---|
| ESMFold (readout at recycle ends) | ~690 M + 650 M LM | 32 frames | **0.87 A** | 11.3-12.0 | yes |
| foldingDiff | **14.5 M** | 1000 | **15.29 A** | 5.7-20.8 | **no** |

### foldingDiff denoising trajectory, 76 residues

Checkpoint 57.9 MB, max length 128 residues, 1000 cosine-schedule steps over six backbone
dihedrals.

| step | RMSD to final | Rg (A) | CA-CA mean +- sd (A) |
|---|---|---|---|
| 0 | 14.01 | 5.75 | 2.294 +- 0.967 |
| 10 | 10.42 | 11.46 | 3.061 +- 0.885 |
| 100 | 12.14 | 11.10 | 2.906 +- 0.907 |
| 400 | 13.31 | 6.92 | 3.148 +- 0.763 |
| 600 | 12.83 | 13.74 | 3.474 +- 0.496 |
| 800 | 10.95 | 20.79 | 3.691 +- 0.260 |
| 900 | 9.15 | 18.85 | 3.809 +- 0.123 |
| 990 | 1.65 | 15.77 | 3.821 +- 0.025 |
| 999 | 0.00 | 15.56 | 3.823 +- 0.007 |

Two things matter here beyond the 18-fold increase in motion.

**The chain stays plausible throughout.** CA-CA runs 2.3 to 3.8 A across the whole
trajectory and never approaches the 12.5 A of ESMFold's mid-trunk readouts. A backbone tube
can be swept through every frame.

**It converges to better geometry than ESMFold's readouts.** The final frame is
3.823 +- 0.007 A against an ideal 3.80, tighter than ESMFold's 3.84 +- 0.08.

The collapse is real and late: the chain is still expanding at step 800 (Rg 20.8 A) and only
compacts in the final 10% of steps. That is a genuinely watchable arc, and it is what the
Phase 3 score needs in order to have contact-formation events to play.

## Phase 0b — foldingDiff live engine

### Bundle cost

| Component | Parameters | Checkpoint |
|---|---|---|
| foldingDiff | 14.5 M | 57.9 MB |
| ProteinMPNN v_48_020 | 1.66 M | 6.7 MB |
| **Total** | **16.2 M** | **64.6 MB** |

Against ESMFold's 8.4 GB. Both are MIT-licensed and pure PyTorch.

### Generation, 76 residues on the M1 Max CPU

1000 denoising steps in 18.0 s. 201 frames kept at stride 5, 0.80 MB as `.pftraj`.
15.76 A of motion, radius of gyration sweeping 5.7 to 22.0 A.

### Backbone geometry after idealised-O placement

Measured on the final frame. N, CA and C come from the model's own sampled dihedrals; O is
constructed.

| Measurement | Value | Ideal |
|---|---|---|
| N-CA | 1.460 A | 1.458 |
| CA-C | 1.540 A | 1.525 |
| C-N(i+1) | 1.340 A | 1.329 |
| CA-CA | 3.823 +- 0.007 A | 3.80 |
| C=O | 1.231 A | 1.231 (constructed) |
| CA-C-O | 120.80 deg | 120.8 (constructed) |
| **O...N(i+1)** | **2.255 +- 0.007 A** | **~2.25; a flipped torsion gives ~1.7** |
| O-C-N(i+1) | 122.55 deg | ~123 |

The O...N(i+1) distance is the check that matters: it is the one that would catch a sign
error in the constructed torsion, and it is not a quantity the construction sets directly.

### ProteinMPNN inverse folding, and a control that validates the pipeline

Run on ESMFold's final ubiquitin backbone, which is 0.83 A from experimental 1UBQ:

```
designed  MTIFVETENGEVIELEVKPDDTIAEVKKKIEEKTGIPPEKQILIYKGKELKDDKTLADYGIKEGDVLKLVLKDLGA
native    MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG
```

It essentially recovered ubiquitin. The pipeline is correct.

That control matters because the generated backbone designs very differently:

| Backbone | residue types | top 4 as % of protein | charged R/K/D/E |
|---|---|---|---|
| ESMFold ubiquitin (real fold) | 15 | 53% | **41%** |
| foldingDiff generated, T=0.1 | 8 | 86% | **1%** |
| foldingDiff generated, T=0.2 | 13 | 78% | 7% |
| foldingDiff generated, T=0.3 | 16 | 72% | 5% |
| foldingDiff generated, T=0.5 | 13 | 72% | 1% |

Raising the sampling temperature does not fix it, so this is a property of the generated
backbone rather than of the sampling: foldingDiff backbones at 76 residues are low
designability, and ProteinMPNN fills them with leucine, glycine, proline and alanine.

**Musical consequence, which needs a decision before Phase 3.** The Fantasy profile uses
R, K, D and E as octave-shift triggers. A real fold offers roughly 41% charged residues; a
generated one offers 1 to 7%. Those triggers will fire between six and forty times less
often on a generated protein, and the hydrophobicity colour mode will be nearly uniform.
Recorded in BLOCKERS.md.

### A trap worth remembering

`protein_mpnn_run.py` does `if args.seed:` and picks a **random** seed when it is falsy, so
`--seed 0` means "not seeded" rather than "seed zero", and its own help text says so. The
flag looks deterministic and is not. PLAN.md Phase 3 requires the same protein to yield the
same piece, so `Tools/assign_sequences.py` refuses seed 0 outright. Verified: a non-zero
seed reproduces the same sequence across runs, and different seeds differ.

## Phase 0b — foldingDiff backbone quality (14 samples, 76 residues)

### The model-free finding, which does not depend on any predictor

A compact globular chain has a radius of gyration of about `2.2 * N^0.38` angstroms. The
formula was validated against a real protein before use: it predicts 11.4 A for 76 residues
and experimental ubiquitin measures 11.49 A.

| Rg / expected | samples |
|---|---|
| <= 1.2 (compact) | 2 / 14 |
| <= 1.35 | 4 / 14 |
| <= 1.5 | 6 / 14 |
| > 2.0 (badly extended) | 4 / 14 |

Median ratio 1.55, range 1.12 to 2.78. **Most generated backbones are extended rather than
folded**, with perfect local geometry (CA-CA 3.83 +- 0.01) and no tertiary structure.

Confirmed not to be a fault in this pipeline, by two controls:

1. `Tools/make_foldingdiff_trajectories.build_backbone` reproduces the repository's own
   `angles_and_coords.create_new_chain_nerf` to within 0.0005 A, which is PDB rounding.
2. The repository's own `sampling.sample_simple` entry point, with none of this project's
   code involved, produced Rg of 25.16 and 16.52 A for 76 residues.

### Self-consistency, on a metric that is biased against foldingDiff

| | value |
|---|---|
| scTM median | 0.118 |
| scTM range | 0.029 - 0.229 |
| designable (scTM > 0.5) | **0 / 14** |
| correlation, Rg ratio vs scTM | -0.47 |

**This number must not be quoted as foldingDiff's designability.** The fold-back here used
ESMFold, whereas the foldingDiff authors deliberately use OmegaFold, and say why in their
own README: OmegaFold "is natively designed to be run without MSA information, making it
more suitable for our protein design task". ESMFold is known to underperform on de novo
designed sequences, and the low pLDDT values above (41 to 75) are consistent with that.

So 0/14 is suggestive, not conclusive. The fair test needs OmegaFold. What does stand
without a predictor is the radius of gyration result.

The compactness filter helps but does not rescue anything: at Rg ratio <= 1.2, median scTM
rises from 0.118 to 0.168 and the best sample reaches 0.229, still far from 0.5.

### Composition, which is what the score actually consumes

Median 13% charged residues against a real fold's 41%, and the most common residue is
median 30% of the protein against 17% for the ubiquitin design. Two samples exceeded 65%
of a single residue type, one of them 66% alanine.

## Phase 0b — Genie 2 versus foldingDiff, identical criteria

8 Genie 2 samples against 14 foldingDiff samples, both at 76 residues, both measured the
same way on the M1 Max CPU.

| | **Genie 2** | foldingDiff | a real fold |
|---|---|---|---|
| Parameters | 15.73 M | 14.5 M | — |
| Rg / expected, median | **0.96** | 1.55 | 1.00 |
| Rg / expected, range | **0.94 - 1.19** | 1.12 - 2.78 | — |
| Compact (ratio <= 1.2) | **8 / 8** | 2 / 14 | — |
| scTM, median | **0.939** | 0.118 | — |
| scTM, best | **0.980** | 0.229 | — |
| Designable (scTM > 0.5) | **8 / 8** | 0 / 14 | — |
| Charged residues, median | **49%** | 13% | 41% |
| Residue types | 13 - 17 | 6 - 18 | 15 |
| CA-CA | 3.860 +- 0.012 A | 3.83 +- 0.01 A | 3.80 |
| Seconds per sample | **142 s** | 18 s | — |

Best single sample: scTM 0.980 at **0.44 A RMSD**. ESMFold folded the designed sequence back
onto Genie 2's own backbone to within half an angstrom.

The scTM caveat that was attached to foldingDiff's 0/14 applies here too, and it now cuts
the other way: the fold-back is ESMFold rather than the OmegaFold the authors use, so these
numbers are biased **low**, and Genie 2 still reaches a median of 0.939. The caveat only
strengthens the result.

The radius of gyration comparison needs no predictor at all: every Genie 2 sample was
compact, and its worst sample (1.19) was better than foldingDiff's best (1.12 was
foldingDiff's single best of 14, and its median was 1.55).

### The one place Genie 2 is worse

**142 s per sample against foldingDiff's 18 s**, on the same CPU for the same 1000 denoising
steps, because each step runs a much heavier SE(3)-equivariant network. That is the number
that decides whether live on-device generation is viable, and it is measured on CPU: the
model is only 15.73 M parameters, so the ANE should close much of the gap. To be measured in
P0-19.

### Genie 2 emits a CA trace, not a backbone

Not fatal, and arguably convenient. PhoneFold's renderer sweeps a tube through CA positions,
and the P-SEA assignment PLAN.md specifies is CA-only by design. ProteinMPNN ships CA-only
weights, which is what produced the sequences above. But `.pftraj` stores four atoms per
residue, so it needs either a CA-only mode or idealised construction of N, C and O.

### The Genie 2 trajectory as PhoneFold will show it

76 residues, seed 1, every 5th of 1000 denoising steps kept: 201 frames, 0.25 MB.

| | Genie 2 (generated) | ESMFold ubiquitin (interim bundle) |
|---|---|---|
| atoms per residue stored | 1 (CA trace) | 4 |
| frames | 201 | 32 |
| max RMSD across trajectory | **10.72 A** | 0.87 A |
| Rg range | **1.0 - 10.8 A** | 11.3 - 12.0 A |
| final Rg / compact expectation | 0.95 | 1.05 |

The arc is the point: the chain begins as a tight ball of noise at Rg 1.0 A, expands and
organises, and settles into a compact fold at 10.8 A against an expectation of 11.4 A.
That is a concert. ESMFold's 0.87 A was a twitch.

Designed sequence for this backbone, from ProteinMPNN's CA-only weights:

```
MTEEEKERLRKIGEELGASEEVIEKALEALEKAGLDVSKLSDELLAFVIKAIEKGVPVEEIAKMSVEELEKAKKEM
```

14 residue types, 45% charged, natural N-terminal methionine, and recognisable
hydrophobic/charged patterning. The foldingDiff equivalent was
`AAAAAAAAAGAALGAGPSGPSPAALAAAAARAAAAAAAAL...` at 1% charged.

### Control: the re-derived sampler matches Genie 2's own

`Tools/make_genie2_trajectories.py` re-implements the reverse diffusion loop in order to
record intermediate frames, which the upstream sampler discards. Verified against upstream
for the same seed: **all 1000 `randn_like` draws identical**, and the final structure matches
to a **Kabsch RMSD of 0.00048 A**, which is PDB write rounding.

A raw coordinate comparison of the same two structures shows 85 A of difference, because
upstream centres the structure in its PDB writer. That is a rigid-body offset, not a
disagreement. Structures are compared after superposition, never coordinate-wise: the first
comparison here was made the wrong way and briefly looked like a serious bug.

## Phase 0b — P0-17 and P0-19: Genie 2 exported to Core ML

Measured 2026-08-28 on the M1 Max. **These are Mac figures.** PLAN.md is explicit that
desktop and Simulator numbers say nothing about ANE work; on-device measurement remains a
human-verifiable gate.

`Genie2Step_L64.mlpackage`, fp16, 33.8 MB. One export per length bucket, with the static
features baked in as constants.

### The headline: the ANE will not compile this model

```
MILCompilerForANE error: failed to compile ANE model using ANEF.
Error=_ANECompiler : ANECCompile() FAILED.
```

| Compute units | load (s) | ms/step | s per 1000-step trajectory |
|---|---|---|---|
| CPU only | 1.8 | 29.2 | 29 |
| **CPU + GPU** | 1.9 | **15.2** | **15** |
| CPU + ANE | **527.9** | 498.1 | 498 |
| all | 4.2 | 16.2 | 16 |
| *PyTorch CPU (baseline, same length)* | — | *116.3* | *116* |

Requesting the ANE is **33x slower per step than the GPU** and takes nearly nine minutes to
load, because the ANE compile fails and the runtime falls back badly. Asking for `ALL` is
fine: Core ML picks the GPU.

**Core ML on the GPU is 7.6x faster than PyTorch on the CPU**, taking a 1000-step trajectory
from 116 s to 15 s at 64 residues.

Consequence for PLAN.md: the project is subtitled "folds a protein on the Apple Neural
Engine", and for Genie 2 that is not available. The live engine runs on the **GPU** instead.
Nothing else about the design changes, and 15 s per trajectory on a Mac is comfortable.

### What it took to convert, and what each rewrite cost

Six rewrites, each verified numerically before use rather than assumed:

| Rewrite | Why | Measured effect on output |
|---|---|---|
| `sinusoidal_encoding` | strided in-place assignment (`enc[..., 0::2] = ...`) has no converter | **exact**, asserted over 3 shapes |
| `rot_to_quat` | `torch.linalg.eigh` has no Core ML op | see below |
| `quat_to_rot` | built a rank-6 intermediate | **exact** to 1e-5 |
| dropout layers stripped | build masks with `new_ones` | **0.000e+00**, asserted |
| `new_ones` / `new_zeros` | no converter | n/a, registered |
| IPA point attention and `invert_apply` | rank-6 tensors; Core ML caps rank at 5 | **7.2e-07**, 0.00004% RMS |

The IPA rewrite replaces a materialised `[B, N, N, H, P, 3]` tensor with the algebraic
expansion of a weighted pairwise squared distance, `||q||^2 + ||k||^2 - 2 q.k`, as a per-head
matmul. Never above rank 4, exact, and faster because the rank-6 tensor is never built.

### The one rewrite that is not exact: the quaternion sign

Genie 2 converts rotations to quaternions with Davenport's q-method, taking the eigenvector
of the largest eigenvalue. **LAPACK's eigenvector sign is arbitrary**: over 4000 random
rotations, `eigh` returned a non-negative scalar component 51.6% of the time, so the sign
flips discontinuously between neighbouring rotations. The closed-form replacement agrees on
the *rotation* 100% of the time and on the *sign* 51% of the time.

Since that quaternion is fed to the network as a pair feature, the network can only have
learned to be robust to a sign that arbitrary. Measured:

| | effect |
|---|---|
| denoiser output `z` | 7.5 - 9.2% relative RMS |
| generated structure compactness | 3/4 compact (median Rg ratio 1.03) vs 8/8 (median 0.96) |

Small sample, and the compactness filter the app needs anyway absorbs it, but it is a real
measured difference and is not being described as identical. A larger comparison is worth
running before shipping.

## Phase 1 — P-SEA against DSSP

Measured 2026-08-28. Reference: **mkdssp 4.4.5**, with CA coordinates read from the DSSP
records themselves so states and coordinates cannot fall out of register. 10 PDB structures,
997 residues, spanning all-alpha, all-beta and mixed.

### Agreement depends on the DSSP 8-to-3 mapping, and the plan does not say which

| Mapping | Agreement |
|---|---|
| Lenient: H, G, I -> H; E, B -> E (the usual convention) | **79.4%** (792/997) |
| Middle: H, G, I -> H; E -> E | 80.4% |
| Strict: H -> H; E -> E only (regular secondary structure only) | **84.8%** (845/997) |

**PLAN.md's Phase 1 gate asks for 85% and no standard mapping reaches it.**

### The implementation is not the problem

The Swift implementation reproduces biotite's established P-SEA **exactly**: 678/871 residues
on the earlier reference set, structure for structure. It is not an approximation that could
be tuned up.

### Where the disagreement is

| DSSP truth | predicted H | predicted E | predicted C | recall |
|---|---|---|---|---|
| H | 277 | 0 | 92 | 75.1% |
| E | 0 | 190 | 72 | 72.5% |
| C | 10 | 31 | 325 | 88.8% |

**P-SEA never confuses helix with sheet**: both off-diagonals are zero. Every error is
under-assignment, and it is structural rather than incidental. Of the 205 residues it gets
wrong, 42 are DSSP `G` (3-10 helix), 12 are `B` (isolated beta bridge) and 3 are `I` (pi
helix). A CA-only method that requires five consecutive seed residues for a helix cannot
find a three-residue 3-10 helix, by construction.

That is also why the strict mapping scores so much better: it stops counting elements the
method was never able to detect.

### A bug this found, worth recording

An early version scored 64.9%. The cause was the **dihedral sign convention**: the CA virtual
dihedral of a right-handed alpha helix is +50 degrees under IUPAC, and the implementation
returned -50. P-SEA's helix angle criterion is 50 +/- 20, so it never fired: on myoglobin, 2
residues of 153 passed the angle test where 118 are helix. Helix detection silently fell back
to distances alone and nothing crashed. Fixed by negating `atan2`.

Also recorded because it nearly went unnoticed: `mkdssp 4.4.5` **segfaults** on several NMR
entries (2A3D, 1VII, 1L2Y, 2GB1). It was briefly believed to work because the exit status was
read after a pipeline, which reports the status of `head`, not of `mkdssp`.

## Phase 1 — the learned CA-only secondary structure assigner

Built after Marc chose to hold PLAN.md's 85% gate and replace P-SEA rather than restate the
criterion.

| | P-SEA (baseline) | **Learned** |
|---|---|---|
| Agreement with DSSP, held-out ten | 79.4% (792/997) | **86.9% (866/997)** |
| Parameters | none | 5,699 |
| Weights on disk | none | 124 kB JSON |
| Phase 1 gate (>=85%) | not met | **met** |

### Why the measurement is trustworthy

- The **ten evaluation structures were excluded from the training dataset by PDB id**, in
  `build_sse_dataset.py`, and the exclusion list is written into the dataset so it can be
  audited. This is generalisation, not recall.
- Train and validation were split **by chain**, never by residue: splitting by residue puts
  neighbouring residues of the same helix on both sides and inflates the score.
- Features are **CA-only**, as PLAN.md requires. No amides, no carbonyls, no hydrogen bonds.
- Swift feature extraction and the forward pass are asserted **byte-comparable** against the
  Python implementation on a fixture, to within 1e-4 on features and 1e-2 on logits. Without
  that the model would be fed something it was never trained on and would simply get quietly
  worse.

### Training

139 chains fetched, 118 used for training and 21 for validation, 17,858 residues
(34% helix, 25% sheet, 41% coil). X-ray only, because mkdssp 4.4.5 segfaults on several NMR
entries. Validation accuracy 91.6%.

### Viterbi smoothing was measured and rejected

It is the obvious next step and it makes things worse:

| | accuracy | segments | short helix/sheet segments |
|---|---|---|---|
| Raw argmax | **91.59%** | **552** | 78 |
| Viterbi | 89.89% | 397 | 9 |
| DSSP truth | — | 552 | 70 |

Viterbi costs 1.7 points of accuracy *and* over-smooths: it produces 397 segments where the
truth has 552, and almost eliminates short helix and sheet segments, 9 against 70. Raw argmax
reproduces the real segmentation closely. The transition matrix is kept in the model file for
reference but is not applied, and the reason is recorded there too.

Temporal stability across frames is a different axis and is still handled by `SSHysteresis`.

## Phase 2 — renderer per-frame cost

Measured on the M1 Max in release, 314 residues (beta-2 adrenergic receptor 7TM core).

| Stage | ms/frame | share of the 16.7 ms budget |
|---|---|---|
| Fold engine (align, interpolate, assign, contacts, metrics) | 1.65 | 10% |
| Tube geometry and GPU packing (22,548 vertices) | 0.52 | 3% |
| **Total CPU before drawing** | **2.17** | **13%** |

Leaves 87% of the frame for the actual draw, which is the point of writing the vertex buffer
in place rather than rebuilding `MeshResource`.

### A layout trap worth recording

`SIMD3<Float>` occupies **16 bytes, not 12**: it is 16-byte aligned and the fourth lane is
padding. `RenderVertex` is therefore 48 bytes rather than the 40 that counting floats
suggests. The mesh descriptor takes its attribute offsets from `MemoryLayout.offset(of:)`, so
it is correct; hard-coding 12 for the normal's offset would have sheared every normal in the
buffer and lit the protein wrongly without any error. A test pins the real layout.

## Phase 2 — the app runs

Verified 2026-08-28 on the iOS 26.5 Simulator (iPhone 17) and macOS, by screenshot rather
than by a build exit code.

`Trp-cage TC5b`, 20 residues, playing from the bundled sample provider: the backbone tube
renders lit and shaded against the Aurora Stage ground, with live readouts (Rg 6.8 A,
compactness 0.98, 37 contacts, pLDDT 91, helix/sheet/coil 50/5/45) and the twelve-protein
gallery.

### Three things "BUILD SUCCEEDED" did not catch

1. **The Metal shader was never compiled.** The Xcode project was generated *before* the
   `.metal` file was written, so it was not in the sources phase. The build passed, the app
   ran, and the protein rendered flat grey. Found by looking for `default.metallib` in the
   built bundle and finding nothing.
2. **Xcode 26 does not ship the Metal Toolchain.** Compiling any shader needs
   `xcodebuild -downloadComponent MetalToolchain`, a 688 MB download. Until it is installed
   the error is `cannot execute tool 'metal' due to missing Metal Toolchain`.
3. **The protein was coloured from an array of zeros.** The confidence array was never wired
   from the frame into the renderer, so a pLDDT-91 protein rendered orange, the colour for
   *very low* confidence, while the readout directly beneath it read 91. The number and the
   picture came from different places. Only visible by looking at it.

### Shader API details that cost a build each

- RealityKit's stock materials **ignore a per-vertex colour channel**. The channel is
  delivered correctly; nothing reads it. A custom surface shader reading `geometry.color()`
  is required, and that returns `float4`.
- `geometry.uv0()` and `uv1()` are **float2 each**, not float4. Declaring a float4 uv
  attribute compiles and silently hands the shader the wrong lanes.

## Phase 2 — why the renderer does not use a custom shader

Established by bisection on the iOS 26.5 Simulator, after several rounds of a mesh that was
present, had a material assigned, and drew absolutely nothing.

`CustomMaterial` fails to build a pipeline:

```
REMaterialBuilderErrorDomain Code=50 "Program realitykit::fsSurfacePbr failed due to
invalid argument numbers. Constant buffer count [16] exceeds limit [14]."
Pipeline data for technique SurfaceShaderOpaque failed compilation!
```

It fails with `lightingModel: .lit` **and** with `.unlit`, and the failure is silent from
Swift: `CustomMaterial(surfaceShader:lightingModel:)` returns successfully and the pipeline
dies later inside the renderer. Nothing throws and nothing is logged at the app level.

**The bisect that settled it:** the identical mesh with a plain `SimpleMaterial` rendered
correctly. Geometry, transform, camera and scale were never at fault.

### What the renderer does instead

RealityKit's stock materials ignore a per-vertex colour channel, so the colour is delivered
through **mesh parts**: `ColourBuckets` quantises vertex colour, groups triangles by bucket,
and emits one `LowLevelMesh.Part` per bucket with its own `SimpleMaterial`. Ubiquitin in
confidence mode produces **29 parts**, which is a reasonable draw-call count.

This needs no shader, works on the Simulator and on device, and does not have to wait for
hardware to be verified. The custom shader path is kept behind `PHONEFOLD_CUSTOM_SHADER` for
device testing, since the constant buffer limit may well not apply on real hardware.

### Also worth remembering

- `xcrun simctl launch --setenv` is not a thing. Child environment variables go through a
  `SIMCTL_CHILD_` prefix on the parent's environment.
- `xcodebuild` reports `** TEST SUCCEEDED **` alongside `Executed 0 tests` when only
  swift-testing suites ran: that counter covers XCTest only.

## Phase 2 — corrected per-frame baseline, and a regression the gate caught

The Phase 2 gate criterion is "no frame-time regression above 20% versus the recorded
baseline". Writing that check immediately caught one, in code committed an hour earlier.

| Stage | ms/frame, 314 residues, release |
|---|---|
| Tube geometry and GPU packing (the earlier baseline) | 0.52 |
| **Plus colour bucketing, as first written** | **3.25** |
| **Plus colour bucketing, after optimisation** | **1.00** |

`ColourBuckets.split` was doing `buckets[key, default: []].append(...)` per triangle: a hash
lookup and a copy-on-write check 45,000 times a frame, costing 2.7 ms, which is a fifth of
the entire 60 fps budget. The key space is only `count^3`, so it is now a counting sort with
prefix sums: O(n), no allocation per triangle, same deterministic output, **2.9x faster**.

Engine (1.65 ms) plus geometry, packing and bucketing (1.00 ms) is **2.65 ms of the 16.7 ms
budget**, leaving 84% for the draw.

### Measuring it stably

The first version of the check took the mean of one batch and swung between 1.13 and 2.46 ms
on an idle machine, purely from scheduling noise, which would have made the gate flaky enough
to ignore. It now takes the **minimum of five batches**: the fastest batch is the closest
estimate of actual compute cost. Three consecutive runs give 1.02, 1.00, 1.00 ms.

## Phase 2 — colour snapshots

The gate asks for "snapshot tests of all four colour modes against reference images". The
snapshot is the **colour buffer**, not a rendered image: there is no headless GPU render path
in the test target, and comparing screenshots would test RealityKit's rasteriser rather than
PhoneFold's colouring. What can regress here is the colour a residue is assigned, and that is
what is pinned, for a fixed frame of real ubiquitin, across all four modes.

Negative-tested by shifting the pLDDT ramp's cyan-to-blue transition, which reported
"confidence: 5 of 57 colours changed". An earlier attempt to negative-test it by moving the
40-point threshold changed nothing and looked like a weak test: ubiquitin's final frame sits
at 80 to 95 pLDDT, so that threshold governs none of its residues. The perturbation has to
land in the data's actual range to prove anything.

The reference is only regenerated with `PHONEFOLD_RECORD_SNAPSHOTS=1`. A snapshot that
rewrites itself on mismatch is not a test.

### P2-14 — playback and the fragmented backbone (2026-08-28, iPhone 17 Simulator)

| Measurement | Value |
|---|---|
| Frames delivered, trp-cage | 234 / 234 |
| Frame cost, on-screen readout | 1.7 ms |
| Cold launches checked for a consistent start | 5 |
| Protein coverage of the stage at t = 5 s | 26.94, 27.05, 27.07, 26.99, 26.96 % |
| Package test suite | 210 tests, 37 suites, all passing |
| 314-residue frame budget | 593.52 ms/frame over 466 frames (Simulator; see the note above) |

Coverage is measured against the stage's own median ground colour rather than an assumed
background value: the first attempt hard-coded the ground and reported every launch as 100 %
lit, which is the shape of an answer that is not measuring anything.

### P2-05 — the Aurora grade: five routes to the stage's pixels (2026-08-28)

PLAN.md Phase 2 asks for "HDR bloom on emissives, mild depth of field, vignette, Aurora
grade". Bloom and depth of field are screen-space effects. Every API that could reach the
stage's pixels was tried and the result measured, not assumed:

| Route | Result | How it was established |
|---|---|---|
| `CustomMaterial` surface shader | Pipeline never compiles | `fsSurfacePbr`: "Constant buffer count [16] exceeds limit [14]". Mesh present, material assigned, nothing drawn. Bisected against `SimpleMaterial` |
| `ARView.renderCallbacks.postProcess` | Traps on assignment | `EXC_BREAKPOINT` in `ARView.renderCallbacks.setter`, no assertion text in `log stream`. A/B of that one line: unset the app runs, set the process is gone |
| SwiftUI `layerEffect` over `RealityView` | Unsupported-effect placeholder | Rendered as SwiftUI's yellow-and-red placeholder |
| SwiftUI `colorEffect` over `RealityView` | Unsupported-effect placeholder | Same. The vignette term was visibly applied **to the placeholder** |
| `UnlitMaterial.faceCulling = .front`, and reversed triangle winding | Both ignored | The shell drew its near wall either way and the tube vanished behind a flat silhouette |

`ARView.renderCallbacks.postProcess` is the only one of these that would deliver true bloom
and a true depth of field, because it is the only one that hands over `sourceDepthTexture`.
It may well work on hardware. No device is paired with this machine
(`xcrun devicectl list devices`: "No devices found"), so that is untested and is not claimed.

**A note on the red probe.** The `colorEffect` route was first tested with a shader returning
pure red, and the stage came back pure red, which was read as success. It was not: a uniform
output is identical whether it landed on the RealityView or on the placeholder that replaces
it. The failure only became visible once the shader returned something with structure in it -
the vignette's gradient, which showed up sitting on the placeholder. A probe whose output is
uniform cannot distinguish success from the failure mode it is meant to detect.

#### What is delivered, and what it costs

| Measurement | Value |
|---|---|
| Halo: shell + back-face rejection, 300 residues / 43,056 triangles | **0.15 ms** per frame (release) |
| The same, debug build | 9.49 ms - 63x slower, and meaningless |
| Frame cost on screen, trp-cage, after the grade | 1.7 ms (unchanged) |
| Package suite | 214 tests, 38 suites, all passing (release) |
| Phase 2 machine gate | GREEN, including the macOS app build |

Delivered: the halo (object-space glow, welded to the tube's own normals), the vignette
(composited, needs no shader), and PLAN.md's indigo-to-near-black ground. Not delivered:
screen-space bloom and depth of field, for the reasons in the table.

**One thing deliberately not done.** A tone curve over the stage would lift the shadows and
add contrast, and would also distort the pLDDT ramp - a data scale structural biologists read
at a glance, and the reason PLAN.md picked it. The stage is graded around the protein and the
protein's own colours are left true.

### Recycling: what the later passes actually add (2026-08-28)

ESMFold refines by recycling: the trunk runs, its structure is fed back, and it runs again.
The bundled trajectories are 4 recycles x 8 readouts, where the 8 are the structure module's
IPA layers. Within a recycle the readouts descend cleanly; at each new recycle the trunk
re-enters from a coarser state, the structure re-expands, and Rg steps back up. Those are the
periodic peaks in the trace.

Measured against each trajectory's own final structure, after Kabsch superposition:

| Protein | Residues | End of recycle 0 | Final (4 recycles) | RMSD, recycle 0 to final |
|---|---|---|---|---|
| Ubiquitin | 76 | pLDDT 90.5 | 90.5 | **0.18 A** |
| Myoglobin | 153 | 91.8 | 93.5 | 0.38 A |
| Trp-cage | 20 | 86.5 | 91.1 | 0.75 A |

Ubiquitin's later recycles retrace the same numbers: Rg 12.02 to 11.36 and pLDDT 79.9 to 90.6,
three times over, arriving where the first pass already was. Three quarters of the runtime for
0.0 to 4.6 pLDDT and a structure that is the same structure.

**So playback defaults to the first recycle.** The whole trajectory stays in the file and
stays playable through `RecycleSelection.all`; this is a choice about what to show.

There is no denser honest sampling of a single pass available: readouts taken between trunk
blocks were previously measured as geometrically broken, CA-CA distances of 5 to 18 A, because
the structure module is not trained to run mid-trunk. One recycle is 8 real structures and
everything between them is interpolation. A long descent with a real structure at every step
is what the diffusion trajectories are for - the bundled Genie 2 run is 201 of them.

Playback is paced from the trajectory's own length for a fold of about 12 seconds, because the
bundled trajectories run from 8 readouts to 201 and a fixed rate cannot serve both.

### A flicker test that was passing for the wrong reason

`noFlicker` counted every secondary-structure change and required them to be under 1% of
residue-frames. Switching playback to the first recycle took that measurement from 0.74% to
1.94% with no change to any geometry: three quarters of a four-recycle trajectory is an
already-settled structure where nothing changes, and those frames were diluting the rate. Of
the 88 changes across the whole ubiquitin run, 53 fall in the first recycle's 36 frames and 35
are spread over the 120 settled ones.

The test now measures **reversals** - a state that changes and changes back within a tenth of
a second - as a fraction of changes rather than of residue-frames. Change is the app's whole
subject; only reversal is flicker. Measured: 53 changes, 6 reversals, so 89% of changes stick.

### The cartoon: tessellation, smoothing, and what it costs (2026-08-29)

| Measurement | Before | After |
|---|---|---|
| Cross-section segments / samples per residue | 12 / 6 | 20 / 10 |
| Vertices, 314 residues | 21,540 | 62,620 |
| Geometry + packing + bucketing, 314 residues, release, idle machine | 0.52 ms | **2.52 ms** |
| The same inside a full parallel test run | - | 3.32 ms |
| Outline, 300 residues | 0.15 ms / 43,056 tri | 1.24 ms / 119,600 tri |
| Fraction of a 60 fps frame | 3% | 15% |

**Guide-point smoothing.** An alpha helix turns every 3.6 residues, so a spline through raw
alpha carbons traces a rounded triangle - which is what a helix looks like at the level of its
alpha carbons, and not what anyone means by a helix. Guide points inside helices and strands
are smoothed with a [1, 2, 1] pass before splining, scaled by structure confidence so the
smoothing eases in with the ribbon.

How hard to pull is arithmetic, not taste. At 100 degrees per residue one full pass multiplies
the helix radius by (2 + 2 cos 100) / 4 = 0.41, so two full passes leave 17% of it. The first
attempt used 0.85 twice and flattened every helix into a shallow wave - a worse failure than
the squared-off spiral it was fixing. One pass at 0.40 keeps about 77% of the radius.

### How much fold is actually in each trajectory (2026-08-29)

Across the readouts now played, first to last, after Kabsch superposition:

| Trajectory | Residues | Rg first → last | RMSD first → last |
|---|---|---|---|
| protein_g_b1 | 56 | 10.33 → 10.03 | **0.76 A** |
| ww_domain | 34 | 9.95 → 9.36 | 0.71 A |
| villin_hp36 | 36 | 9.77 → 9.15 | 0.76 A |
| ubiquitin | 76 | 12.05 → 11.41 | 0.85 A |
| lysozyme | 129 | 14.49 → 13.63 | 0.92 A |
| trp_cage | 20 | 7.55 → 6.94 | 0.98 A |
| alpha3d | 73 | 13.32 → 12.42 | 0.98 A |
| myoglobin | 153 | 16.00 → 15.03 | 1.04 A |
| beta2ar_7tm | 314 | 24.98 → 23.50 | 1.59 A |
| proinsulin | 86 | 11.54 → 17.75 | 8.30 A |
| gfp | 238 | 13.17 → 20.56 | 10.23 A |
| **genie2_76aa_seed1** | 76 | **1.22 → 10.83** | **10.72 A** |
| alpha_synuclein | 140 | 11.85 → 24.52 | 16.09 A |

**ESMFold's readouts are not a folding pathway.** The structure module's first IPA layer
already emits a near-final structure, so nine of the thirteen trajectories move by under
1.6 A from beginning to end. There is almost nothing to watch, and no rendering or pacing
change can add it.

The three ESMFold entries that do move - proinsulin, GFP, alpha-synuclein - move by
*expanding*, not folding: those are the ones the model is least sure about. Alpha-synuclein is
intrinsically disordered and ESMFold has nothing to converge to.

The one trajectory that is a genuine descent from disorder into structure is the diffusion
run: Genie 2 goes from Rg 1.22 to 10.83 A over 201 real steps, every one of them a valid
structure. That is what a watchable fold looks like, and it is why Phase 0 changed engine.
The cost is that Genie 2 generates de novo backbones, so it cannot fold a named protein.

### What the Genie 2 trajectory actually looks like to play (2026-08-29)

Measured over its 201 steps, contacts counted at the tracker's 8 A threshold with |i-j| >= 3:

| Step | Through | Rg (A) | Contacts |
|---|---|---|---|
| 0 | 0% | 1.22 | 2701 |
| 40 | 20% | 3.37 | 2652 |
| 80 | 40% | 6.39 | 1100 |
| 108 | 54% | 8.00 | - |
| 140 | 70% | 9.65 | 291 |
| 200 | 100% | 10.83 | 182 |

Three things follow, and they all bear on whether this should lead the gallery.

**It expands, it does not fold.** The denoising starts from a near-zero-radius Gaussian blob
and opens outward. That is the model's real generative path and it is a genuine descent into
structure, but the motion on screen is a ball unpacking, not a chain collapsing. The intuitive
folding animation - extended chain drawing itself into a compact core - is not what either
engine does.

**The first sixth is a degenerate blob.** 35 of 201 steps have Rg under 3 A, which puts all 76
residues inside a sphere a few angstroms across. Every residue pair is then in contact: 2701
of them, against 182 in the finished structure. It renders as a magenta mass.

**And it costs.** Those frames measure **19.8 ms** in the app against a 16.7 ms budget for
60 fps, so playback stretches: 13 seconds of wall clock covered 7% of the trajectory. The
cause is the contact count, not the geometry. Fixable - the degenerate prefix can be trimmed
or the tracker capped - but not yet fixed.

### The colour ramp: a gradient instead of a staircase (2026-08-29)

Marc reported the gradients as jagged. Measured on the screenshot he sent: **26 discrete steps
along one strand ribbon**, about 19 px apart, each about 3 levels per channel. That is not
aliasing, it is the quantiser: colour was delivered by splitting the mesh into one part per
quantised colour and tinting each part's material, so every part is one flat colour and a ramp
arrives as a staircase.

Finer quantisation is a dead end. The counting sort's working memory grows with the cube of
the level count:

| Levels | Parts (draw calls) | Step | Key space |
|---|---|---|---|
| 16 | 36 | 6.67% | 4,096 |
| 32 | 51 | 3.23% | 32,768 |
| 48 | 65 | 2.13% | 110,592 |
| 64 | 77 | 1.59% | 262,144 |

Going 16 to 48 already cost 0.38 ms a frame in zeroing alone, and 2.13% per step was still
visible.

**Replaced with a ramp texture.** 1024 by 3 texels, one row per secondary structure, baked by
calling `Colouring` itself on a synthetic vertex so it cannot drift from the colour the rest of
the code believes in. Each vertex carries the coordinate that looks up its own colour, and the
GPU interpolates between texels.

| | Before | After |
|---|---|---|
| Draw calls for the protein | 65 | **1** |
| Colour steps along a ribbon | 26 | none |
| Geometry pass, 314 residues | 2.90 ms | **1.84 ms** |
| Vertex size | 64 bytes | 80 bytes (stride) |

One bug worth recording. RealityKit samples the texture's V axis the opposite way up from the
row order, so a sheet vertex asking for row 2 read row 0 and came out coil slate. Helix sits in
the middle row and was unaffected either way, which is why the symptom was "the strand has no
colour" rather than "the colours are wrong": on screen the sheet vanished into the coil. The
rows are reversed when the image is built, so the pure logic stays in structure order and
stays testable.

### The spline was the reason helices were not round

An alpha helix advances 100 degrees per residue, so a turn is 3.6 alpha carbons. Measured on a
unit circle sampled at that step, a Catmull-Rom spline's midpoint between two samples sits at
**0.831 of the radius** - it cuts 16.9% off the corner. That is why helices kept drawing as
rounded triangles, and no amount of tessellation or guide-point smoothing fixes it, because the
curve itself is the wrong shape. Smoothing made it worse: a [1, 2, 1] pass multiplies a helix's
radius by 0.41, so rounding the polygon that way also shrank it.

Replaced with a blend of the two circular arcs through each overlapping triple, which
reproduces a circle exactly. On an ideal helix, radius 2.3 A and rise 1.5 A:

| | worst radius | error |
|---|---|---|
| Catmull-Rom | 1.912 A | 16.9% |
| Circular arcs | 2.194 A | **4.6%** |

The 4.6% residual is expected and honest: the circle through three points of a *helix* is a
tilted circle, not the helix, so its projection dips slightly inside. Guide-point smoothing now
applies to strands only, where flattening the pleat is what it is for.

### The drag that got stuck

`isInteracting` was cleared only by SwiftUI's `onEnded`, and `onEnded` does not always run - a
gesture pre-empted by the simultaneous magnify, or cancelled by the system, simply stops. When
it did not run the camera stayed interacting for good, `advance` returned early every tick, and
the orbit never came back. The interaction now also ends on 0.3 s without input.

### The artefacts, and what each one actually was (2026-08-29)

**Dark slivers at arrowhead tips and on tight turns.** The outline shell was offset a fixed
0.16 A while an arrowhead's tip was 0.07 A wide, so the shell crossed through the ribbon it
was meant to surround and its far wall came out in front. The offset is now derived from
`Profile.thinnestHalfExtent` - half of the thinnest section the cartoon draws - so it cannot
cross anything, and the arrow tip is 0.16 A rather than 0.07.

**A notch in the strand.** trp-cage's assignment is `-HHHHHHH--HHH----E--`: exactly one sheet
residue. The arrowhead returned an absolute half-width over a fixed 1.6-residue span, so it
reached back across two *coil* residues and widened them, and past the tip the width jumped
from 0.11 to 0.84 between samples a quarter of a residue apart. It is now a multiplier on the
section rather than a replacement for it - 1 outside a strand, so the structure decides and
there is nothing to jump back to - and the head is never longer than the strand it caps.

**A near-collinear guard that guarded nothing.** `arcPoint` rejected degenerate triples on the
absolute length of a cross product: at 3.8 A spacing a sine of one part in a hundred million
still clears 1e-7, and the circle it describes has a centre computed from the difference of two
nearly equal large numbers. It is now a relative test with a smooth blend to a straight line.

Worth recording honestly: this last one was found by reasoning, not by measurement, and the
measurement then said it was not the bug. A probe over trp-cage's real geometry found **no**
residue below a turn sine of 0.15, so nothing was ill-conditioned and the strand's kink was
the arrowhead all along. The conditioning stays because the guard it replaced was meaningless,
not because it fixed what it was written to fix.

### Three reports, three measured causes (2026-08-29, second pass)

**The ribbon artefacts were depth precision, not geometry.** A probe over both an ideal helix
and the real trp-cage frame found the swept mesh clean: 191 rings, **0 reversals and 0 folded
edges of 3,800**. So nothing was folding. The camera was set to near 0.01 / far 100, a ratio of
10,000 to 1, which spends nearly all the depth buffer on the first fraction of the scene. The
protein is scaled to about 1.15 units with the camera at 1.5, so a ribbon 0.5 A thick is about
0.03 units and the outline stands 0.005 units off the surface - both inside the noise at that
ratio. Now near 0.05 / far 20, a ratio of 400 to 1: twenty-five times the precision where the
protein actually is, and still clear of the closest the camera can come (0.35).

**The strand's notch was still the arrowhead.** Measured on the real chain, the half-width
jumped **0.123 to 0.719 between samples a tenth of a residue apart at u = 17.10**. The taper
ended at the strand's last residue *index*, but `interpolatedStructure` fades a structure out
over the half residue past it, so for that half residue the width snapped back to the full
strand. The point now sits at the end of the strand's extent.

**And a bug I introduced myself.** The 0.3 s input timeout added to recover from a lost
`onEnded` was firing *during* a drag: a hand holding still for half a second is ordinary, and
the camera was ending the interaction out from under a finger that had not lifted. Two seconds
now - long enough that only a genuinely abandoned gesture trips it.

Measured on the drag itself, under synthesised events: a 500 px sweep rotates the protein and
it stays put on release, and a slow drag in five bursts with 0.45 s pauses tracked through
every burst (3.80, 4.00, 4.17, 4.20, 4.12 mean pixel change). So the mechanism works; what
remains, if anything, is about how the input arrives.

### Why the strands looked lumpy (2026-08-29)

Not the pleat, and not the frame. Measured on protein G's second strand, the half-width along
its six residues ran **0.72, 0.92, 1.05, 0.95, 0.83, 0.72** - a 1.46-fold swing along a single
strand, because the cross section grows with confidence and confidence is assigned per residue.
On screen that is a ribbon pinching in and out like a squeezed tube. No cartoon draws that: an
element has one width and tapers only where it ends. Confidence is now averaged over each
secondary-structure element, which keeps the growth as a fold settles and removes the wobble.

Two other things measured on the way, both of which turned out not to be the fault:

| Hypothesis | Measurement | Verdict |
|---|---|---|
| The beta pleat survives in the guide path | Deviation from a straight strand: 2.82 A raw, and only 1.45 A at maximum smoothing | Protein G's sheet is genuinely curved; smoothing it further would flatten real structure |
| The ribbon frame corkscrews | Roll per residue on sheet: mean 22.5, worst 64.3 degrees unsmoothed | Real, and worth fixing - a [1,2,1] frame average takes the worst to 35 degrees - but ~16 degrees is real beta-sheet twist and the reference shows it too |

The frame smoothing stays: it removes the per-residue alternation of the pleat and leaves a
steady roll alone, which is the distinction that matters, since a helix's 44 degrees per
residue is the helix and must survive.

Also this round: the cross section is a superellipse rather than an ellipse, so a ribbon is a
slab with crisp edges instead of a flattened sausage; the outline is opaque, because a
transparent material is drawn without writing depth and the shell was compositing over the
ribbon in front of it - the see-through patches at the bottom of each helix turn.

### Curvature and zigzag are separable, and only one of them was the problem

Marc's correction: a beta strand is allowed to curve and twist, but its surface and edges must
be flat. That splits the earlier measurement in two, and measured separately the answer is
plain. The alternating component - how far each alpha carbon sits off the midpoint of its
neighbours, which is the pleat - against the smooth bend:

| Smoothing | Zigzag, mean / worst | Curvature kept |
|---|---|---|
| none | 1.743 / 2.157 A | 2.82 A |
| **0.4 x 1 (what shipped)** | **1.141 / 1.636 A** | 2.47 A |
| 0.6 x 2 | 0.422 / 1.050 A | 2.00 A |
| **1.0 x 3 (now)** | **0.169 / 0.498 A** | 1.75 A |
| 1.0 x 6 | 0.132 / 0.333 A | 1.45 A |

At the shipped setting the alternation was 1.14 A - about the ribbon's own half-width - which
is exactly why the edges looked serrated. Three full passes cut it by nearly seven times and
keep the curve. Going further buys little and starts straightening the sheet itself, which is
real structure.

The earlier measurement missed this because it measured total deviation from a straight line,
which is dominated by genuine curvature: it moved only 2.82 to 1.45 A across the whole range
and made the smoothing look ineffective. It was measuring the wrong quantity, not reporting a
wrong answer.

### Performance gates that stop failing for the wrong reason

Both timing tests had been re-recorded or widened repeatedly and still went red intermittently:
one run in eight failed *both at once*, which is the signature of a load spike rather than a
regression. They now assert a **ratio** against a calibration measured in the same run, and the
two measurements are interleaved batch by batch so a spike has to hit every batch, and both
halves of one equally, to survive. Ten consecutive full runs pass.

And the superellipse turned out to cost real time: four `pow` calls per vertex is a quarter of
a million a frame at 314 residues, measured at **2.92 ms** against 1.80 before it. The sharpness
is constant around a ring, so sixteen precomputed rows spanning ellipse to slab cover every
section the renderer sweeps. Back to **1.65 ms** - faster than before the superellipse existed,
with the flat faces kept.

| | Geometry, 314 residues |
|---|---|
| Original ellipse, 12 x 6 tessellation | 0.52 ms |
| 20 x 10 tessellation | 2.52 ms |
| plus 48-level colour quantisation | 2.90 ms |
| ramp texture instead of quantisation | 1.80 ms |
| plus superellipse, `pow` per vertex | 2.92 ms |
| **plus precomputed section tables** | **1.65 ms** |

### The helix edges: vertices in the wrong places (2026-08-29)

Uniform angular sampling is badly behaved on a flattened superellipse, and the numbers are the
opposite of what intuition suggests. Measured on the helix ribbon - half-width 1.05,
half-thickness 0.30, sharpness 6 - twenty uniform-angle samples put **fourteen of the twenty on
the two thin edges**, leaving the broad faces spanned by segments 9.8 times longer than the
shortest. Shading interpolated across spacing that uneven is what made the sides look coarse.

Spacing the ring by arc length instead: segment ratio 9.8 to **2.8**, and six of twenty on the
edges rather than fourteen. Free at runtime, because the sections are already precomputed per
sharpness level; the aspect ratio used to place them travels with the sharpness, since a
section flattens and squares off together.

### The camera, again

Two changes, neither of which is a diagnosis - the drag still cannot be reproduced here.

The rotation is now applied from the gesture itself rather than waiting for the next tick of
the render clock, so it cannot depend on that task still running. And the auto-orbit's resume
delay went from 2.5 s to 8 s: PLAN.md wants the orbit instantly overridden by a drag, which it
was, but resuming two and a half seconds after the finger lifts means a view you have just set
starts sliding away while you are still looking at it.

The camera's state is now on the glass under `PHONEFOLD_DIAGNOSTICS=1` - yaw, pitch, and
whether it believes it is orbiting or held - because four attempts at this have been guesses
and a screenshot of those three numbers during a stuck drag would settle it.

### Two defects measured to ground: the hollow ribbon ends, and the drag (2026-08-29)

**The hollow ends were real holes: the sweep never emitted caps.** `TubeGeometry.build`
connects consecutive rings with quads and stopped there, and the boundary-edge count says so
exactly: **40 boundary edges on every build - 2 x 20 radial segments** - whether the chain is
helix, sheet or coil, and nothing else in the mesh is open. This renderer culls nothing
(measured in P2-05: `faceCulling` and reversed winding both ignored), so each open terminus
showed the tube's interior wall - on screen, an end facing the camera is a hollow scoop with
a dark inside.

Capped with a triangle fan per end. Three details were set by measurement rather than taste:

| Measurement | Value | Consequence |
|---|---|---|
| Boundary edges, before / after | 40 / **0** (welded by position) | the surface is closed; the test reverts to 40 without the fix |
| Sweep triangles whose geometric normal agrees with their vertex normals | **0 of 4,400** | the sweep is wound with geometric normals *inward*; the caps copy that convention so `farFacing`'s majority calibration treats them like the wall they close |
| Cost, alpha3d in the live app | 14,420 → 14,462 vertices, 28,800 → 28,840 triangles | 2 x (radial + 1) vertices and 2 x radial triangles; the rim is duplicated because a cap is flat and needs the tangent as its normal |

**The drag that reads as stuck: the pitch clamp.** Pitch was clamped to +/-(pi/2 - 0.05) to
protect a camera-orbit up vector - but the app orbits the *protein* against a fixed camera,
`position`/`orientation` are consumed by nothing, and a subject quaternion has no pole. From
the resting tilt 0.18 at 0.006 rad/point the clamp is reached after **223 points of downward
drag** (283 upward): one ordinary trackpad drag, after which vertical input does nothing at
all while horizontal keeps working. Measured on the old code, consecutive 100-point vertical
drags advanced the attitude by **0.600, 0.600, 0.141, then 0.000 rad forever**; on the new
attitude-quaternion camera all forty steps advance 0.600 rad, and increments premultiply
about the screen axes so "drag right turns right" survives being upside down (tested).
In the app, a synthesised 600-point vertical click-drag now carries the rotation straight
through the old stopping point - rot 179 degrees at 220 points, 141 at 600, having passed
through the pole - and holds on release.

Honest scope: Marc's report is still not reproduced with real trackpad input. The clamp is
the one measurable mechanism that behaves exactly like "stuck" (dies mid-gesture, one axis
only), and it is now gone; if the report survives this fix, the overlay below settles it.

**The diagnostics that could never have appeared.** Last round's camera-state overlay was
wrapped in `#if DEBUG`, and the app Marc runs is a Release build: `PHONEFOLD_DIAGNOSTICS=1`
showed nothing in the only build that mattered (measured - launched Release with it set, no
overlay). The gate is now the environment variable alone, and the overlay carries the drag /
magnify / scroll event counters, the last drag delta, and rot / distance / orbiting-or-held,
updated from the gesture callback itself. One screenshot during a stuck drag now separates
"no events arriving" from "events arriving, camera not moving" from "camera moving, screen
not updating".

**Scroll-wheel zoom** (PLAN.md's "Mac adds scroll-wheel zoom") via a local `.scrollWheel`
monitor. Gating by `.onHover` measurably failed - synthesised pointer moves plus scrolls left
the consumed count at 0 - so the stage's frame is tracked with `onGeometryChange` and the
event location hit-tested against it. Verified in the running app: 8 of 8 scroll events over
the stage consumed, distance 1.50 → 0.67, held; the same scroll over the gallery leaves the
camera untouched and the gallery scrolling. One earlier run before the counters existed
consumed nothing and has not reproduced since; the seen/used counters stay in the overlay so
a recurrence is one screenshot rather than another guessing round.

### The see-through slits were the outline, and it is now off (2026-08-29)

Not transparency: nothing in the 3D materials is transparent any more. The dark slits are the
**outline shell drawn in front of the surface it is meant to sit behind**.

An inverted-hull outline needs the renderer to cull front faces, and this one culls nothing -
measured twice, in P2-05 and again since: `faceCulling = .front` is ignored, and so is a
reversed triangle winding. The stand-in has been to select the far-facing triangles on the CPU.
That holds over most of a surface and breaks down exactly where a ribbon turns edge-on or
twists.

Measured on the alpha-3D bundle by counting thin dark runs enclosed by lit pixels on both
sides - a slit, as distinct from the genuine gaps between helix turns, which are also dark:

| | Enclosed dark runs | Pixels |
|---|---|---|
| Outline on | **2,122** | 7,913 |
| Outline off | 628 | 5,645 |

Three times as many, all artefacts. The outline defaults to off. Its machinery stays and stays
tested: it is the right technique the day this renderer will cull a face, and a cartoon without
an outline is what PyMOL draws by default.

A note on measuring this. The first attempt counted dark pixels inside the protein's silhouette
and returned 46.8% against 46.2% - no signal at all - because a protein is not convex and the
gap between two helices dominates the count. The measurement had to distinguish an *enclosed*
dark run from an open one before it could see a difference of three times.

### The grey through the ribbon was the colour fade, not geometry (2026-08-29)

`interpolatedStructure` fades the outgoing structure's confidence to zero at a boundary, so the
cross section can pass through coil on its way from ribbon to cord. That morph is right for the
*shape* - PLAN.md wants structure to grow rather than snap - and wrong for the colour, because
it took the ribbon's colour all the way to coil slate as well. On a settled protein that puts a
grey wedge across the last residue of every helix, soft-edged, which reads exactly as the coil
showing through the ribbon.

Colour now comes from `colouredStructure`: the nearer residue's own element at its own
confidence, so it changes at the boundary the way a cartoon's does while the shape still morphs.
The colour snapshots moved by 5 of 58 in `secondaryStructure` alone - the boundary samples, and
nothing else.

Ribbon proportions also brought to the convention, which is roughly PyMOL's:

| | Was | Now | PyMOL default |
|---|---|---|---|
| Helix half-width | 1.05 | **1.35** | 1.35 (`cartoon_oval_length`) |
| Helix half-thickness | 0.30 | 0.25 | 0.25 (`cartoon_oval_width`) |
| Sheet half-width | 1.10 | **1.40** | 1.40 (`cartoon_rect_length`) |
| Sheet half-thickness | 0.26 | 0.22 | 0.20 (`cartoon_rect_width`) |
| Coil radius | 0.22 | 0.20 | 0.20 (`cartoon_loop_radius`) |

**A measurement that did not work, recorded so it is not repeated.** Counting grey pixels
enclosed by magenta gave 32,254 before and 37,316 after - apparently worse. It is not a valid
comparison: the ribbon got wider in the same change, so there is more magenta and more enclosed
area, and the auto-orbit means the two captures are not the same pose. Two changes in one pass
with a metric sensitive to both. This one was judged by eye, and said so.

### The grey disc was the cord bursting through the arrow, and the pale band was the texture blending rows (2026-08-29)

**Defect A - the round grey disc on the arrowhead face.** The arrowhead's width multiplier
was applied to the already-confidence-blended width. At a strand's C-terminal boundary the
fade has taken that width down to the coil radius already, so multiplying by the tip fraction
collapsed the tip ring to a sliver - and the full-radius cord drawn at the very next sample
burst straight out of it. Measured on protein G B1's first strand (final frame, levelled
confidence 0.907):

| u along the chain | halfWidth before | halfWidth after |
|---|---|---|
| 7.40 (last sheet sample) | 0.0732 | 0.2082 |
| 7.50 (tip) | **0.0229** | **0.2000** |
| 7.60 (first cord sample) | 0.2000 | 0.2000 |

An 8.7-fold width step between adjacent rings, 0.1 residue apart; the step's rearward-facing
annulus is painted by the coil residue (nearest-residue colour at u = 7.5 rounds to residue
8, coil), and this renderer culls nothing, so end-on it is a perfectly round grey disc in the
middle of the cyan face, radius exactly the cord's 0.20. The fix scales the **un-blended**
target width (`grow(sheetHalfWidth * scale)` rather than `grow(sheetHalfWidth) * scale`), so
the taper now ends exactly on the cord: max adjacent-ring step 1.04x, and the tip ring is the
cord's own circle - the junction is seamless by construction. Pinned by
`JunctionTests.arrowTipMeetsTheCord` on the thinnest-extent ratio of adjacent rings
(threshold 1.5); negative-tested: reverting the one line brings back a 2.59-fold step and the
test fails.

**Defect B - the pale washed-out band across every ribbon end.** Not geometry at all: the
final frame has **zero** inverted triangles and zero bands whose geometric and vertex normals
disagree by more than 30 degrees (measured across all 550 protein G and 720 alpha-3D bands),
and the mesh is watertight. The band is the ramp texture. Colour is looked up in a 1024 x 3
texture with one row per structure, addressed by uv0; a quad whose two rings straddle a
structure boundary interpolates that coordinate **across rows**, and the sampler blends the
rows on the way through. Helix to coil blends magenta into slate - the pale dusty band Marc
photographed four times; sheet to coil passes through the helix row and flashed magenta on
the cord at every strand junction (visible in the same screenshots). Measured on screen at a
helix end before the fix: a band of junction pixels at G/R 0.28 against 0.19 on the pure
face, i.e. partway to slate's 1.24.

The fix duplicates the ring wherever the nearest residue changes: coincident positions and
normals, only the paint attributes differ, so the quads between the pair are zero-area and
never rasterise, and the colour changes in a hard edge at the boundary the way a cartoon's
does. The layout depends only on chain length and profile - never on the frame's assignments -
so the vertex count stays constant across a trajectory and `LowLevelTubeMesh`'s one-off
allocation still holds. Cost on protein G B1: 551 to 606 rings (+10% vertices, all of them in
degenerate quads the GPU drops at assembly). Pinned by
`JunctionTests.mixedTrianglesAreDegenerate` (any triangle whose vertices disagree about
structure must have zero area - with the duplication removed, 80 visible mixed triangles
appear on a 24-residue chain and the test fails) and by
`JunctionTests.layoutIsFrameInvariant`. The colour snapshot fixture was re-recorded for the
new vertex count (58 to 86 digest entries), via `PHONEFOLD_RECORD_SNAPSHOTS=1` as designed.

Verified in the app (iOS Simulator, Release, secondary-structure mode): protein G B1 before
at /tmp/pf_before_g_01.png (rust bands on the cord at every strand junction, fat cord
protruding from both arrow tips, pale wash at the helix ends) against after at
/tmp/pf_after_g_01.png and zooms /tmp/pf_after_arrowtip_zoom.png,
/tmp/pf_after_helixend_zoom.png: taper meets the cord at the cord's own width, junction
edges are crisp, and a pixel grid across the helix end shows pure magenta to the edge with
no intermediate-colour band (before-fix grid had a 4-6 pixel gradient at the same feature).
alpha-3D checked too: /tmp/pf_after_a3d_02.png. macOS Release verified running with the
same build: /tmp/pf_after_mac.png.

**A measurement that did not work, recorded so it is not repeated.** Two attempts to count
"junction blend pixels" across whole screenshots (dusty-pink classifiers, with and without a
slate-neighbourhood gate) could not tell before from after: shaded magenta faces and genuine
cord-in-front-of-ribbon occlusion boundaries dominate any colour-range count, and the
auto-orbit means the poses differ. What worked was pose-independent: the mesh invariant
(zero visible mixed-structure triangles), plus a pixel transect across one identified
junction in each image.

### The pale band at a ribbon end was a shoulder, and the shoulder was one residue wide

Measured on the settled frame, half-width across a helix-to-coil junction:

| | Half-width at u=19 | at u=20 | Worst step per 0.1 residue |
|---|---|---|---|
| Before | 1.328 | 0.200 | **0.226 A** |
| After | 0.493 | 0.200 | **0.084 A** |

The cross section collapsed from full ribbon to cord across a single residue, leaving a broad,
nearly flat face pointing along the chain at the end of every ribbon. A face at that angle
catches the light quite differently from the ribbon it belongs to, and on screen that is a pale
band across the end - which is what has been reported as a see-through artefact for several
rounds. Protein G's sheet-to-coil junction measured the same: 0.218 A per tenth of a residue.

`taperedConfidence` now eases each element's confidence down toward its own ends over
`boundaryFadeResidues` (1.5, capped at a third of the element's length), smoothstepped, so the
shoulder becomes a wedge. 2.7 times gentler on both proteins.

**And a bug caught by the snapshot test, which is the reason to have one.** The taper is for the
*shape*: the colour must keep the element's own confidence, or every ribbon end washes out to
coil slate again. The per-ring `let paint = ss[paintResidue]` shadowed the levelled array and
indexed the tapered one, so it did exactly that - 15 of 86 snapshot colours moved, and 361
vertices carry the wrong colour attributes on a 20-residue test chain. Renaming the levelled
array to `paintTrack` fixes it; with the fix the colour snapshots are **unchanged**, which is
the proof the colour path is independent of the taper. Negative-tested both ways.

### An empty stage: the camera could get inside the protein (2026-08-29)

Marc reported no structure in the app. The mesh was not at fault - bounds measured sane
(trp-cage: mesh extent 24.99 A against a CA extent of 24.01 A, zero stray vertices, zero
non-finite) and the protein rendered on three consecutive launches.

The camera was. The stage normalises every protein so its bounding box measures **1.15 units**
across - a radius of about **0.575** - and `StageCamera.minimumDistance` was **0.35**. The
camera could therefore sit *inside* the protein, and since nothing culls a face here, from in
there you see the tube's interior or nothing at all: an empty stage with no explanation.

Pinch could always reach that in principle. Scroll-to-zoom, added the same day, made it a flick
of a finger. The floor is now 0.8, which clears the protein's own radius and the 0.05 near
plane. Pinned by `ZoomLimitTests`; negative-tested, the old 0.35 fails it at exactly the radius
comparison.

One test had to change with it: `pinchIsAnchored` pinched *in* to half of 1.5, which is 0.75 and
now below the floor, so it was asserting the clamp rather than the anchoring it is named for.
It pinches out instead.

**A hypothesis measured and rejected on the way.** The taper added earlier looked like a
candidate - short helices might have been all taper and no ribbon. Measured: at every fade
setting from 0 to 1.5 residues, a 3, 5, 7 and 12-residue helix all still reach a half-width of
1.29 of a possible 1.35. The taper does not thin short elements.

### The see-through artefacts: the tube was inside out (2026-08-29)

Every "see-through" report over this whole session had one cause, and an earlier measurement
sent every attempt at it in the wrong direction.

**The correction.** METRICS P2-05 concluded "this renderer culls nothing", from two
observations: `faceCulling = .front` had no effect, and reversing the triangle winding had no
effect. Both of those experiments were run on the **outline shell**, never on the protein.
Flipping the protein sweep's winding changes the render materially - so RealityKit *is* culling
back faces, and always was.

**The consequence.** The sweep wound its triangles with the geometric normal *opposing* the
vertex normals: measured at the time as 0 of 4,400 triangles agreeing, and recorded as a
curiosity to calibrate against rather than as a fault. With back-face culling active that means
the renderer discarded the tube's exterior and drew its **interior**, lit by the outward vertex
normals - which looks plausible on a straight run and hollow wherever a ribbon curves or ends.
The scoops, the pale bands, the grey showing through, the "transparency": all of it was the
inside of the tube.

Winding flipped, on the sweep and the caps together. 257 tests pass.

**Why no test caught it.** The mesh tests here calibrate on whichever winding the mesh happens
to have - deliberately, so they are robust to the convention - and that made every one of them
blind to the convention being wrong. `WindingTests.windingIsOutward` now pins it: negative-
tested, the old winding fails it at 9,200 of 9,200 triangles.

**What this invalidates.** Several fixes in this file were aimed at symptoms of this: the
outline shell's CPU far-facing selection was built to stand in for culling that was assumed
absent, and the missing end caps were described as showing the interior wall when they were in
fact showing straight through. The caps are still right - an open end is a hole either way.

## Phase 0d — which engine actually shows a protein folding (2026-08-29)

Marc's brief: *"a gradation from fully unfolded to fully folded with ordered secondary
structure, all compute on device, no precompute"*. Motion is not enough - Genie 2 moves
10.7 A and does it by expanding out of a blob - so every candidate here is measured on the
same four quantities by `Tools/fold_gradient_report.py`:

- radius of gyration per frame, against the compact expectation `2.2 * N^0.38`
- helix / sheet / coil content per frame, by **CA-only P-SEA** (biotite's implementation,
  the same method the Swift `PSEA` was validated against in Phase 1)
- CA-CA virtual bond length: a frame outside 3.8 +- 0.3 A is not a polypeptide and cannot
  carry a backbone tube
- contacts at the app's own 8 A, |i-j| >= 3 threshold

### The comparison, on identical measurements, all at 76 residues except where noted

| Engine | direction | Rg first -> last (A) | ordered SS first -> last | polypeptide frames | folds a **named** protein |
|---|---|---|---|---|---|
| ESMFold readouts (ubiquitin) | collapse of 0.87 A | 12.05 -> 11.36 | **0.49 -> 0.49** | 4 / 8 | yes |
| Genie 2 denoising | **expansion** | 1.22 -> 10.83 | 0.00 -> 0.75 | **3 / 11** | no |
| foldingDiff denoising, seed 11 | **expansion** | 10.14 -> 22.08 | 0.00 -> 0.71 | **3 / 11** | no |
| foldingDiff, seed 12 | expansion | 8.38 -> 14.27 | 0.00 -> 0.49 | 2 / 6 | no |
| foldingDiff, seed 13 | expansion | 5.48 -> 17.32 | 0.00 -> 0.62 | 2 / 6 | no |
| Coil-to-native morph, Cartesian | collapse | 21.3 -> 11.4 | 0.00 -> 0.43 | **30 / 200** | n/a - not folding |
| Coil-to-native morph, torsion space | collapse | 21.3 -> 11.4 | 0.00 -> 0.41 | 200 / 200 | n/a - not folding |
| **CA structure-based (Go) model, ubiquitin** | **collapse** | **21.35 -> 11.66** | **0.00 -> 0.38** (native 0.43) | **11 / 11** | **yes** |

Frames are sampled every 20th of 201 unless the row says otherwise, so the polypeptide-frame
counts are directly comparable.

Three things this settles.

**ESMFold's ordered-structure content does not change at all.** 0.49 at the first readout and
0.49 at the last. The secondary structure is already there before the first frame exists; the
headline visual has no subject on this engine.

**foldingDiff was re-examined and the earlier rejection stands, now on the trajectory's shape
rather than only on sample quality.** Its final backbones measure Rg/expected of 1.25, 1.52
and 1.94 across three seeds - extended, matching the 1.55 median recorded earlier - and the
ordered structure appears only in the last tenth of the run: 0.00 at frame 180 of 201, 0.71 at
frame 200. It denoises torsions, so its *bond lengths* are ideal by construction, but its
CA-CA distances are 2.4-3.6 A for most of the trajectory because the chain is coiled through
itself; only 2 or 3 frames in ten are polypeptides by the same test applied to every other
engine here.

**The interpolation baseline passes chains through themselves.** Minimum non-bonded CA-CA
distance over the trajectory, |i-j| >= 3:

| | minimum CA-CA (A) | frames containing a clash under 4 A |
|---|---|---|
| Cartesian morph | **0.20** | 190 / 200 |
| Torsion-space morph | **0.20** | 193 / 200 |
| Go model, same protein | 3.59 | 32 / 201 (all marginal, none below 3.59) |

A morph gives a perfect gradient and physically impossible intermediates. It is only usable
if it is labelled as a morph, and even then the visual has atoms passing through each other.

### The structure-based model: what it is, and the controls

`Tools/go_model_fold.py` (reference, numpy) and `Tools/go_model_fold.c` (the fast path)
implement the CA-level structure-based model of Clementi, Nymeyer & Onuchic (J Mol Biol
298:937, 2000; preprint cond-mat/0003460), written from the published equations - not ported
from SMOG2, which is GPL-2.0. Constants are the paper's own: `Kr = 100 eps`,
`Kt = 20 eps`, `Kd(1) = eps`, `Kd(3) = 0.5 eps`, non-native `sigma = 4.0 A`, native `sigma_ij`
the native CA-CA distance.

Two deliberate deviations, recorded because they are deviations:

1. The paper derives its native contact map from **CSU heavy-atom** analysis. This
   implementation uses a **CA-CA cutoff of 8 A with |i-j| >= 3**, because the app has a CA
   trace and nothing else. It gives 184 contacts on ubiquitin.
2. The dihedral term is written `1 - cos(dphi) + 0.5(1 - cos 3 dphi)`, minimal at the native
   torsion. The paper prints `1 + cos`; the phase convention there is unresolved and this
   form is the one that makes the native state the minimum, which is the whole point of the
   potential.

| Control | Result |
|---|---|
| Analytic forces vs central finite differences of the energy, per term (bond, angle, dihedral, contacts, all) | worst relative error **1.4e-09** |
| C implementation vs the numpy one, same configuration | max abs difference **4.7e-11** on forces of magnitude up to 274, i.e. **1.7e-13** relative |
| Dihedral gradient before the fix | 1.9 relative error - i.e. wrong, and the trajectory still looked like something. It is checked because of that, not despite it |

The unfolded starting state is a **self-avoiding random coil** (`random_coil`), not an
extended chain. Measured: a near-extended chain is assigned **96% sheet** by P-SEA, because an
extended chain *is* in the beta conformation residue by residue, so starting there makes
ordered structure go *down* over the trajectory. The random coil starts at 0.00 ordered
content at every length tested (20 to 314 residues) and its Rg is 1.6-2.0x the compact
expectation, near the Kohn scaling for denatured proteins.

### Nine named proteins, folded from a random coil on this Mac

Single temperature ramp `kT 1.0 -> 0.5`, `dt 0.015`, `gamma 0.1`, seed 1, steps scaled with
chain length. Timings are **serial, one run at a time**, single-core scalar C (double
precision, no SIMD, no neighbour list) on the M1 Max.

| Protein | aa | steps | us/step | compute (s) | Q final | RMSD to native (A) | TM | Rg first -> last (A) | ordered SS -> (native) |
|---|---|---|---|---|---|---|---|---|---|
| Trp-cage TC5b | 20 | 150,000 | 2.7 | 0.4 | 0.973 | **0.6** | 0.462 | 9.5 -> 6.9 | 0.00 -> 0.40 (0.40) |
| Pin1 WW domain | 34 | 150,000 | 5.6 | 0.8 | 0.971 | **0.7** | 0.862 | 12.8 -> 9.4 | 0.00 -> 0.18 (0.35) |
| Villin HP36 | 36 | 150,000 | 6.0 | 0.9 | 0.928 | 1.5 | 0.636 | 13.9 -> 9.6 | 0.00 -> 0.64 (0.67) |
| Protein G B1 | 56 | 224,000 | 11.7 | 2.6 | 0.978 | 1.6 | 0.825 | 22.0 -> 10.4 | 0.00 -> 0.64 (0.66) |
| Alpha-3D | 73 | 292,000 | 17.7 | 5.2 | 0.973 | **0.9** | 0.924 | 21.4 -> 12.9 | 0.00 -> 0.77 (0.82) |
| Ubiquitin | 76 | 304,000 | 19.3 | 5.9 | **0.995** | **1.0** | 0.915 | 21.3 -> 11.7 | 0.00 -> 0.38 (0.43) |
| Proinsulin | 86 | 344,000 | 23.5 | 8.1 | 0.994 | 3.3 | 0.629 | 21.2 -> 14.0 | 0.00 -> 0.26 (0.40) |
| Lysozyme | 129 | 516,000 | 46.4 | 23.9 | 0.987 | 1.1 | **0.956** | 24.9 -> 13.9 | 0.00 -> 0.33 (0.33) |
| Myoglobin | 153 | 612,000 | 62.3 | 38.1 | 0.985 | **1.0** | **0.956** | 26.7 -> 15.5 | 0.00 -> 0.67 (0.74) |

Nine of nine reach the native state. The reference is each trajectory's own bundled final
frame, which for ubiquitin is ESMFold's prediction at 0.83 A from experimental 1UBQ.

TM-score here is of the **Kabsch superposition on all residues**, not TM-align's optimised
alignment, so it is a lower bound; on 20- and 34-residue chains its `d0` is severe and RMSD is
the more informative column.

### Reliability: it is not one lucky seed

Ubiquitin, `gamma 0.1`, 300,000 steps, five different random coils and five different noise
streams: **5 of 5** reached Q >= 0.984, final RMSD 0.7, 1.0, 1.0, 1.2, 1.5 A. Villin at
`gamma 1.0` and 1.5 M steps: **5 of 5**, RMSD 1.1 to 3.1 A.

Shortening the run finds the floor: 3/3 fold at 150,000 and 200,000 steps, **2/3** at 100,000.

### What it costs, and whether it fits a 60 fps frame

`Tools/go_model_budget.py`. "Steps to fold" is the first frame at Q >= 0.9, so the settled
equilibrium afterwards is not charged to the fold. The renderer costs 1.65 ms of the 16.7 ms
frame at 314 residues, so the engine's share must stay under about 15 ms to be produced live.

| Protein | aa | steps to fold | compute (s) | ms/frame, 30 s playback | ms/frame, 60 s playback |
|---|---|---|---|---|---|
| Trp-cage | 20 | 24,000 | 0.1 | 0.0 | 0.0 |
| Pin1 WW | 34 | 48,000 | 0.3 | 0.1 | 0.1 |
| Villin | 36 | 30,000 | 0.2 | 0.1 | 0.0 |
| Protein G B1 | 56 | 142,240 | 1.7 | 0.9 | 0.5 |
| Alpha-3D | 73 | 167,900 | 3.0 | 1.6 | 0.8 |
| Ubiquitin | 76 | 118,560 | 2.3 | **1.3** | 0.6 |
| Proinsulin | 86 | 292,400 | 6.9 | 3.8 | 1.9 |
| Lysozyme | 129 | 286,380 | 13.3 | 7.4 | 3.7 |
| Myoglobin | 153 | 452,880 | 28.2 | **15.7** | 7.8 |

Peak resident set size, measured with `/usr/bin/time -l`: **1.5 MB** at 76 residues, **1.9 MB**
at 314. There are no weights: the entire model is the native CA trace, **912 bytes** for
ubiquitin as float32 and 3,768 bytes at 314 residues, against Genie 2's 33.8 MB `.mlpackage`.

### Where it fails, measured

**314 residues has not been made to fold, in three attempts.** The beta-2 adrenergic
receptor's 7TM core, 821 native contacts:

| Attempt | Result |
|---|---|
| `gamma 1.0`, `dt 0.015`, kT 1.0 -> 0.5, 3,000,000 steps (689 s) | stable, did **not** fold: helices formed (ordered 0.03 -> 0.61 against a native 0.78) and the chain *expanded*, Rg 39.4 -> 102.1 A, TM 0.034 |
| `gamma 0.1`, `dt 0.015`, kT 0.8 -> 0.4, 4,000,000 steps (935 s) | **the integrator diverged.** Q 0.000; a probe run shows CA-CA already at 2,819 +- 1,905 A by step 30,000 and Rg at 8e11 A by step 300,000 |
| `gamma 0.1`, `dt 0.005`, kT 0.8 -> 0.4, 100,000 steps (23 s) | **stable** - CA-CA 3.83 +- 0.07 A, Rg holding near 39 A, Q already 0.769 |
| `gamma 0.3`, `dt 0.005`, kT 0.9 -> 0.4, 3,000,000 steps (705 s) | stable and **it forms the secondary structure**: ordered content 0.03 -> **0.75** against a native 0.78, CA-CA 3.83 +- 0.07. It does not collapse: Rg 39.4 -> 46.0 A against a native 23.7, RMSD 42.4 A, TM 0.050, Q 0.943 |

So the divergence is the **timestep**, not the length: `dt 0.015` is fine to 153 residues and
unstable here, and `dt 0.005` is stable at 314. The last two rows also show why Q alone is not
enough at this size - **Q 0.943 at TM 0.050** is seven helices formed and none of them packed,
because most of a 7TM bundle's native contacts are local ones inside its own helices.

Four attempts, none reaching the native state, and the stable configuration costs three times
the steps at **235 us each**: 705 s for one run that still did not fold. **The practical
ceiling measured here is about 150 residues**, which is where a fold still costs tens of
seconds rather than tens of minutes.

**Cost grows with length faster than playback tolerates.** 2.7 us/step at 20 residues,
19.3 at 76, 62.3 at 153, **239.5 at 314** - and the number of steps needed grows too. This is
the O(N^2) pair loop with no neighbour list and no SIMD; both are available and neither has
been tried.

**A single temperature near the folding temperature is a coin flip.** Isothermal
`kT 0.7`, 2 M steps, ubiquitin: folded to 1.3 A. At `kT 0.6` the same run trapped at Q 0.75
and 9.4 A; at `kT 0.9` and 1.1 it never folded (Q 0.45, 0.28). Villin at `kT 0.7` reached
Q = 1.000 and had fallen back to 0.768 by the end of the run. The `kT 1.0 -> 0.5` anneal is
what makes 9 of 9 work, and it is the difference between a physics demo and something an app
can play on demand.

**Steps needed depend on friction, and low friction is much faster.** Ubiquitin, same anneal:
772,500 steps to Q >= 0.9 at `gamma 1.0`, **118,560 at `gamma 0.1`**. Folding studies use low
friction deliberately (Kaya & Chan, cond-mat/0212105, use gamma = 0.05); this measurement says
the same thing in this project's own units.

**The native state has to be trustworthy.** The potential's global minimum *is* the reference
structure, so the model faithfully folds to whatever it is given. Proinsulin's reference is an
ESMFold prediction at mean pLDDT 55.2 and it reaches Q 0.994 against it - a confident fold to
an unreliable target. GFP (pLDDT 43.3) and alpha-synuclein (33.3, intrinsically disordered)
were not run for this reason.

### Determinism, which Phase 3 requires

PLAN.md Phase 3 asks that the same protein yields the same piece. Two runs of the same
protein with the same seed agree to **0.000e+00 A** on every coordinate of every frame; two
different seeds diverge to 101.7 A on the final frame while both reaching the native state.
The engine is therefore reproducible on demand and different on request, and which one the
app wants is a setting rather than a rewrite.

## Phase 0e — the structure-based model in Swift (2026-08-30)

Ported from `Tools/go_model_fold.c`, and validated against it rather than against a picture of
a folded protein: the C's `--forces` mode dumps the force on every particle for one
configuration, and the Swift agrees to a **worst relative disagreement below 1e-9** across all
76 residues of a perturbed ubiquitin. That exercises every term - bonds, angles, dihedrals, the
12-10 native well, the non-native repulsion - and is a far stronger check than a folded
structure, because two different force fields can both fold a small protein.

| Measurement | Value |
|---|---|
| Swift, 76 residues | **18.93 us/step** |
| C, same protein | 19.15 us/step |
| Native contacts, ubiquitin, 8 A cutoff, \|i-j\| >= 3 | 184 (Swift and C agree) |

The Swift is as fast as the C. There is no penalty for the port and no reason to ship a C
target.

### How long a fold actually takes, which changes the architecture

Ubiquitin, 76 residues, seed 11, annealed 1.0 -> 0.55:

| Steps | Wall clock | Q (native contacts) | Rg |
|---|---|---|---|
| 200,000 | 3.8 s | 0.09 -> 0.49 | 20.0 -> 17.6 A |
| 500,000 | 9.5 s | 0.09 -> 0.53 | 20.0 -> 18.2 A |
| 1,000,000 | 19.0 s | 0.09 -> 0.52 | 20.0 -> 15.8 A |
| **2,000,000** | **38.1 s** | **0.09 -> 0.96** | **20.0 -> 11.6 A** |

**A complete fold is 38 s of compute on an M1 Max**, not the 2.3 s quoted in the Phase 0d
survey - that figure was for a run that does not finish folding. Two consequences: the
trajectory cannot be computed before playback begins, so frames have to stream as they are
produced; and the non-native repulsion, which is O(n^2) over every pair that is not a contact,
is the obvious target if that has to come down.

Note the transition is not gradual in the reaction coordinate: Q sits near 0.5 from 200k to 1M
steps and then completes. That is a real two-state transition rather than a slow drift, which
is what a funnelled model is supposed to show.

### The unfolded state

A self-avoiding random coil, not a straight chain: backbone angles across 85-145 degrees,
dihedrals uniform, rejected against a 4 A clash with backtracking two residues on failure.

| Residues | Swift, mean of 8 seeds | Python reference | Kohn's law |
|---|---|---|---|
| 40 | 14.6 A (11.3-22.6) | 15.2 A | 17.4 A |
| 76 | 19.8 A (14.4-30.0) | 19.6 A | 24.4 A |
| 129 | 29.5 A (23.7-45.4) | 27.7 A | 32.1 A |

Swift and Python agree closely. **Both run at 0.81 to 0.92 of Kohn's experimental scaling**,
so the law is the right order and not the right constant for this walk, and the test is written
around what the walk measurably does rather than around the idealised law.

A hypothesis measured and rejected on the way: that the coil was too compact because clashing
candidates were being accepted instead of backtracked. Adding backtracking changed the radii
**not at all** - byte-identical - because the walk never fails a placement at this clash radius.
The compactness was the walk's own nature, and the single-seed test that flagged it was the
thing at fault.

### The morph engine, and a claim of mine that measurement killed (2026-08-30)

Interpolating an unfolded coil into the native structure, 200 frames on ubiquitin:

| | Bond lengths | Closest non-bonded approach |
|---|---|---|
| Torsion space | **3.68 - 3.89 A** | 0.28 A |
| Cartesian | 0.55 - 3.89 A | 0.34 A |

Torsion space keeps the chain a chain: every CA-CA bond stays at a real distance, where a
Cartesian morph pulls the backbone through itself until its bonds collapse to a third of an
angstrom. That is the difference between a chain moving and a chain melting.

**What it does not do is prevent clashes.** 0.28 A against 0.34 A is no improvement, and I had
written into the source that torsion space fixed the clashing before measuring it. It does not:
interpolating torsions constrains bonded geometry and says nothing about whether two distant
parts of the chain pass through each other. Both numbers are now measured by a test so the
claim cannot drift back.

A morph is therefore never physically valid, and is labelled as an interpolation wherever it
appears.

### Two porting bugs, both caught by round-trip

**A dihedral sign.** `UnfoldedChain.place` produced the *negative* of the dihedral that
`StructureBasedModel.dihedral` measures - work the cross products through and the measured
angle comes out as `atan2(-sin phi, cos phi)`. Nothing noticed while the only caller was the
random coil, where the dihedral is drawn uniformly around the circle and a sign flip yields an
equally valid coil. The morph reads real dihedrals and replays them, and landed **34.7 A from
its own destination**. A round-trip test - read a chain's internal coordinates, build it back,
require the same chain - now pins it at under 1e-6 A.

**The first two bonds.** The morph's first three atoms were taken from a linear interpolation
of positions, so they ignored the interpolated bond lengths: a straight line between two
conformations is shorter than the arc the chain travels, and the first bonds fell below 3 A.
They are now constructed from the interpolated internal coordinates like every other atom.

### The engine abstraction (2026-08-30)

Three engines, selectable, all computed on device with nothing precomputed:

| Engine | Provenance | Confidence channel | Disclosure shown |
|---|---|---|---|
| Simulate | `structure-based-folding` | per-residue native contacts | "Simulated on device toward a known structure — not a prediction" |
| Morph | `geometric-morph` | per-residue journey completed | "Interpolation toward a known structure — not a fold" |
| Generate | `genie2-denoising` | denoising progress | "Generated — this protein has never existed" |

The disclosure lives on the provenance rather than on a view, so an engine cannot be paired
with the wrong claim: a structure-based fold arrives at a real protein's real structure without
having predicted it, and a viewer told nothing will reasonably assume otherwise, because that
is what folding software normally does.

A live fold is assembled into an ordinary `TrajectoryBundle`, so it plays through exactly the
path a bundled trajectory takes - same provider, same interpolation, same secondary-structure
and contact enrichment. There is no second playback path to drift.

**Per-residue native contact fraction** is what the colour ramp reads for a simulation: it
measures how much of each residue's own native contact set has formed, so the core locking in
first is visible while the termini are still loose. A residue with no native contacts of its
own takes the chain's overall value, because 0/0 is not 0 - scoring those zero painted them as
permanently unfolded even in the native structure, which a viewer would read as meaningful.

### Fetching a reference structure from AlphaFold (2026-08-30)

**The file URL is asked for, not constructed.** `AF-{accession}-F1-model_v4.cif` returns **HTTP
404** today: AlphaFold is on `model_v6`, and the version moved during this project. The
prediction API at `/api/prediction/{accession}` reports the URL for whatever the current
release is, along with the sequence, so one extra request removes a class of breakage that
would otherwise reach a user as "that protein does not exist".

Verified against the live service (P69905, haemoglobin subunit alpha): 142 residues, sequence
beginning MVLSPADKTNVK, pLDDT all within 0-100, radius of gyration in the range a folded
globular domain occupies. Those network checks are **opt-in** behind `PHONEFOLD_NETWORK_TESTS=1`
- a phase gate that fails on a train or when EBI is down stops being read - and the parser is
covered offline by a real trimmed excerpt of AlphaFold's own mmCIF.

**Column positions are read from the loop header, never assumed.** mmCIF declares its column
order and that order is not fixed across producers or versions. A test shuffles the declared
order, swapping `Cartn_x` with `occupancy` in both header and data, and requires identical
coordinates out - which a parser counting fields from the left would fail. Fixed-width slicing
would be worse still: it drops every `ATOM` line while `HETATM` happens to line up.

The sequence comes from the coordinates rather than from the API's sequence field, because a
prediction can cover a fragment of a longer entry and a sequence longer than the coordinates
misaligns every residue type in the app.

### The engine picker, live in the app (2026-08-30)

Trp-cage folded on the iPhone 17 Simulator by the structure-based engine, with nothing
precomputed: Rg 7.1 A, 29 contacts, 87% of native contacts formed, its helix present, and a
radius-of-gyration trace that is visibly *noisy* - thermal fluctuation in a real Langevin
trajectory, which looks nothing like the smooth monotone curves the ESMFold readouts gave.

Two bugs found by looking at the screen rather than the tests:

**Two columns headed CONTACTS.** `ConfidenceSource.nativeContacts` took the display name
"Contacts", which the panel already used for the contact counter - so the HUD showed CONTACTS
17 beside CONTACTS 56, two different quantities under one label. Renamed to "Native".

**The picker rendered one letter per line.** Sharing the header row with the title and the
colour control left each button a few points wide, and SwiftUI wrapped the labels vertically.
The picker has its own row now.

Neither was visible to a test: both are layout and labelling, and the suite was green
throughout.

### Halving the cost of a fold with a neighbour list (2026-08-30)

The non-native repulsion is `(sigma/r)^12` with sigma 4 A, evaluated over every pair that is
not a native contact. Measured on ubiquitin:

| Separation | Value of the term |
|---|---|
| 8 A | 0.000244 |
| 10 A | **0.000017** |
| 12 A | 0.000002 |

And almost every pair is beyond it: of 2,517 non-native pairs, **153 (6%) are within 10 A when
unfolded and 237 (9%) when folded**.

A Verlet list of the pairs within 10 A plus a 2 A skin, rebuilt when any atom has moved half
the skin, on a complete 2,000,000-step fold:

| | Wall clock | Per step | Q | Rg |
|---|---|---|---|---|
| Every pair | 45.3 s | 22.67 us | 0.09 -> 0.96 | 20.0 -> 11.7 A |
| **Cutoff 10 A, skin 2 A** | **20.9 s** | **10.46 us** | 0.09 -> 0.97 | 20.0 -> 11.7 A |

**2.2 times faster, arriving at the same place.** The force change is 8.3e-06 absolute on a
coil whose largest force is 1.4e+03, and 1.1e-05 at the native state.

Two things worth recording. A **larger skin is slower, not faster** - 24.1 s at 4 A and 28.3 s
at 6 A - so the cost is dominated by the size of the list rather than by how often it is
rebuilt, and the smallest skin that stays correct is the right one. And the fidelity test must
compare forces **absolutely**: at the native state the model sits in its own minimum, so the
largest force present is 7.5e-04 and a ratio against it reads 1e-05 as a catastrophe while the
same absolute change on a coil reads 6e-09. The denominator collapsed, not the accuracy.

### Does a longer run finish on the reference structure? (2026-08-30)

Marc asked for longer runs aimed at finishing on the target structure. Measured on ubiquitin,
from a self-avoiding coil **16.06 A** away in distance-matrix RMSD:

| Steps | kT final | Wall clock | Q | dRMSD to reference |
|---|---|---|---|---|
| 2,000,000 | 0.55 | 20.8 s | 0.967 | 0.86 A |
| 2,000,000 | 0.30 | 21.1 s | 1.000 | 0.49 A |
| **2,000,000** | **0.10** | **21.0 s** | **1.000** | **0.23 A** |
| 4,000,000 | 0.10 | 41.4 s | 1.000 | 0.26 A |
| 8,000,000 | 0.05 | 85.5 s | 1.000 | 0.16 A |

**The answer is not "run longer", it is "cool further".** Dropping the final temperature from
0.55 to 0.10 costs nothing at all - the wall clock is identical - and takes the fold from 0.86
to 0.23 A with every native contact formed. Doubling the run at the same temperature measured
0.26 A, no better than half the work, and quadrupling it reached 0.16 A for four times the
time. The fold arrives long before the run ends; what decides whether it settles onto the
reference is how cold it gets, not how long it wanders.

The default is now 0.10, so the app's engine finishes on the structure it was given: 0.23 A of
distance-matrix RMSD from a start 70 times further away.

Distance-matrix RMSD is used rather than superposed RMSD because it needs no Kabsch fit and
raises no handedness question: two structures with the same distance matrix are the same up to
rotation, translation and reflection, which is all "did it arrive" requires.
