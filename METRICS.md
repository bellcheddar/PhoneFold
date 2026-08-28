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
