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

### Release and debug do not fold to the same place (2026-08-30)

The convergence test failed the phase gate in debug while passing in release, on the **same
seed and the same step count**:

| Build | dRMSD to reference | Q | Wall clock |
|---|---|---|---|
| Release | 0.23 A | 1.000 | 21 s |
| Debug | 3.44 A | 0.79 | 502 s |

Not a bug. Langevin dynamics is chaotic, and a difference in the last bit of a force - which is
all it takes for an optimiser to contract a multiply-add differently - grows exponentially into
a different trajectory. Both are successful folds of the same protein under the same physics;
they are not the same fold, and no seed makes them so.

This is a sharper version of the rule already in CLAUDE.md that debug figures are meaningless
for performance: here the debug *result* differs too, not only the timing. The test therefore
asserts arrival only in release, and in debug - where 100,000 steps is a tenth of a fold and
still costs 36 seconds - asserts only that the chain is moving toward the reference.

Worth noting how it was caught: the release suite was green, and I committed on that before
reading the gate. The gate runs both builds, and it was right to.

### Type an accession, watch that protein fold (2026-08-30)

P69905 typed into the app on the iPhone 17 Simulator: the structure is downloaded from
AlphaFold, and the trajectory is computed on the device from an unfolded coil.

| | |
|---|---|
| Protein | Haemoglobin subunit alpha, 142 residues |
| Native contacts formed | **99%** |
| Radius of gyration | 14.5 A |
| Frame cost | 1.6 ms |
| Fold complete within | 98 s of launch, fetch included (Simulator) |

The result is the recognisable all-alpha globin fold, reached from a self-avoiding coil, with
the disclosure "Simulated on device toward a known structure - not a prediction" on screen
throughout.

At 142 residues this sits at the practical ceiling the Phase 0d survey estimated (~150), and it
holds: 99% of native contacts, not a partial collapse.

**A downloaded reference is not a precomputed trajectory.** The structure is an answer fetched
from a database; every frame of the fold toward it is arithmetic done here.

### Still outstanding for macOS distribution

The Mac app is not sandboxed, so the fetch works in development. An App Store build must be
sandboxed and will need `com.apple.security.network.client`, which is not yet in the project.
Recorded rather than added, because enabling the sandbox changes more than one thing and
belongs with the distribution work rather than in the middle of the engine.

## Phase 0f — Genie 2's reverse process in Swift (2026-08-30)

The exported `Genie2Step_L64.mlpackage` is **one denoising step**: `trans [1,64,3]`,
`rots [1,64,3,3]`, `timesteps [1]` in, predicted noise `z [1,64,3]` out. The schedule and the
reverse loop are not in it, so both have to be driven from Swift, and both have to match the
training-time definitions exactly - a diffusion schedule that is subtly wrong does not fail, it
denoises to plausible rubbish.

Ported and validated against the upstream Python:

**The cosine schedule matches to the precision the arithmetic allows, and no further.** Torch
builds it in float32, and the early betas are `1 - (ratio of two nearly-equal cosines)` -
catastrophic cancellation whose absolute error is one ULP of 1.0 however the arithmetic is
ordered. Computing it in `Double` gives a *mathematically better and wrong* answer: beta[1]
comes out 2.4625e-06 against the 2.5034e-06 the network was trained with, 1.6% out on the last
denoising step. Recomputed in `Float` it agrees to **1.1920928955078125e-07, exactly 2^-23**.
The tail agrees to 1.4e-05 relative, and the cumulative product to 7.6e-05 after a thousand
ULP-noisy multiplications. What that is worth where it is used: beta scales added noise as its
square root, and sqrt(0.3599776) against sqrt(0.3599825) differ in the sixth decimal.

**Genie 2's frames have determinant -1.** Not a porting mistake - the port matches upstream
element for element, worst disagreement below 1e-06. It falls out of the construction: the
binormal is perpendicular to the tangent, so `t . (b x n) = t . (b x (b x t)) = -1` exactly.
They are orthonormal but improper, the network was trained on frames built this way, and
"correcting" them to proper rotations would feed it something it has never seen.

Also noted, not fixed because it is upstream's and harmless here: `compute_frenet_frames` calls
`torch.cross` without `dim`, which picks the first axis of size 3. With a batch of one that is
the intended last axis; with a batch of three it would silently cross the wrong dimension.

### Genie 2 running live on the device (2026-08-30)

The reverse process drives the exported Core ML step model from Swift: 1000 denoising steps,
Frenet frames rebuilt from the translations each step, **37 s on an M1 Max** and several minutes
on the Simulator, which has no GPU for Core ML.

The result is a real backbone, and the geometry is what proves it: **mean CA-CA spacing 3.94 A**
against the 3.8 A of a real peptide. A wrong schedule, a wrong frame layout or a mis-strided
multi-array could not produce that. Rg runs 1.74 (noise) to 12.07 A.

**Validated against the reference implementation step by step.** Fed the identical starting
coordinates, at timesteps 1000, 999 and 998:

| | Swift | Python | Worst difference |
|---|---|---|---|
| `w_z` at t=1000 | 0.750007 | 0.750026 | 1.9e-05 |
| scale at t=1000 | 2.000025 | 2.000101 | 7.6e-05 |
| predicted noise, max magnitude | 3.245 | 3.243 | **0.010** per residue |
| updated translations | - | - | **0.015** per residue |

#### Some seeds diverge, and I could not attribute it to a defect in the port

Seeds 1 and 2 reach NaN part way through the reverse process - at frames 116 and 77 of 180 -
while seeds 3 and 4 complete cleanly at 3.86 and 3.91 A mean spacing. Ruled out by measurement,
not by argument:

| Hypothesis | Measurement | Verdict |
|---|---|---|
| Compute units - the ANE will not compile this graph | `.all` and `.cpuAndGPU` both give 3.94 A | Not it |
| Degenerate Frenet frames near collinear triples | `min\|cross\|` stays 0.17-0.53 all the way to the blow-up | Not it |
| A biased random generator | mean -0.0001, sd 1.0033, lag-1 correlation 0.0004 | Not it |
| The schedule | matches upstream to float32's own precision | Not it |
| The single-step update | matches Python to 0.01 in z and 0.015 in trans | Not it |
| Xcode's compiled `.mlmodelc` differing from the `.mlpackage` | identical size, identical results | Not it |

What is left is the one thing that cannot be matched: torch's random stream. The noise sequence
therefore differs, and the process is marginally stable - at t = 1000 the posterior mean is
multiplied by `1/sqrt(alpha_t)` = 2.0, so noise added early is amplified by every step after
it. Instrumented, a diverging seed grows `max|trans|` linearly - 3.4, 24.7, 49, 72, 92, 111,
NaN - while a good one decelerates to about 59 and settles.

**The sampler therefore retries with the next seed, and that is a workaround rather than a
fix.** It is labelled as one in the source. A test pins that seed 1 recovers to 3.86 A through
the retry, and a second pins that the same seed still fails honestly with `attempts: 1`, so the
first test cannot pass for the wrong reason.

#### The gate is now nine minutes

Almost all of it Core ML. The two full sampler runs are release-only: they spend their time
inside a compiled model that behaves identically whichever way the surrounding Swift was
optimised, so running them in both builds doubles the gate to learn nothing. The multi-array
round trip - the part that is actually Swift, and the one that would catch a stride mistake -
runs in both.

### All three engines, live (2026-08-30)

| Engine | What it does | Verified |
|---|---|---|
| Simulate | Folds a named protein toward its known structure | Haemoglobin alpha, 142 residues, 99% native contacts |
| Morph | Interpolates into the known structure | Lands on the reference to 0.05 A |
| Generate | Genie 2 invents a backbone from noise | 64 residues, Rg 10.0 A, 163 contacts, mean CA-CA 3.94 A |

Genie 2's default seed is **3, not 1**. Seeds 1 and 2 are measured to diverge, and although the
sampler retries, each wasted attempt is a thousand denoising steps - half a minute on a Mac and
several minutes on a phone. Starting from a draw known to complete costs nothing.

Note the radius-of-gyration trace for a generated protein runs the *other way* from a fold: it
climbs from 1.7 A as the noise ball opens out, where the structure-based engine's descends. The
two engines are doing genuinely different things and the trace shows it without being told.

### The macOS sandbox entitlement (2026-08-30)

An App Store macOS build must be sandboxed, and a sandboxed app has no network unless it says
so. `PhoneFold-macOS.entitlements` declares `com.apple.security.app-sandbox` and
`com.apple.security.network.client` — outbound only; the app never listens, so the server
entitlement is deliberately absent.

Applied **conditionally on the SDK**, `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`, because
`com.apple.security.app-sandbox` is not a valid iOS entitlement — iOS sandboxes every app
implicitly — and supplying it there is a provisioning error rather than a harmless no-op. One
target builds for both platforms, so the condition is not optional.

Verified: both platforms build, `codesign -d --entitlements` shows both keys in the signed
macOS binary, the sandboxed app launches and stays up, and the system log records **no sandbox
denials** for it.

**Not verified:** that the AlphaFold fetch actually succeeds under the sandbox. The Mac screen
was locked, so the result could not be read off the window, and absence of a denial in the log
is encouraging rather than conclusive. It wants one look at a fetch on an unlocked screen.

### All three engines verified on screen (2026-08-30)

| Engine | On screen | Disclosure shown |
|---|---|---|
| Simulate | Haemoglobin alpha, all-alpha globin fold, 99% native contacts | "Simulated on device toward a known structure — not a prediction" |
| Morph | Protein G B1, helix and sheet resolving, progress 83 | "Interpolation toward a known structure — not a fold" |
| Generate | 64 residues, two-helix bundle, Rg 10.0 A, 163 contacts | "Generated — this protein has never existed" |

The radius-of-gyration trace tells the three apart without a caption, which is a better piece of
honesty than the caption:

- **Simulate** descends and is visibly *noisy* — thermal fluctuation in a real Langevin
  trajectory.
- **Morph** descends perfectly smoothly. There is no physics in it and the trace shows it.
- **Generate** *climbs*, because the noise ball opens outward rather than collapsing.

### Polish pass (2026-08-30)

**The counter strip clipped on a phone.** It was a horizontal `ScrollView` with the compute
meter beside it, which truncated the last counter mid-value - "H/E/C 45/1" - against the
meter's "0.7 ms". A reading cut in half is worse than no reading: it looks like a layout fault
and cannot be trusted. `ViewThatFits` now takes the one-row form where the width allows and
drops the meter onto its own line where it does not, so nothing is truncated and nothing has to
be scrolled to be read.

**Trace labels sat on the traces.** "RADIUS OF GYRATION" was overlaid at the top-left of its
own plot and the line ran straight through the words. The labels are above the plots now.

**Genie 2 had no way to produce a second protein.** The accession row is meaningless for an
engine that invents rather than looks up, so with Generate selected it becomes a "New backbone"
button and a seed readout instead of a text field the engine cannot use.

**And a bug that pass exposed:** setting the engine started two runs - the launch override set
it and started one, and `onChange` started another - and the first task's cancellation error
then overwrote the healthy state, so the app showed "Genie 2 could not run: cancelled" over a
run that was proceeding normally. A cancelled run is now silent, because cancelling always
means a replacement is already under way.

One polish item was raised and **rejected on inspection**: the gallery leading with trp-cage
looked like an oversight and is not. At 20 residues it folds in a few seconds where ubiquitin
takes twenty, so with Simulate as the default engine it is the right first impression.

## Phase 3 — the score

### P3-01, the musical primitives (2026-08-30)

Scales, modes, MIDI pitch and the seed that makes a protein sound like itself. Pure arithmetic,
no audio, because the mapping is the competitive argument and a wrong note should be something
a test can assert on rather than a matter of opinion through a speaker.

**The seed is FNV-1a, deliberately not Swift's `Hasher`.** Standard hashing is randomly seeded
per process by design, so a piece built on it would be different every launch - the one thing
PLAN.md says must never happen. Pinned against values computed independently from FNV-1a's
published definition: ubiquitin's sequence hashes to `0xb3569d42cb3c6d78`. Negative-tested by
changing one constant of the algorithm, which the test catches.

**A test of mine that could not fail, caught by its own comment.** The stability test was first
written as `x == literal || x == x`, whose second clause is a tautology - while the comment
above it said "comparing it against itself would prove nothing". It now pins both literals.

Scale degrees run past the ends of the scale in both directions rather than clamping at the
octave, because register is driven by the trajectory: a long-range contact asks for a note well
below the tonic, and clamping would flatten exactly the contrast the mapping exists to show.

### P3-02, the style profiles (2026-08-30)

Styles are declarative JSON in `Apps/Shared/Resources/Styles`, referenced into the app bundle
as a folder reference rather than copied into the target. A copy would be free to drift from
the canonical file with nothing to notice it had, and the tests read the shipping file for the
same reason: a fixture copy would pass while the real style was broken.

**`voices` is keyed by `String`, not by `Voice`.** Swift encodes a dictionary whose keys are
neither `String` nor `Int` as a flat *array* of alternating keys and values, so an enum key
would have produced JSON no one could hand-edit - which is the entire point of putting styles
in JSON. Asserted directly, by decoding the encoded form back through `JSONSerialization` and
checking it is an object.

**A voice is a timbre, not a patch number.** PLAN.md specified a bundled SoundFont and flagged
an unlicensed one as a halt; Marc chose synthesis instead on 2026-08-30, which removes the
licence question entirely and leaves nothing to redistribute.

### P3-03, the sonification mapping (2026-08-30)

PLAN.md's core table, implemented row for row and measured against the trajectories that
exist. Three constants were set by measurement, and the first attempt at each was wrong.

**The gallery `.pftraj` files are not folds, and tuning to them would have tuned to the wrong
thing.** Measured across all thirteen: eight raw readouts each, of which readout 0 already
carries the entire contact map - 132 for alpha3d, 312 for lysozyme, 755 for the beta-2
adrenergic 7TM, 2,697 for GFP, 3,448 for alpha-synuclein - and mean pLDDT jumps to its final
value on readout 1 and then sits flat within 0.4 (lysozyme 94.3, 94.4, 94.5, 94.4, 94.3, 94.2,
94.1). They are eight readouts from the tail of one ESMFold recycle: a structure being
refined, not a protein folding. The constants below were measured on live engine runs, which
is the path the app defaults to.

**Contacts per readout, live engines, excluding each trajectory's first readout** (trp-cage 20,
villin HP36 36, ubiquitin 76 residues; structure-based at 200k steps, 180 frames):

| Engine | p50 | p90 | p99 | max |
|---|---|---|---|---|
| Structure-based | 2 to 6 | 6 to 16 | 10 to 24 | 15 to 37 |
| Morph | 0 to 2 | 2 to 6 | 3 to 9 | 3 to 13 |

A cap of **16 notes per bar** therefore leaves better than nine bars in ten whole. The first
attempt was 6, which dropped 62% to 99% of every trajectory's contacts - a cap that was
silently rewriting the fold rather than protecting a bar from a cluster. Measured on the
shipping path: villin under both engines now drops under 5%, asserted.

**Contacts are spread across the bar, not stacked on the downbeat.** Sixteen simultaneous
onsets are audible as one noise; sixteen spread across four beats are audible as sixteen
events.

**The first raw frame establishes state; it does not sound.** Its contacts are whatever is
already in contact when the trajectory begins - 9 to 40 local pairs for a random coil, the
whole contact map for a bundled readout. Reported as `establishedContacts`, distinct from
`droppedContacts`, because nothing went wrong.

**The plateau window is six readouts**, tolerance 1.5 on the 0-100 scale, floor 50. Measured
firing points across every trajectory and both classes:

| Trajectory | Fires at | Of |
|---|---|---|
| lysozyme, myoglobin, ubiquitin, villin, ww_domain (gallery) | 6 or 7 | 8 |
| villin HP36, morph | 174 | 180 |
| trp-cage, structure-based | 113 | 181 |
| ubiquitin, structure-based | 137 | 181 |
| GFP, alpha-synuclein, Genie 2 | never | — |

A window of 8 or more cannot fire at all on an eight-readout trajectory. A window of 3 fires on
a transient stall at readout 45 of 181, a quarter of the way into a structure-based fold. Six
is the only size that works on both.

**And the floor does real work.** GFP holds at mean pLDDT 34 to 37 and alpha-synuclein - an
intrinsically disordered protein - at 31 to 39, so neither ever resolves. That is PLAN.md's
"an intrinsically disordered region never resolves, so it stays a detuned wash for the whole
piece", falling out of the mapping rather than being special-cased. Genie 2 never resolves
either, for a different reason: its confidence is denoising progress, which climbs
monotonically and so has no plateau to find.

**A compaction gate on the cadence was measured and rejected.** Requiring compaction >= 0.8 as
well as a confidence plateau killed the cadence entirely for villin and ubiquitin under the
structure-based model at 200k steps, because a truncated fold never gets that compact. A piece
that can never resolve is worse than one that resolves early.

**Radius of gyration is normalised by chain length**, against two measured scaling laws:
denatured `Rg = 1.927 N^0.598` (Kohn et al., PNAS 2004, 101(34):12491) and native globular
`Rg = 2.2 N^0.38` (Flory scaling as fitted by Dima and Thirumalai, J. Phys. Chem. B 2004,
108(21):6564). Without it a 20-residue miniprotein reads as permanently compact and a
300-residue one as permanently extended, and the accelerando would be a property of the
protein's size rather than of its folding. Checked against real native radii: trp-cage at
7.2 A over 20 residues and lysozyme at 14.3 A over 129 both read above 0.9.

**Recycle boundaries only exist in the gallery.** Every live engine emits `recycle: 0`
throughout, so the harmonic modulation row of PLAN's table fires for ESMFold trajectories and
never for a simulated fold. Stated rather than papered over.

### P3-04, the musical clock (2026-08-30)

A fixed-tempo scheduler in front of a bounded jitter buffer, with no audio framework in it at
all: it converts bars to seconds and nothing else, so it can be tested exactly rather than
listened to.

**Tempo is per bar, not per piece.** The accelerando means every bar has its own length, and a
clock that assumed one tempo would drift further out of step with the fold on every bar.

**A moment's notes are sorted into beat order by the sonifier**, because the clock walks a bar
with a single watermark rather than searching. Out of order, a note is not merely late - it is
skipped until the playhead passes it, and a pad written after the contacts would never sound at
all. Found by writing the clock, not by listening.

**Starvation is reported only when a bar has actually run out.** The first attempt marked every
tick that landed on a downbeat as starving, because "nothing queued" and "the current bar has
not finished" look the same from inside the loop.

**The allocation gate, and the instrument being wrong twice.** PLAN.md asks for "no
audio-thread allocations detected in the scheduler (assert with a test harness)". Darwin's only
allocation counter is `malloc_zone_statistics`, which is **process-wide**, and that took two
corrections to measure honestly:

1. Measured inside the test process, the first bulk run through `advance` reported 343 blocks
   and every run after it reported 2 - ten times the iterations still reported 2. That 343 is a
   one-off warm-up of the code path, not per-tick allocation, so an assertion of "zero on the
   first run" would have been asserting something untrue about the runtime rather than
   something true about the scheduler. Bisection established this: an empty loop and a
   `removeAll` loop both report 2, so the probe itself is trustworthy, and the 343 tracked the
   *first* use of a path rather than the amount of work in it.
2. Then the same test failed under the full suite, reporting 2,099 and 8,092 blocks where it
   had reported 2 running alone. swift-testing runs suites in parallel, so the figure was
   dominated by whatever else happened to be allocating at that moment. **A process-wide
   counter cannot measure one thread**, and no amount of tolerance-widening fixes that - it
   only makes the test unable to fail.

The harness is therefore its own executable, `foldaudio-probe`, run as a subprocess by the
test. In a process doing nothing else, a delta is the scheduler's. Measured:

| Loop | Blocks |
|---|---|
| 10,000 bars played | 0 |
| 100,000 bars played | 0 |
| 10,000 bars held (starved) | 0 |
| 100,000 bars held (starved) | 0 |

The harness also reports that the played runs never starved, never refused a bar, and never
reallocated the output array, so a zero cannot come from the loop quietly doing nothing.

### P3-05a, the synthesiser and the offline render (2026-08-30)

The first sound. Voices are synthesised rather than sampled, which was Marc's call on
2026-08-30 and removes the SoundFont licence question PLAN.md flagged as a possible halt.

**A raw readout is one beat, not one bar - measured, not chosen for tidiness.** At one bar per
readout a 180-readout live fold rendered as an **eight-minute** piece: 480.1 s, against an
animation the app plays in 12 s. At one beat each the same fold is 121.9 s, which is a piece of
music. The gallery's eight-readout references become 6.1 s, which is short, but eight ESMFold
readouts of an already-folded protein do not contain more music than that.

**This forced the clock's design.** A beat's worth of contacts is spread across semiquavers, so
a flurry of sixteen runs four beats past the readout that made it and overlaps the three after
it. A scheduler holding one bar at a time would have to discard that tail, so the clock became
a bounded queue of absolute times.

**Two starvation bugs, both found by rendering rather than by reasoning:**
- Starvation fired at the exact moment boundary rather than past it, marking every on-time tick
  as a stall. `>` rather than `>=`.
- An unbounded catch-up filled the queue: advancing sixty seconds after one moment held until
  the queue was full and then refused everything. Holding is now capped at 8 beats per tick.

**Low confidence sounded silent, not murky.** Squaring velocity into amplitude, on top of the
low-pass and the voice's own gain, attenuated a low-confidence note three times over: the first
twenty-four seconds of a villin morph rendered at **0.001 RMS** against 0.115 elsewhere in the
same style. Velocity is now linear, and the low-pass floor is 500 Hz rather than 300 - a
one-pole filter is 6 dB per octave, so 300 Hz does not make a note dull, it makes it absent.
After the fix the same fold rises 0.004 to 0.134 RMS across two minutes: an audible crescendo
tracking the fold, which is what the mapping was for.

**Measured on the shipping path**, Fantasy style, 48 kHz:

| Trajectory | Engine | Duration | Peak | LUFS | Notes | Cadence |
|---|---|---|---|---|---|---|
| lysozyme | gallery | 6.1 s | 0.870 | -14.4 | 84 | bar 7 of 8 |
| ubiquitin | gallery | 6.1 s | 0.702 | -16.2 | — | — |
| trp-cage | structure-based, 400k steps | 91.1 s | 0.848 | -14.6 | 1,913 | bar 125 of 181 |
| villin HP36 | morph | 121.9 s | 0.544 | -21.5 | 1,193 | bar 175 of 180 |

No clipping anywhere, and none refused. The limiter's ceiling is 0.999 rather than 1: with a
ceiling of exactly 1 the asymptote *reaches* it in Float, leaving nothing for the sixteen-bit
conversion to round into.

**Loudness is ITU-R BS.1770-4 with both gates**, which matters here more than usual: a piece
opens on an unfolded chain, and ungated, nine seconds of silence in front of three of tone
reads six decibels quieter than the tone alone. Calibration is asserted by relation rather than
by an absolute figure - twice the amplitude is 6.02 dB - and the K-weighting coefficients are
the standard's own at 48 kHz, so any other rate returns `nan` rather than a plausible wrong
number.

**Still to reconcile, and it is Marc's call:** the app animates a fold in 12 s (`FoldPlayer.pace`,
`targetSeconds: 12`) while the music of the same fold runs 91 to 122 s. Both are defensible
alone and they cannot both stand. The score's duration is a single parameter, so this moves
either way once decided.

### P3-05b, the live spatial engine (2026-08-30)

`AVAudioEngine`, a pool of sixteen mono `AVAudioSourceNode`s, one `AVAudioEnvironmentNode` with
HRTF per source. Every note is its own spatialised source, placed at the coordinate of the
residue that produced it - the midpoint of the pair, for a contact - so the fold collapses
around the listener because the protein does. This is what Marc asked for when he overrode the
recommendation to defer spatial audio.

Nothing here re-implements the scheduling: it drives the same `MusicalClock` and the same
`SynthVoice` the offline renderer does, so the WAV that gets auditioned is the piece the app
plays rather than an approximation of it.

**Two API facts, verified against the SDK rather than assumed**, by compiling a probe before
writing the engine:
- `AVAudioSourceNode` conforms to `AVAudioMixing`, so a source node carries its own `position`
  and `renderingAlgorithm` and can be spatialised without a player node.
- The environment node reports rendering algorithms `[0, 1, 2, 6, 3, 7]` as applicable, HRTF
  among them.

**And one lifetime bug that only a crash could have found.** The first version cached each
node's `AVAudioMixingDestination`. Every test segfaulted at teardown - `EXC_BAD_ACCESS` in
`AVAudio3DMixingImpl::~AVAudio3DMixingImpl`, reached through `SpatialVoice.deinit` - because a
destination holds an unowned reference to its mixer and the engine released the environment
node before the array of voices. Setting `position` on the node itself needs no second object
and has no second lifetime to get wrong. The engine now also tears its graph down explicitly in
`deinit` rather than trusting release order.

**The thread handoff is an ownership flip, not a lock.** While a slot's `isSounding` is false
the scheduler owns its voice memory; while it is true the audio thread does. The scheduler
publishes with a releasing store after writing every field, and the render block acquires before
reading one. When the pool is full the oldest voice is *asked* to release and the new note is
counted as lost, because stealing would mean writing memory the audio thread owns.

Scale: **20 angstroms to the metre.** One-to-one, a 300 A chain would be spread over 300 m and
the whole piece would arrive from a point; at this scale it is a 15 m stage, and a 30 A folded
protein is about a metre and a half across - something a listener stands inside.

Tested through the real graph in `AVAudioEngine`'s manual rendering mode, so the environment
node, the HRTF, the connections and the render blocks are all exercised on a machine with no
audio hardware: a note at the N-terminus arrives louder on the left and one at the C-terminus
louder on the right, thirty-two simultaneous notes into sixteen voices lose notes without
producing a single non-finite sample, and a cut-off pad is silent once its 1.8 s release has
run.

### P3-07, the MIDI export (2026-08-30)

Standard MIDI file, format 1, 480 ticks per quarter, one channel and one named track per voice
plus a conductor track. **A real tempo map, not a baked-in speed**: the accelerando is the whole
point of the radius-of-gyration mapping, so positions are in ticks - which are
tempo-independent - and every tempo change is a set-tempo event. A file with one fixed tempo
would export a different piece from the one that played.

**The parser is written from the specification's byte layout, not from the writer.** A writer
checked only against its own reader is one mistake made twice. It handles running status and
note-on-with-velocity-zero, neither of which this writer emits, so the round-trip test is a
test of both halves.

**Independently validated.** `AVMIDIPlayer` accepts the file and reports 8.194 s;
`AVAudioSequencer` reads 6 tracks with sensible lengths in beats. Two of Apple's parsers, not
mine.

**And the round trip found a real defect in the export.** On a ubiquitin fold, 71 notes went in
and **61 came back**. MIDI cannot express two of the same pitch overlapping on one channel, and
the score asks for exactly that: the pad sustains four beats and a new one starts every beat,
so a chord tone overlaps itself four deep. A note-on for a pitch already sounding is ambiguous -
nothing can tell which of the two a later note-off ends. Earlier notes are now truncated at the
later one's onset, which is what a DAW does, and 70 of the 71 come back. The last one is two
notes of the same pitch on the same tick of the same channel: the same musical instant twice,
which the synthesiser plays as two voices and MIDI has no way to distinguish however it is
written. Asserted as "every distinguishable note", with the duplicate counted rather than
waved away.

### P3-08, the remaining four styles (2026-08-30)

Jazz, Rock, Pop and Surf, as declarative JSON alongside Fantasy.

**Two synthesis parameters were added first, so the styles are real rather than claimed.**
PLAN.md asks Rock for "distortion depth" and Surf for "tremolo picking", and the schema could
express neither - four style files differing only in key and tempo would have been a thinner
thing than the plan describes. `drive` is a soft saturation normalised by `1/tanh(k)`, so
turning it up adds harmonics rather than level (unnormalised, a distorted guitar is just the
loudest thing in the mix). `tremoloDepth` only ever takes level away, for the same reason.

`VoiceSpec` now decodes with per-field defaults, so adding these did not invalidate a style
file already on disk - including one a user has edited, which is what putting styles in JSON
was for.

Measured, lysozyme through the shipping command-line renderer:

| Style | Mode | Duration | Peak | LUFS |
|---|---|---|---|---|
| Fantasy | minor | 9.8 s | 0.727 | -16.0 |
| Jazz | dorian | 8.7 s | 0.687 | -17.2 |
| Rock | aeolian | 8.2 s | 0.861 | -14.5 |
| Pop | major | 10.0 s | 0.758 | -17.5 |
| Surf | phrygian | 8.1 s | 0.662 | -18.7 |

All five deterministic across three runs, none clipping, none refusing a note, all inside the
loudness range. The durations differ because tempo differs by style, and the piece is the same
number of beats.

**What the schema still cannot say**, stated rather than implied: Jazz's brushed kit and Pop's
sidechain are not expressible - there is no percussion voice and no ducking - so those two
styles are carried by key, voicing, swing and timbre alone. Surf's spring reverb is a global
reverb setting driven by confidence rather than a per-style effect. The `swing` field is
declared and stored but is not yet applied to note placement.

### P3-09, live style switching (2026-08-30)

PLAN.md: "Style switching is live and beat-quantised, never a restart."

**What makes it not a restart is that the harmonic state survives.** Rebuilding the sonifier
would send a piece that had modulated three times, or that had already reached its cadence,
back to the opening chord - which is the one thing a listener hears as a restart whatever else
stays the same. The position in the progression carries over, clamped rather than wrapped
(two styles rarely have progressions of the same length, and wrapping position 5 into a
four-chord loop lands somewhere arbitrary rather than somewhere late), and a piece that has
resolved stays resolved.

**What makes it quantised is that the timbres change by time, not by flag.** Notes sit on the
timeline up to four seconds ahead of the playhead, so swapping the voices outright would
retimbre notes written under the old style and already on their way - the switch would arrive
early and raggedly. Each note is given the voices in force at its own onset, and the switch
point is the next unwritten moment, which is by construction the next beat.

Writing the test found a trap in the test rather than the code: Fantasy's progression both
begins and ends on the tonic, so at index 5 the *degree* is back to the opening one and "has it
modulated" cannot be asked of the degree alone.

### P3-12, swing (2026-08-30)

The `swing` field was declared in every style file and stored, and did nothing. It now warps
note placement.

**A warp of the whole beat, not a delay applied to the offbeat.** Simply moving notes at 0.5
would swing the eighths and leave the semiquavers between them straight - so a contact flurry
would run in even sixteenths across a swung bar and sound like two pieces at once. Each beat is
instead warped piecewise-linearly: the first half stretched, the second compressed, pivot moved
late. Every subdivision then moves consistently, the warp is monotonic so nothing overtakes
anything, and a downbeat never moves at all.

At swing 1/3 the offbeat eighth lands on exactly 2/3 of the beat, which is the triplet feel
Jazz asks for. At swing 0 it is the identity - measured, not approximated: Rock re-rendered to
the same peak of 0.861 and the same -14.5 LUFS. Jazz moved from -17.2 to -17.8 LUFS and Surf
from -18.7 to -19.4.

### P3-11, the score's controls in the app (2026-08-30)

A row of its own under the engine picker: sound on or off, the five styles, and MIDI export.
Its own row because the engine and the style are separate choices - what computes the fold, and
what the fold sounds like - and on one line they read as a single control with eight options.

**One export path for both platforms.** The first version used `NSSavePanel` on the Mac and
wrote into the temporary directory on iOS, which is somewhere the user cannot reach: the button
would have appeared to work and delivered nothing. `fileExporter` with a `FileDocument` is a
save panel on the Mac and a document picker on iOS, and there is nothing to keep in step.

The exported MIDI is **the moments that were played**, logged as the music went, rather than a
second scoring of the same frames. A re-score would give the same notes - the mapping is
deterministic and that is tested - but exporting what was heard needs no such argument.

An About sheet now exists, because PLAN.md asks for the Tay et al. citation to appear in one
and there was nowhere to put it. It carries the citation, the trajectory's own provenance
disclosure, the style's description, the note that a disordered region never resolves, and that
every voice is synthesised rather than sampled.

### P3-10, haptics (2026-08-30)

PLAN.md: "transient on contact formation, sharper for long-range, a low rumble tracking core
packing, a distinct pattern at convergence."

**Split in two, for the same reason the musical clock has no audio framework in it.** Which
moments produce which feelings is the interesting part, is the same on a phone and a watch, and
can be asserted exactly; playing them needs an actuator this machine does not have.
`HapticScore` is pure and tested; `FoldHaptics` is the CoreHaptics half.

Mapped:

| Trajectory feature | Feeling |
|---|---|
| Contact, local (\|i-j\| < 6) | Transient, sharpness 0.30 |
| Contact, medium (6 to 11) | Transient, sharpness 0.55 |
| Contact, long-range (12+) | Transient, sharpness 0.85 |
| Long-range hydrophobic (the core) | Transient, intensity x1.25 |
| Compaction above 1/3 | Continuous rumble, intensity 0.15 to 0.60, sharpness 0.10 |
| Convergence | Continuous, 2 beats or more, soft and strong, once |

Capped at six taps a bar: a bar can carry sixteen contact onsets, and sixteen taps in a beat is
a buzz rather than sixteen sensations. Contacts below velocity 0.15 are not felt at all - that
is the floor the confidence mapping uses for a completely unresolved residue, and felt it would
be noise under the taps that matter. The rumble is silent below a third compaction: an unfolded
chain that buzzed continuously would be a constant rather than a signal, and the point is that
it grows.

**Haptics fire on the beat, not when the bar is queued.** A bar is handed to the audio engine up
to four seconds before it sounds; a tap four seconds ahead of its note is not one event reaching
two senses, it is a fault. A backlog plays only the most recent bar, because a pile-up released
at once is a jolt rather than a fold.

**`CoreHaptics` imports on every platform PhoneFold ships to, including ones with no actuator**,
so the header being present proves nothing - a Mac and a simulator both compile it and neither
can buzz. `supportsHaptics` is the only honest test, and a device that cannot buzz counts what
it could not play rather than throwing on the first event. The engine's `stoppedHandler` and
`resetHandler` are both wired: the system stops the engine on backgrounding and on a phone
call, and without them the first such event leaves a silently dead engine.

**Not yet verified on hardware**, and it cannot be from here. Added to the list needing Marc's
device.

### The capture tap, and what the audio architecture still lacks (2026-08-30)

PLAN.md's audio architecture list, item by item, honestly:

| Asked for | State |
|---|---|
| `AVAudioEngine` with voices fed by a bundled SoundFont | Synthesised instead - Marc's call; the licence halt cannot arise |
| `AVAudioEnvironmentNode` with HRTF, per-residue positions | Done |
| Musical clock decoupled from inference, holds a pad when starved | Done |
| Tap `mainMixerNode` for the Phase 4 capture path | Done, and tested: the tap hears the mix rather than silence |
| `AVAudioSession` `.playback` with `[.allowAirPlay]` on iOS | Done |
| macOS: default output device with a **user-selectable route** | **Not done.** It uses the default device; there is no route picker |
| visionOS: keep the session spatial | Uses the same `.playback` path as iOS; not verified on device |
| Parallel MIDI event log, for export and CoreMIDI out | Export done. **CoreMIDI out on the Mac is not done** |

The tap is installed here rather than in Phase 4 because the mixer belongs to this engine, and
a capture path reaching into it from outside would be one more thing to keep in step with the
graph. Its block runs on the audio thread, so the contract is written on it: no allocation, no
lock, no call back into the engine.

## Phase 4 — big screen, capture, and the iPhone ship

### P4-01, the mmCIF exports (2026-08-30)

Final model and multi-model trajectory, pLDDT in the B-factor column, models numbered from one
so `load file.cif` gives one object with n states.

**Biotite refused the first version, and that is the whole reason for validating against
somebody else's parser.** `KeyError: 'pdbx_PDB_ins_code'` inside `_fill_annotations`: a real
reader assumes the author columns and the placeholder columns are present, and my own parser -
written to my own layout - was perfectly happy without them. The `atom_site` loop is 21 columns
now rather than 16.

**And the round trip found a second defect, in the caller rather than the writer.** The
command-line exporter had `backboneOnly: true` hard-coded, on the assumption that a bundled
trajectory is a CA trace. It is not: the ESMFold gallery files carry real N, C and O, so the
export was discarding two thirds of the atoms it had. It now asks the readouts.

Measured, through Biotite, on the exported lysozyme trajectory:

| | |
|---|---|
| Models | 8 |
| Atoms per model | 516 (four per residue) |
| Elements | C, N, O |
| CA-CA | 3.80 A |
| N-CA | 1.46 A |
| CA-C | 1.52 A |
| C-O | 1.23 A |
| Biotite's own SSE annotation | 35 helix, 8 sheet, 86 coil |
| B-factor, model 1 | 74.36 to 85.36 |
| B-factor, model 8 | 82.13 to 96.96 |

The bond lengths are the textbook peptide values, Biotite's secondary structure annotation
finds a mostly-helical protein with a small sheet - which is lysozyme - and the per-model
confidence climbs across the trajectory the way the app measured it climbing. Genie 2's file
comes out as 201 single-atom models, correctly, because a diffusion run has no backbone to
write.

**One property of the format worth knowing:** Biotite's `AtomArrayStack` carries annotations
per atom, not per model, so reading a multi-model file as a stack collapses the B-factors to
the first model's. The file is right - reading model 8 explicitly gives model 8's values - but
anything colouring a stack by confidence is showing frame one.

**What the file says about itself.** Three of the four engines do not report pLDDT, so the
B-factor column's meaning is written into the file as an audit record, along with the
trajectory's provenance. A structure that leaves the app without those is one somebody will
later mistake for a prediction.

### P4-02, the offscreen render pass (2026-08-30)

PLAN.md forbids ReplayKit for the deliverable and asks for an `MTLTexture` pass at export
resolution. It is `RealityRenderer`, **verified available and rendering to a 1920x1080 texture
on this machine before a line of the stage was written** - because the alternative, drawing
`TubeMesh` again in raw Metal, would be a second implementation of the picture, and PLAN's own
gate is that the exported film and live playback are visually identical. Two implementations of
a picture are two pictures.

**The material moved into `FoldRender` first, for the same reason.** It was built in the app's
`FoldCanvas`, which was fine while the only renderer was the on-screen one. There is one
construction now and both paths call it.

**Three things this found, none of which reasoning would have:**

1. **A `RealityRenderer` scene has no lighting at all.** `RealityView` supplies a default
   environment; `RealityRenderer` supplies nothing, so a lit `SimpleMaterial` renders black -
   and against a near-black stage that is a frame in which the protein is present and
   invisible. Measured: 0% of the frame differed from the background. The offscreen stage now
   lights itself with a key and a fill.
2. **The background colour is given as sRGB and lands in a linear target.** The 0.047 asked for
   arrives as 1, not 12. The first coverage test assumed 12 and therefore counted every pixel
   as drawn - it reported 100% coverage and could not have failed. It reads the background from
   a corner of the frame now.
3. **`RealityRenderer` owns and commits its own command buffer.** An external `commit()` and
   `waitUntilCompleted()` waits for nothing and returns while the GPU is still drawing, which
   hands the encoder the previous frame. `onComplete` is the only signal that the pixels are
   there, so `render()` is async.

**And one in my own test harness worth recording:** comparing two 1920x1080 pixel arrays inside
an `#expect` produced **55 MB of console output** for a single failing line, because
swift-testing prints the values it compared. Frames are compared by digest now.

Framing lives in the stage rather than in each caller, because the distance depends on the
field of view and the caller does not know it: the first attempt guessed `radius * 3.2 + 6` and
put a 129-residue protein in the middle third of the frame. The field of view is set explicitly
rather than defaulted, so an SDK default that changed would not silently reframe every export.

Rendered, with nothing on screen, on a machine whose display was asleep: lysozyme (129
residues, radius 22.2 A), GFP (238) and the beta-2 adrenergic 7TM (314), all at 1920x1080.

**Where "visually identical" is still at risk**, stated rather than assumed: the live view gets
`RealityView`'s implicit default environment and the offscreen stage gets two explicit lights.
They are not the same lighting. Closing that gap means giving both paths the same explicit
lights, which changes the look Marc has already approved - so it is in BLOCKERS.md rather than
changed unilaterally.

### Marc's two decisions, 2026-08-31

**A fold lasts about forty-five seconds**, not two minutes and not twelve seconds.

Two knobs rather than one, because one is too coarse: readouts are grouped into moments, and
then each moment's length in beats is trimmed. At 180 readouts, grouping alone offers 55 s (two
per moment) or 36 s (three) and neither is 45; grouping by two and shortening the moment to
0.82 beats gives 45.

| Trajectory | Engine | Pacing | Duration | Cadence |
|---|---|---|---|---|
| villin HP36 | morph | 180 readouts to 90 moments of 0.82 beats | 51.7 s | bar 89 of 90 |
| trp-cage | structure-based, 400k | 181 to 91 moments of 0.82 beats | 38.4 s | bar 60 of 91 |
| lysozyme | gallery | 8 readouts, 1 each, 4.00 beats | 17.1 s | bar 7 of 8 |

The gallery stays at 17 s rather than stretching to 45: eight readouts spread over forty-five
seconds would be eleven-beat moments, and a moment longer than a bar has no shape - the pad it
holds is only four beats.

**Three consequences, all measured, none of them free:**

1. **The plateau detector had to be re-derived, and both obvious fixes were wrong.** It is a
   *rate* of change: six moments used to be six readouts, and 1.5 across them is a quarter of a
   point per readout. Grouping makes six moments twelve readouts. Leaving the tolerance alone
   stopped a morph resolving at all - 0 cadences where there had been 1, because its confidence
   saturates over only the last handful of readouts. Shrinking the window instead made it
   permissive enough that a **Genie 2 run cadenced**, which a generative sample must never do,
   having nothing to converge on. Scaling the tolerance with the grouping keeps the rate fixed
   and both cases correct.
2. **The contact cap bites harder**, and that is a real cost of a shorter piece rather than a
   defect: half as many bars means each carries twice as many contacts and reaches the
   sixteen-note cap more often. Measured 5.5% dropped against 1% before. Raising the cap is not
   the answer - sixteen onsets in a 0.82-beat moment is already thirty notes a second.
3. **The clock's queue was too small, and was silently losing music.** 128 notes looked like
   four times a moment's worth, but the queue holds everything inside the producer's four-second
   lookahead - eight moments in flight - and a trp-cage fold **refused 76 notes**. Sized for the
   lookahead now, at 512.

**And the lighting is unified on explicit lights.** The live view was lit by `RealityView`'s
implicit default environment and the offscreen renderer by two lights of its own, which
"exported video and live playback are visually identical" cannot survive. One rig in
`FoldRender`, used by both.

The lens was not identical either, and would have been missed if only the lighting had been
looked at: the offscreen stage was on a 60-degree lens against the live view's 42, which is a
visibly deeper perspective on the same protein. Both are 42 now.

### P4-03, the film (2026-08-31)

`AVAssetWriter` with a pixel-buffer adaptor for the picture and one sample buffer for the whole
soundtrack. **Not real time**: `expectsMediaDataInRealTime` is false on both inputs, which is
the whole difference between this and a screen recording - the writer waits for the renderer
rather than the renderer racing the writer, so a slow frame costs export time instead of a
dropped frame.

The soundtrack goes through the **real audio graph** - `FoldAudioEngine`'s manual rendering
mode, with the same `AVAudioEnvironmentNode` and HRTF the app plays through - so the film
carries the spatial mix rather than a flat approximation.

**Three defects, and the second one was in code that had been correct for weeks.**

1. **A deadlock, found by exporting something longer than a few seconds.** `AVAssetWriter`
   interleaves its tracks and stops accepting video once the video runs far ahead of an audio
   track that still expects data. Writing every frame and then the sound sat at **0.3% CPU for
   twenty-one minutes with a zero-byte file**, spinning in a `while !isReadyForMoreMediaData`
   loop that would never come true. The soundtrack is written first now and its input closed
   immediately, and the readiness loop has a ten-second deadline so a stall is an error rather
   than a hang.
2. **`isRawFrame` was an exactness test that only worked by arithmetic accident**, and pacing
   the animation from the score exposed it. An eighth of a second per readout at 60 fps is
   exactly five output frames, so the interpolation parameter landed on integers. The new
   pacing gives 145.5 frames per readout, the parameter steps by 0.0069, and it lands within
   1e-4 of an integer roughly never: **2 raw frames out of 8 readouts**. Contacts advance only
   on raw frames, so three quarters of the fold's events vanished and an eight-bar piece became
   two bars. A frame is now marked raw when it is the first one nearest a readout, which holds
   at any ratio.
3. **A caller can pace its frames by a different rule and the export will refuse.** The
   command-line renderer did exactly that, producing a fifteen-second picture against a
   thirty-eight-second soundtrack; the exporter now compares the two before drawing a frame and
   throws rather than writing a file that looks finished. The pacing rule moved into
   `Sonifier.Pacing` so every caller can reach it.

The offscreen stage uses `StageCamera` itself rather than a copy of its numbers, and the live
stage's normalisation verbatim - protein scaled to 1.15 across its bounding diagonal, camera on
+Z at the camera's own distance, the protein rotated rather than the camera. With the lens and
the lighting already matched, the film is framed and lit as the app is.

**The last frame is held while the music rings out.** The frame count comes from the style's
midpoint tempo, but the accelerando means the real piece is not that estimate, and there is a
tail besides: a villin fold gave 44.8 s of picture against 51.7 s of sound, so the last seven
seconds played over the end of the file. Repeating the final frame is what the moment wants
anyway - the cadence resolving over the finished protein - and brings the drift to **0.00 s**.

Measured: villin HP36 morphing, 3,105 frames at 1920x1080, 51.8 s of picture against 51.7 s of
sound, **23.9 MB**. trp-cage under the structure-based model, 2,686 frames, 29.5 MB.
Bitrate scales with the pixel rate rather than being fixed, because the same figure that is
generous at 1080p is a smear at 4K.

### P4-04, the presets and the caption (2026-08-31)

**A vertical film needed the camera moved, not just the texture resized.** The field of view is
vertical, so a 16:9 frame is limited by its height and the live stage's distance is already
right; a 9:16 frame is limited by its width, whose half-angle is `atan(tan(v/2) * aspect)` -
narrower at 0.5625 than the vertical - so a protein framed for landscape has its sides cut off.
Standing back by `1/aspect` puts the same protein in the frame, and the figure was checked
against the geometry rather than tuned by eye: a protein 1.15 across needs
`0.575 / (tan(21°) × 0.5625)` = 2.66 units where landscape needs 1.5, and 1.5 × 1.78 is 2.67.

Measured, lysozyme at 1080x1920: 1,025 frames, 17.1 s of picture against 17.1 s of sound,
drift **0.00 s**, 19.3 MB.

**The caption is drawn once and blended per frame.** The text does not change while the film
plays, so one text layout serves the whole export rather than one per frame - at 3,000 frames
that is the difference between an export and a wait. It is deliberately not a RealityKit text
entity: an entity would be *in* the scene, so it would orbit with the protein, be lit by the
stage's lights and sit at the mercy of the depth buffer. A caption belongs on the film.

Type scales with frame height, so a 4K export is not a 1080p caption at a quarter of the size -
asserted by comparing the inked fraction of the frame at 1080p and 4K rather than by reading
the point sizes back.

Core Text rather than `NSAttributedString.draw`, which is AppKit on one platform and UIKit on
the other and neither in a package that builds for both.

**The confidence is named in the caption, not just printed.** Three of the four engines do not
report pLDDT, and a bare number under the wrong name is worse than no number - the same reason
the mmCIF export writes its B-factor column's meaning into the file.

### P4-05, the export UI (2026-08-31)

Marc's call: the film goes to **Photos**, and MIDI and mmCIF go through the share sheet, since
Photos cannot hold them.

**The frames are recomputed, not kept.** A 52-second fold is about 3,100 frames and holding
them would be gigabytes. The stream is deterministic, so an export rebuilds the same frames
from the same provider - and gets to render at its own resolution rather than at whatever the
screen happened to be.

**`.addOnly` photo access, not full.** PhoneFold writes films and never reads the library;
asking for read access to do that would be asking for more than the feature needs, and it is
the kind of thing App Review asks about.

**A background task around the export.** iOS suspends an app a few seconds after it leaves the
screen, which for a two-minute render is a file that is never written and no error to explain
it. macOS does not suspend, so the guard is a no-op there rather than a second code path.

A determinate progress bar rather than a spinner: a render is minutes long, and a spinner says
only that something is happening, which is the one thing the user can already see. The preset
buttons disable while a render is in flight, because a preset changed mid-render would not
apply to the render in flight - offering it would be offering a control that does nothing.

Both platforms build. The Photos write itself needs a device or a simulator with a library, so
it is on the list that needs Marc.

### P4-06, onboarding (2026-08-31)

Three cards: what it does, what the music means, and the disclaimer.

**The disclaimer is PLAN.md's exact words, and it is neither softened nor buried.** PLAN says
"Marc will be asked about this and the app should answer first", so it is the last card before
the app opens, in the same type as everything else rather than in small print, and the same
words stand permanently at the *top* of About rather than in a footnote.

> PhoneFold visualises how a neural network converges on a structure. It is not a physical
> folding pathway, and no protein folds this way.

The "seen" flag is read from `UserDefaults` directly rather than through `@AppStorage`: the
stage needs the value in a `@State` initialiser to decide whether to present the sheet at all,
and a property wrapper only exists once the view does. The key is versioned so that a
materially different introduction can be shown again rather than silently skipped.

**A correction to my own comment, recorded because the rule matters more than the line.** The
first version of that comment justified avoiding `@AppStorage` with a cold-launch race I had
never observed - a plausible-sounding measurement that did not happen. Every number in this
file is measured; an invented reason in a source comment is the same offence in a quieter place.

### P4-07, the gallery's listening notes (2026-08-31)

Thirteen notes, one per bundled trajectory, as JSON in `Apps/Shared/Resources/Notes` - data
rather than a table in the app, for the same reason the styles are: they are editorial, Marc is
the one qualified to write them, and a word should be changeable without a recompile.
`TrajectoryMetadata` already had a `listeningNote` field that nothing filled; a bundle carrying
its own note still wins, so a trajectory generated in future can describe itself.

**The headline replaces the length on the gallery tile.** Thirteen proteins all captioned
"N residues" tells a visitor nothing about which one to press. "It never resolves - and that is
correct" does.

The notes are held to the same standard as the rest: they say what a listener would otherwise
get wrong. Alpha-synuclein's says it never resolves *and that this is correct*, because the
protein really is disordered and the prediction is right. GFP's says the barrel is not reached -
that trajectory's mean confidence is 34 - rather than describing a structure the film does not
show. Genie 2's says the protein has never existed. Tested, so a note that stopped saying those
things would fail rather than quietly mislead.

The tests read the shipping file and cross-check it against the trajectories actually present:
every protein has a note, no note describes a protein that is not there, and a headline is
short enough for a tile.

### P4-08, accessibility (2026-08-31)

**The colour-blind-safe palette already existed and was unreachable.** `ColourOptions
.accessiblePalette` and the amber-and-blue secondary structure colours were written in Phase 2,
and nothing in the app ever set the flag - the only way to see them was from a unit test. A
capability nobody can reach is not a feature. It is now driven by
`accessibilityDifferentiateWithoutColor`, read from the environment by the view and pushed into
the stage, because a `RealityView` coordinator has no environment of its own.

**Reduce Motion stops the orbit outright rather than slowing it.** A slow drift is still drift,
and the setting exists for people for whom that is the problem. A drag still turns the protein,
so nothing is lost but the motion nobody asked for. Contact flashes are suppressed under the
same setting - they are PLAN's "particle bursts".

**Reduce Transparency removes the aurora grade entirely**, for the same reason: the vignette is
a translucent wash, which is exactly what the setting asks not to be shown, and a fainter wash
is still a wash.

**Selection was carried by colour alone.** Every picker in the app - engine, style, export
preset - showed its selection as a blue capsule and nothing else, which VoiceOver cannot see
and a colour-blind user may not either. They now carry `.isSelected`, which is both spoken and
rendered by Differentiate Without Color.

**The stage had no text of its own**, being a protein turning in space. It now has a spoken
description built from the fold's state - protein, structure content in words rather than
percentages, the named confidence, and how far through it is - and `updatesFrequently`, so it
re-reads as the fold proceeds rather than describing frame one for a minute.

That description is a **pure function in `FoldRender`, and tested**, rather than a string
assembled inside a view where the only way to check it is to turn VoiceOver on and listen. The
tests pin the things that would otherwise quietly go wrong: a two-residue strand in a helical
protein is not "alpha and beta"; an unfolded chain reads as "unstructured coil" rather than as
the description giving up, because that is where every simulated fold begins; and the
confidence is named rather than numbered.

**Not done, and split out as P4-15:** Dynamic Type. The stage is built from fixed `.system(size:)`
point sizes throughout, and making them scale is a layout change to every control rather than an
attribute - it needs doing properly rather than annotated as finished.

### P4-12, the privacy manifest (2026-08-31)

`PrivacyInfo.xcprivacy`: no tracking, no tracking domains, no collected data types, and one
required-reason API - `UserDefaults` under `CA92.1`, "access info from same app", for the single
flag recording whether the introduction has been seen. Verified present in the built bundle
rather than only in the repository.

**The failure mode is staleness, not absence**, which is why there is a test rather than a
file. A manifest is written once and quietly stops being true the first time somebody reads a
file's modification date - and nothing fails, because Apple checks it at submission and not at
build. The test scans the shipping sources for every required-reason API symbol and asserts
that any category actually used is declared; it excludes the tests and the command-line tools,
because a manifest describes the binary Apple receives and `preview-style` is not in it.

It also checks that every declared reason is a code Apple publishes. A plausible-looking string
that is not on the list is rejected at submission, which is a long way from here.

**The app icon is not done and is not claimed.** PLAN.md asks for it to be generated with
Marc's `marcs-vibe-icon` skill "matching the portfolio house style", and that skill is not
installed on this machine. Drawing one anyway would be inventing the house style rather than
matching it, so it is in BLOCKERS.md as P4-16.

### P4-09, the mutation duet (2026-08-31)

PLAN.md calls this "the feature that gets it used by protein engineers rather than admired".
Two halves: what a substitution does to the fold, and what two folds sound like together.

**PhoneFold cannot predict a mutant's structure, and the feature does not pretend to.** There
is no sequence-to-structure model on the device, and a mutant has no AlphaFold entry. What a
structure-based model can do is the standard thing - keep the native structure and weaken the
interactions the substituted residue makes, which is how Go-model phi-value studies have
represented substitutions since Clementi, Nymeyer and Onuchic. The strength retained is a proxy
from Kyte-Doolittle hydropathy scaled by burial, with glycine and proline treated as more
disruptive than hydropathy alone implies, and burial taken from the native contact count the
model already has.

**And the obvious claim turned out to be false, which changed what the feature is.** I first
asserted that a destabilising mutation folds less completely. Measured on villin HP36, weakening
the most buried residue's contacts gave a **higher** final native fraction than the wild type -
1.00 against 0.89 at 200,000 steps. A Go landscape is smooth by construction, and removing some
of a residue's contacts can reduce frustration rather than add it. Which direction a
perturbation moves a fold is a property of that protein and that site, not something this model
can be assumed to get right.

So the feature is a **comparison, not a stability prediction**: the duet sonifies where and by
how much two folds diverge, which is real, rather than how much worse the mutant is, which
would be a claim about free energy that nothing here computes. The test asserts that the two
trajectories differ, and no longer asserts a direction.

**The dissonance mapping.** The two parts are in the same key by construction, so the interval
*between* them is the whole effect. Where they agree about a residue the mutant sings the wild
type's note; where they disagree its note is displaced along the conventional Western
consonance ordering - unison, octave, fifth, fourth, major sixth, major third, minor third,
minor sixth, major second, minor seventh, major seventh, minor second, tritone - reaching a
tritone at a 30-point confidence difference. Thirty is not a rounding difference: it is one
fold being confident where the other is not, which is the residue an engineer is looking for.

The ladder is written out where it can be argued with rather than buried in a lookup, and it is
a convention rather than an acoustic law.

**The wild type keeps the harmony.** A duet whose key was set by the thing under test would be
reading the answer off the experiment.

**The notation is checked against the sequence.** `A53T` written against the wrong isoform or
the wrong numbering perturbs the wrong residue - and the piece would still play, which is the
worst kind of wrong. The error names what was found: "Residue 1 is MET, not ALA".

Each fold gets its own MIDI channels and its own named tracks, so a duet opens in a DAW as two
labelled proteins rather than five tracks with two folds tangled in each. The mutant is offset
past channel 9, which General MIDI plays as percussion whatever the note says.

**A swift-testing gotcha worth recording:** `#expect(optional?.value == 64 + 6)` failed while
reporting `70 == 70`. Comparing a `UInt8?` against a literal *expression* decomposes into
something the macro mis-handles; assigning both sides to explicit `Int` locals first passes.
The values were right the whole time.

### P4-09 continued: two corrections the running found (2026-08-31)

**Hydropathy alone missed the most famous substitution in the protein used to test it.**
Villin HP36's core is three phenylalanines, and F11A - taking one of them out - is about as
destabilising a change as that protein has. With a hydropathy-only proxy it came out as a 5.6%
perturbation and the duet reported **every residue at exactly 0 divergence**: the two folds were
identical. F and A are two points apart on Kyte-Doolittle and a hundred cubic angstroms apart in
size, and cavity creation is precisely what makes F to A drastic.

Residue volume (Zamyatnin, Prog. Biophys. Mol. Biol. 1972, 24:107) is now a second axis, and the
larger of the two decides - because a substitution is drastic if it is drastic on *either*, not
only on both. A test spot-checks the table at both ends rather than taking it on trust: a
transposed digit there would silently change every duet.

This also corrected an assertion written under the old proxy: isoleucine to valine now keeps
0.84 rather than 0.95, because it really does remove 27 cubic angstroms. The volume axis was
right to disagree with the test.

**And the divergence readout was measured three ways before one of them was honest.**

| Statistic | On villin F11A | Why it is wrong |
|---|---|---|
| Final frame only | every residue 0 | Both folds aim at the same structure and reach it; the last frame says they never differed |
| Largest at any moment | four residues at ±100 | Early in a fold both chains are near zero and a one-frame difference in *when* a contact forms reads as a hundred points |
| **Mean over the fold** | 34 −8, 3 +7, 4 +7, 30 −6, 33 −5 | How much the two differed *for how long*, which is the question |

The mean is what shipped. The sign is kept, because consistently higher in the wild type is a
different finding from consistently lower.

Worth noting where the divergence lands: the mutation is at residue 11 and the differences show
at 3, 4, 30, 33 and 34 - the termini and the C-terminal helix - which is what perturbing a
packed core residue would be expected to do rather than a local effect at the site itself.

### P4-17, the duet in the app (2026-08-31)

A mutation field, a Duet button, and a readout naming the residues where the two folds
diverged and in which direction.

**The conductor plays a prepared score rather than bypassing the sonifier.** A duet is two folds
merged, so it cannot be written a frame at a time from either one - but the sonifier still runs
as the *clock*, deciding when a moment falls, and the merged moment is substituted for the one
it would have written. Substituting rather than bypassing keeps the picture and the sound on the
one timeline that the whole pacing rule exists to hold together.

**The field only appears for the structure-based engine.** A substitution perturbs native
contact energies and a morph has none to perturb: it would produce two identical folds and a
duet in perfect unison, which would look like a working feature and be nothing of the kind.
Offering the control there and quietly doing nothing is worse than not offering it.

**Two folds share one progress bar**, each taking half. Two runs of 0 to 100 look like the app
starting over.

**The stage shows the wild type.** A duet is an auditory comparison, and two proteins
superimposed would be a second thing to read at once. PLAN.md's description of the feature is
entirely about sound - "same key, two channels, pLDDT delta driving dissonance" - and nothing in
it asks for both structures on screen.

And starting a plain fold clears any prepared duet, or the next run would play the previous
comparison over a single protein.

## P4-10 external display (2026-08-31, Simulator)

| What | Measured |
|---|---|
| Scene roles the app was asked to configure, display attached | `UIWindowSceneSessionRoleApplication` only |
| `simctl io enumerate` connected screens | 2 (LCD id 1, TVOut id 2) |
| `simctl io screenshot --display 2`, PhoneFold running | "Timeout waiting for screen surfaces" |
| `simctl io screenshot --display 2`, home screen, no app running | "Timeout waiting for screen surfaces" |
| Simulator windows while TVOut connected (CoreGraphics, incl. offscreen) | 1 |
| `ExternalDisplaySceneDelegate` in the built binary | present, `_OBJC_METACLASS_$_ExternalDisplaySceneDelegate` |

The last two rows are the ones that matter together. The Simulator reports the screen as
connected but publishes no surfaces to it for **any** app including its own home screen, and never
opens the external display window, so it cannot be used to test this. The delegate class is
present under exactly the name the scene manifest references, which is the one failure mode that
would have been silent.

**Measured, and it cost an hour before it was believed:** `strings` on `PhoneFold.app/PhoneFold`
finds none of the app's own strings. Xcode 26 debug builds put the code in
`PhoneFold.debug.dylib` and leave a 40 KB launcher in its place, so inspecting the executable by
that name says "the file was never compiled in" about code that is demonstrably running.

## P4-11 Live Activity (2026-08-31, Simulator, iPhone 17 / iOS 26.5)

| What | Measured |
|---|---|
| `Activity.request` succeeded | yes — "live activity for Trp-cage TC5b on Simulate: true" |
| System accepted it | `chronod` "Consuming activity archive size 22680.0 B", "reload: succeeded" |
| Widget extension hosted to draw it | yes — `runningboardd` launched `com.mdeller.phonefold.widgets` (pid 76719) |
| Dynamic Island, app backgrounded | atom glyph + "48%", captured |
| Publishes over a 45 s fold at 60 fps | 99 of 2,700 snapshots (`ActivityReportTests`) |

The publish count is the point of the rate limit: 2,700 updates is far past the system's budget,
and pushing them all freezes the banner at whatever got through rather than failing loudly.
99 is measured, not derived - a whole percent of 2,700 frames is 27 of them and the arithmetic
says 100, but the comparison accumulates in a `Double` and a couple of intervals land a hair
under 0.01.

**Not verified here:** the Lock Screen banner. The Simulator's Device > Lock does nothing on this
machine - the menu item presses, the screen does not lock - so the banner's own layout has never
been seen, only the Dynamic Island's. Same view code, different container.

**Two things that cost time and are worth writing down.** `#if canImport(ActivityKit)` is true on
macOS: the module is present and every symbol in it is `@available(macOS, unavailable)`, so the
block compiles and fails inside on eight lines. The guard has to be `os(iOS)`. And
`ActivityKit.Activity` is a plain non-Sendable class whose `update` and `end` are nonisolated -
held in a `@MainActor` property it can never be passed to them, and no amount of `Task { }`
helps, because the value carries the isolation. It has to live outside any actor.

## P4-14 Genie 2 divergence: the root cause (2026-08-31, M1 Max, release build)

`swift run --package-path PhoneFoldKit -c release genie2-probe`, run from the repository root.
Six seeds, 1,000 reverse steps each, `scale` 0.6.

| seed | as shipped | max &#124;CoM&#124; | CA-CA | re-centred | max &#124;CoM&#124; | CA-CA | Rg |
|---|---|---|---|---|---|---|---|
| 1 | diverged at step 422 | 113.98 | — | OK | 0 | 3.86 | 11.4 |
| 2 | diverged at step 621 | 112.33 | — | OK | 0 | 3.86 | 10.9 |
| 3 | OK | 49.09 | 3.86 | OK | 0 | 3.85 | 10.0 |
| 4 | OK | 87.27 | 3.91 | OK | 0 | 3.86 | 10.5 |
| 5 | OK | 105.50 | 3.94 | OK | 0 | 3.85 | 12.1 |
| 6 | diverged at step 481 | 110.12 | — | OK | 0 | 3.86 | 10.9 |

Å throughout. **3 of 6 seeds diverged; with the centre of mass projected out each step, 6 of 6
complete.** The cause was that `sampleOnce` centred the coordinates it *recorded* and never the
ones it fed back in, so the centre of mass random-walked to 114 Å on a chain whose own radius of
gyration is 11 Å — far outside anything the network saw in training — and the posterior mean's
`1/sqrt(alpha_t)` factor, 2 at t = 1000, amplified the resulting nonsense at every later step.

**The spacing is the second, independent signal.** Ideal consecutive CA-CA is 3.8 Å. The seeds
that survived without re-centring were drifting up to 3.94 Å and scattering across 0.08 Å;
re-centred, every seed lands in 3.85 to 3.86 Å, a range of 0.01 Å. And Rg 10.0 to 12.1 Å for 64
residues sits on Dima and Thirumalai's native scaling, 2.2·N^0.38 = 10.5 Å — these are compact
globular backbones, not merely finite ones.

**Why it survived the earlier investigation.** Everything checked against the Python reference
agreed, and all of it was a *single step from identical coordinates*: at step one both are
centred, so the one quantity that only drifts over a trajectory is exactly the one a single-step
comparison cannot see.

Consequence: the app's Genie 2 seed default goes back to **1**, from the 3 it had been moved to
in order to skip the two seeds that failed.

## P4-15 Dynamic Type (2026-08-31, Simulator, iPhone 17 / iOS 26.5, screen 402 pt @3×)

Thirty-three `.font(.system(size:))` calls in the app were replaced with a `.scaledFont` that
honours Dynamic Type. Making the text scale exposed a layout that could not.

The control column's laid-out width, measured with `.measured(_:)` at each content size:

| content size | before | after |
|---|---|---|
| large (default) | 402.00 | 402.00 |
| extra-extra-extra-large | 402.00 | 402.00 |
| accessibility-medium | 402.00 | 402.00 |
| accessibility-large | 402.00 | 402.00 |
| accessibility-extra-large | 402.00 | 402.00 |
| accessibility-extra-extra-large | 405.00 | 402.00 |
| accessibility-extra-extra-extra-large | **465.67** | 402.00 |

465.67 pt on a 402 pt screen is 1,397 px of a 1,206 px display: the stage was 16% wider than the
phone and centred, so it bled off **both** edges and the title's left half was off-screen.

**Three plausible fixes in a row changed nothing at all** — the engine row, the gallery and the
HUD counters were each fixed and each turned out to be a passenger. What settled it was
measuring rather than reasoning:

- `.measured(_:)` on every row: all of them reported 465.67 or 465.67 minus their own padding,
  so none of them was the cause.
- The root's own `GeometryReader` read **465.67 while `UIScreen.main.bounds.width` read 402** —
  proving the overflow was above the whole view tree, not inside one row.
- A 4 pt red border on the root was **not visible on any edge**.
- Settings.app at the same content size rendered perfectly, so it was PhoneFold, not the
  Simulator.

The cause was three `fixedSize()` labels — Sound, MIDI and Export film — plus the 32 pt route
picker. `fixedSize` is right for them (otherwise "Export film" wraps mid-word) but it makes them
unshrinkable, and at the largest size those four alone wanted 425.67 pt of a 402 pt screen.
They now drop to icon-only at accessibility sizes, where they all carry `accessibilityLabel`s
already.

**Capped at `accessibility3`, and stated as a cap.** Above that the column fits horizontally but
not vertically: the controls alone are taller than the phone, the title gets pushed up under the
Dynamic Island, and no room is left for the protein. PhoneFold is a stage. The onboarding cards
and About are sheets, are text and nothing else, and are deliberately not capped.

## P4-13 twenty consecutive folds (2026-08-31, M1 Max, release build)

`swift run --package-path PhoneFoldKit -c release leak-probe`, from the repository root. Each
fold simulates trp-cage with the structure-based model, builds the frame stream, scores it,
renders the audio offline and puts five frames through the offscreen Metal stage. Physical
footprint (`task_vm_info.phys_footprint`, the number jetsam uses) after each fold, in MB:

| fold | 20-fold run | 40-fold run |
|---|---|---|
| 1 | 236.1 | 235.7 |
| 2 | 235.7 | — |
| 3 | 283.6 | — |
| 8 | 395.5 | — |
| 17 | 400.0 | 400.2 |
| 18 | **325.1** | **334.0** |
| 20 | 326.0 | 335.0 |
| 26 | — | **260.1** |
| 40 | — | 328.5 |

**No leak. The footprint sawtooths between about 236 and 401 MB and is reclaimed twice.** A leak
does not give memory back, and this gives back 75 MB at fold 18 and another 77 at fold 26. Over
the 40-fold run the mean of the second half is **47.1 MB below** the mean of the first.

**Twenty folds is not enough to tell, which is worth recording because PLAN asks for twenty.**
The first reclaim lands at fold 18, so a twenty-fold window sees only the climb and reports
+47.0 MB between halves - indistinguishable from a slow leak. The gate therefore runs forty.

`Tools/verify_phase.sh 4` now runs this and the MP4 probe rather than skipping both. What is
still skipped is the full accessibility audit, and deliberately: VoiceOver rotor order, focus
escape and gesture conflicts are not things a script can judge, and a check that only asserted
labels exist would pass an app that is unusable.

## P5-01 PhoneFold Studio (2026-08-31, macOS)

| What | Measured |
|---|---|
| Target builds for macOS | yes (`verify_phase.sh 5`, Release) |
| Window on launch | 1412 × 882, titled "PhoneFold Studio" |
| File menu | New Fold Window, Close, Close All |
| Help menu | PhoneFold Studio Help, What PhoneFold Is Not |
| ⌘N opens a second window | yes — window count 1 → 2, then 2 → 3 |
| iPhone build still green after the model refactor | yes |

**Not verified: what the window looks like.** `screencapture -l` returns "could not create image
from window" because this terminal has not been granted Screen Recording. That is Marc's to
grant in System Settings → Privacy & Security, and until then every macOS check here is
structural rather than visual.

## P4-19 the stage's width (2026-08-31, Simulator, iPhone 17, screen 402 pt)

Found by taking the README screenshot. Widths from `.measured(_:)`, in points:

| Row | Before | With `FoldCanvas` replaced by `Color.clear` | After the fix |
|---|---|---|---|
| `zstack` | 402.00 | 402.00 | 402.00 |
| `column` | 402.33 | 402.33 | 402.33 |
| `header` | **451.33** | 402.00 | 402.00 |
| `canvas` | **451.33** | 402.00 | 402.00 |
| `hud` | **451.33** | 402.00 | 402.00 |
| `gallery` | **451.33** | 402.00 | 402.00 |
| `engine` / `score` / `export` | 411.33 | 362.00 | 362.00 |

A `RealityView` reports an intrinsic width of its own, and as a direct child of the stage's
`VStack` it handed that ideal to every sibling. The substitution is the proof: swapping that one
view for `Color.clear` put every row back to 402, so it was the canvas and not any of the rows.
Drawing it in an `.overlay` on `Color.clear` keeps it there, because a colour has no intrinsic
size and an overlay never influences what it is drawn on. Verified at every content size from
default to accessibility-extra-extra-extra-large: every row is 402.

**Two instruments lied before this was found, and both are now fixed.** The on-glass diagnostic
overlay is one long unwrapped monospaced line, so it reported its full length as an ideal width
and widened the column itself: a debug overlay that breaks the layout it exists to diagnose. And
`.measured(_:)` reported only `onAppear`, so a row that is empty at launch and full once the fold
has readouts reported its empty width for ever, which sent a real investigation after a counters
row "measured at 0 points".

The counters row itself is reverted to `ViewThatFits`. P4-15 had replaced it with a scrolling row
on the theory that it caused the accessibility overflow; it did not, and the scroll view was
worse, because it has no intrinsic width to contribute and the enclosing row then sized itself to
the compute meter alone.

## P5-03 batch mode (2026-08-31, M1 Max, release build, machine shared with another job)

Five records, both identifier kinds, resolved offline from the bundled trajectories, morph
engine, multi-model mmCIF out. `Tools/fixtures/batch_five.fasta`.

| What was varied | Wall clock | Result |
|---|---|---|
| 180 readouts, 45 s target | 1237 s | 5 folded, 0 failed, 0 warnings |
| 48 readouts, 45 s target | 1217 s | 5 folded, 0 failed, 0 warnings |
| folding only, no delivery | **0.1 s** | 5 folded |
| 180 readouts, **4 s target** | **271 s** | 5 folded, 0 failed, 0 warnings |

**The obvious knob was the wrong one, and it was in the code before it was measured.** Cutting
readouts by 73% changed the run by 1.6%, because `Sonifier.pacing` normalises to a target
*duration*: fewer readouts are simply held on screen for longer, and the stream is about 2,700
frames either way. `BatchDelivery` had a `frameCount` property that was assigned and never read,
which is worse than no knob at all, and a comment asserting it was "the dominant cost".

Isolating the fold settled it: **all five folds take 0.1 s**, so the entire rest of the run is
the frame stream, each frame re-deriving contacts and secondary structure. Shortening the target
duration is the only real lever, and it is honest about the trade: a shorter target is a shorter
film, not the same film computed faster. The gate uses 4 seconds because it is testing the
orchestration, not the animation.

These numbers were taken while another project's job held about a quarter of the machine, so they
are an upper bound rather than a clean figure. The 1.6% and the 4.5x are ratios measured under
the same load, which is what the conclusion rests on.

## P5-05 CoreMIDI virtual source (2026-08-31, macOS)

| What | Measured |
|---|---|
| Loopback tests (real CoreMIDI input port connected to the source) | 5 passing |
| MIDI sources on the system before toggling | none |
| MIDI sources after "Send MIDI to Other Apps" | `PhoneFold` |
| After toggling off, and after quitting | none |
| Live channel against `MIDIFile.channel(for:part:)` | identical |

The system-wide check is the one that matters and it was run from **a separate process**: a
standalone Swift program enumerating `MIDIGetNumberOfSources()`, which is what a DAW does. The
app appearing in its own test proves nothing about whether Logic can see it.

**The endpoint is created on demand and disposed on the way out.** Creating it at launch would
put PhoneFold in every DAW's device list for a user who never asked, and leaving it behind on
quit would leave a dead device there. Both directions are checked above.

The live source and the file export share `MIDIFile.channel(for:part:)`. Two maps would be the
worst kind of wrong: each file looks right alone, and they only disagree once someone lines a
recorded take up against the exported `.mid` hours later.

**Not verified, and it is the human gate:** that the MIDI is musically usable in a DAW. Timing
here is approximate by construction - each note is dispatched by sleeping until its beat, which
carries task-scheduler jitter of a few milliseconds, where the synthesiser's own notes sit on the
audio clock exactly.

## P5-04 ProRes and image sequence (2026-08-31, machine loaded — see BLOCKERS)

One record, morph engine, 3-second target, verified with ffprobe rather than by reading back
this repository's own writer:

| What | Measured |
|---|---|
| `--codec prores422hq --film` | `codec_name=prores`, `format_name=mov`, 124 MB for 3 s |
| Audio track in that file | `pcm_s16le` — uncompressed, as a mastering codec deserves |
| `--image-sequence` | 580 PNGs, `frame.000000.png` upward, plus a README |
| Film-writer suite with the new codecs | 5 passing |
| Image-sequence suite | 5 passing |

**A real bug, caught by an existing guard.** The first ProRes run failed with "the picture is
9.7 s and the sound is 44.0 s; the frames were not paced from the same rule as the score".
`BatchDelivery` paced the frame stream to the requested target while `FilmExporter` derived its
own score at the default 45 s. The exporter's drift check is what refused it, which is exactly
what that check exists for: it had never fired in anger before. `FilmExporter.Options` now
carries `targetSeconds` and the batch passes its own through.

This never surfaced in the batch gate because that gate writes mmCIF only, so no score was built.
A cheap check can be silent about the thing an expensive one exercises.

**Not to be trusted as a timing:** 363 s for a single three-second ProRes film. The machine was
saturated by another project's job. Flagged in BLOCKERS.md with the rest.

## P5-06 structure comparison (2026-08-31)

Real files: AlphaFold **P00698** (hen lysozyme) against the **1LYZ** crystal structure, fetched
from EBI and the RCSB.

| Step | Result |
|---|---|
| mmCIF reader on an RCSB file (1UBQ) | 76 alpha carbons, coordinates match |
| PDB and mmCIF of 1UBQ, read independently | agree residue for residue on all 76 |
| AlphaFold vs 1LYZ, matched by number | **18.11 Å over 129 residues** |
| The same, with the mismatch check | refused: "only 7% of the 129 matched residues have the same name" |
| Offset the check derived | **18** — hen lysozyme's signal peptide, exactly |
| The same comparison at that offset | **0.54 Å over 129 residues** |

**Matching by residue number is necessary and not sufficient, and the second half was only
visible on real data.** Matching by array position pairs a prediction's residue 1 with a crystal
structure's residue 3 whenever the disordered ends are missing, so the code matched by number
from the start and the synthetic tests confirmed it. Real files then produced 18.11 Å, which is
not a bad prediction: it is the same structure eighteen residues out of register, because a
UniProt entry includes the signal peptide and a structure of the mature protein does not. Both
files number from 1 and mean different things by it.

The fix is cheap and decisive: compare the residue *names* at the matched positions. Seven per
cent agreement is not a comparison. The offset is then found by maximising name agreement over a
range of shifts, which turns "these do not line up" into "shift by 18", and never touches
coordinates - searching over superpositions would be a structure alignment, which is a different
program and explicitly not what PLAN asks for.

**A crash found only by real data.** The first run on real files exited 139. `String(format:)`
bridges to C varargs and `%s` with a Swift `String` is undefined behaviour; every synthetic test
passed because none of them formatted a residue name.

## The CoreMIDI suite's full-run failure (2026-08-31) — resolved, and my first diagnosis was wrong

| Condition | Result |
|---|---|
| `MIDISourceTests` alone | 5 pass |
| With `OfflineRenderTests` | pass |
| With `OffscreenStageTests` + `FilmWriterTests` (Metal-heavy) | pass |
| With `FoldAudioEngineTests` (live AVAudioEngine) | pass |
| Full suite, **parallel** | **4 of 5 fail**, `OSStatus -2` |
| Full suite, **`--no-parallel`** | **535 tests in 86 suites, all pass** (1714 s against 709 s) |
| Standalone: 80 clients, then 40 virtual sources | no failure |
| Standalone: 200 create-and-dispose cycles | no failure |
| Standalone: cooperative thread pool saturated, 12 creations | 0 failed |

**I diagnosed this wrongly the first time and shipped code on the strength of it.** The initial
reading was a transient MIDIServer refusal under machine saturation, and `MIDISource.init` gained
a four-attempt retry. It was recorded as unconfirmed at the time, and then disconfirmed: the same
four failures reproduced with the retry in place on a machine at load 1.24. The retry has been
removed rather than kept with a corrected comment, because code defending against a condition
that does not exist is cargo, and the disproven story would have outlived the memory of it.

The cause is 86 suites executing concurrently in one process. It is not machine load, not a
client or endpoint limit, not a leak on the disposal path, and not cooperative-pool starvation:
each of those was tested standalone and rejected. Nothing in `MIDISource` can change it, and the
feature is verified working system-wide from a separate process.

So the suite is `.enabled(if:)` on `PHONEFOLD_COREMIDI_TESTS`, which `verify_phase.sh 5` sets for
its own invocation. Skipped rather than deleted or quietly passed: a skipped test prints its
reason, and the gate still runs them for real.

## Phase 5a machine gate: GREEN (2026-08-31)

```
PASS  no #if os / canImport in FoldCore, FoldEngine, FoldGeometry
PASS  no human-verifiable criterion ticked by an agent
PASS  swift build (macOS)
PASS  swift test (macOS)                     535 tests, 86 suites, 705 s parallel
PASS  PhoneFold Studio builds for macOS
PASS  batch mode: 5 records folded headlessly, 5 mmCIF written
PASS  the CoreMIDI virtual source emits valid events to a loopback client
```

Parallel is 2.4x faster than serial: 705 s against 1714 s. That is why the CoreMIDI suite was
isolated into its own invocation rather than the whole suite being run with `--no-parallel`,
which would have cost seventeen minutes on every gate to work around five tests.

## Phase 5c: the machine gate's three items (2026-08-31)

| PLAN's wording | Result |
|---|---|
| "builds for visionOS" | yes, and the other four surfaces still build |
| "renderer runs in the Simulator from the sample provider" | yes - trp-cage drawing in a volume in the simulated room, screenshot taken |
| "immersive space lifecycle unit-tested" | 5 tests in `ImmersiveSessionTests`, and the app is driven by that state machine rather than a boolean |

**Four platform assumptions that only visionOS refuted**, each of which built fine everywhere
else:

- `WCSessionDelegate` requires `sessionDidBecomeInactive` and `sessionDidDeactivate` on visionOS
  as well as iOS. The guard said `os(iOS)`, and the conformance failed with a message naming
  neither member.
- `WidgetCenter` exists on visionOS only from 26.0, against this package's 2.0 floor. Availability
  -checked rather than raising the whole package for one optional refresh on a platform with no
  complication.
- **ProRes is `API_UNAVAILABLE(visionos)`.** The cases are absent there rather than falling back
  to H.264: a codec that quietly wrote H.264 when asked for ProRes would produce a file named
  `.mov` that reports success and is not a master.
- **RealityKit on visionOS has no `CustomMaterial`** and permits no custom Metal surface shaders.
  The stage's shader was already an opt-in path behind `PHONEFOLD_CUSTOM_SHADER`, so visionOS
  takes the default every other platform takes.

## P5c-04, the hand: a fifth thing only visionOS refutes (2026-08-31)

**A SwiftUI gesture attached to a `RealityView` receives nothing on visionOS unless the pinch
ray hits an entity carrying `InputTargetComponent` *and* a `CollisionComponent`.** The phone's
`DragGesture` and `MagnifyGesture` in `FoldCanvas` had been compiled into the visionOS target
since P5c-01 and looked like the feature being complete already. They were not a coarser
version of the gesture: with no collision geometry in the scene they were **no gesture at
all**, and the protein could not be turned by hand. Nothing about that is visible from a
build, a screenshot, or the code reading correctly on four other platforms - all five compile
the identical two gestures.

The fix is `targetedToAnyEntity()` plus a box the stage keeps in step with the mesh. Two
things about the box that are not obvious and are now tested (`InputTargetShapeTests`, 8
tests):

| | |
|---|---|
| Rebuilt when the protein changes by more than 5% of its own diagonal | A fold changes shape 60 times a second; rebuilding a `ShapeResource` per frame allocates constantly for a box that is nearly always the same box |
| Measured against the box's diagonal, not in angstroms | An absolute threshold is a different threshold for a 20-residue peptide and a 300-residue domain |
| A suppressed rebuild leaves the *stored* extent alone | Otherwise the box creeps with each ignored frame and ends up describing nothing |
| A degenerate bounds is padded to 0.5 A, never used as-is | A zero-size box hit-tests against nothing. A first frame with one residue, or every CA on one line, produces exactly that - and the symptom is identical to a gesture that was never wired up |
| Built in the protein's own space | The entity transform already carries the framing scale; a box in stage units is scaled twice and the hand grabs a region a fraction of the protein's size |

**Measured:** all five surfaces build with the change; the visionOS app launches and draws in
the simulator; 40 tests across the four FoldSync and FoldRender suites pass.

**Not measured, and it cannot be from here:** that visionOS actually *delivers* a targeted
pinch-drag to the entity. `simctl` has no input injection, and `Simulator.app` opened against
a `simctl`-booted visionOS device reported zero windows and then timed out on an Apple Event,
so there was no surface to synthesise a drag against either. In `BLOCKERS.md` with the other
headset items.

## P5b-03, the half that was never built (2026-08-31)

`PhoneFoldModel` carried `watchLink`, `watchTransport` and `lastPublishedToWatch`, with a
careful comment above them about `canImport(WatchConnectivity)` against `os(iOS)` - and **not
one of the three was ever assigned**. `init()` called `observeForActivity()` and nothing else.
`grep -rn watchLink Apps/` returns the declaration and no other line.

What that means in practice, which is worth writing down because none of it shows in a build:

| | |
|---|---|
| The phone never activated a `WCSession` | so the Watch's own session had no counterpart and `isReachable` was false for ever |
| No state was ever published | so the wrist's Now Playing screen had nothing to show, and `FoldComplicationStore` had nothing to save - the complication's data only ever arrives from the phone |
| No command was ever handled | so every button on the wrist sent into a session with no host |
| `requestedGalleryID` was consumed by `StageView` and set by nobody | the one line of evidence that would have shown it: a `@Published` property with a reader and no writer |

All ten of the 5b handshake tests passed throughout, because they test `RemoteLink` against a
mock transport - correctly, that is what PLAN's gate asks for - and `RemoteLink` was never the
part that was missing. The gap was one construction site in the app, below the level any of the
package's tests can see.

Now built: `connectWatch()` on the main actor, commands routed to the player, and state
published through `State.isWorthSending(after:)` rather than on a timer - a fold publishes sixty
states a second and the wrist can use about one, but a **style change has to go immediately**
and its progress has not moved at all, so the filter compares everything but progress exactly
and progress at one per cent.

**A scrub is ended by a timeout on the phone, not by a message from the wrist.** `sendMessage`
is dropped outright when the other device is unreachable, so an "I have stopped turning the
Crown" message can be lost - and a Watch that goes out of range mid-scrub would leave the phone
holding one frozen frame with no way back short of relaunching. A timeout cannot be lost. Same
argument as `StageCamera.inputTimeout`, which closes an abandoned drag on its own clock rather
than trusting `onEnded`.

## P5b-04, the wrist haptics (2026-08-31)

PLAN: "Wrist haptics of the fold, the phone keeping the audio."

**The moments cannot travel in the state.** State goes by `updateApplicationContext`, which the
system coalesces so only the newest survives - a hundred contacts forming would arrive as one
state saying "some contacts have formed by now". A moment that is coalesced has not been
delayed, it has been deleted. So cues are messages, and `FoldRemote.Cue` is a third payload kind
crossing the same two delegate callbacks as commands and states. Each decoder refuses the other
two rather than guessing, and that is tested in both directions.

**And the rate limit is on the phone.** `WKInterfaceDevice.play` queues rather than drops, so an
unfiltered stream of contacts arrives as one continuous buzz that outlasts the fold. Filtering
on the Watch would still have paid for every message.

`WristHaptics` (9 tests) decides. Two rules in it are not obvious and both fail silently:

- **A suppressed burst does not move the clock.** If it did, a fold forming contacts
  continuously would push the window forward on every rejected reading and buzz exactly once,
  which looks identical to the feature being switched off. Measured in the test: a full second
  of contacts at a 0.35 s floor gives three buzzes, not one.
- **Arrival is never rate limited.** The heaviest burst in a fold is the one immediately before
  it arrives, so the window is almost always still open at the end - rate limiting the arrival
  would swallow precisely the cue the feature exists for, and only on the folds that end most
  emphatically.

**The counts come from `history.latest`, never `history.samples.last`.** The retained series is
decimated as a fold lengthens - the stride doubles each time the buffer fills - so a count taken
from it would represent fewer and fewer frames as the fold went on, and the burst threshold
would be measuring something different at the end than at the start. `latest` is the newest
frame whether or not the decimation gate kept it.

**Measured:** 40 tests across FoldSync and FoldRender pass; all five surfaces build.
**Not measured:** anything a wrist can feel. In `BLOCKERS.md`.

## An undeclared dependency that only fails when the machine is busy (2026-08-31)

`FoldCapture` has imported `FoldEngine` since batch mode landed, and `Package.swift` never
declared it. That is not a latent error waiting to be found - it is a **race**, and it had
already passed and failed on the same tree the same day:

| Run | Load average | Result |
|---|---|---|
| Phase 5 gate, earlier | ~2 | PASS - visionOS Release built |
| `xcodebuild` Debug, by hand | ~11 | PASS |
| Phase 5 gate, re-run | 143 | FAIL - `unable to resolve module dependency: 'FoldEngine'` |

Every build that also builds `FoldEngine` leaves its `.swiftmodule` in the same products
directory, so `FoldCapture` resolves the import by accident whenever the scheduler happens to
compile `FoldEngine` first. Under load the ordering changes and the accident stops happening.

**The lesson is about the gate rather than about the dependency.** A check that passes on a
quiet machine and fails on a busy one is not noise to be re-run until it agrees: the two runs
were both telling the truth about different orderings of the same undeclared edge. Declaring it
makes both orderings correct.

## P5b-07, the Live Activity on the wrist (2026-08-31)

PLAN: "Live Activity mirrored on the wrist."

**Half of this was already free, and that is what makes the other half easy to miss.** watchOS
puts a running Live Activity into the Smart Stack whether or not the app says anything: with no
declaration the feature *appears* to work, showing the iPhone Lock Screen banner squeezed onto a
watch face. `supplementalActivityFamilies([.small])` is what buys a layout designed for a wrist,
and `@Environment(\.activityFamily)` is what lets the banner tell which one it is being asked
for.

Three details that are not guesses:

- `ActivityFamily` is `@available(iOS 18.0, *)` and **unavailable on watchOS, visionOS and
  macOS** - it is declared by the *iPhone's* widget extension, which is the only target that has
  it, and the deployment target here is already 18.0.
- `activityFamily` arrives in the environment, so the banner had to become a `View` rather than
  stay a `@ViewBuilder` method on the `WidgetConfiguration`, which has no environment to read.
  `detail` and `tint` became statics because the Dynamic Island closure still needs them.
- `.medium` is deliberately not listed. It is the iPhone banner and is what the unannotated body
  already is; naming it would claim two designs where there is one.

The wrist card carries the protein and the progress and nothing else. The Lock Screen gets a
metre of distance and a glance of a second or two; a Smart Stack card is read at arm's length in
less, often while the arm is still moving - and the confidence already has a place on the wrist,
in the complication, which is a different question asked at a different time.

**Measured:** builds. **Not measured:** what it looks like on a wrist. In `BLOCKERS.md`.

## P5b-06, the Fold of the Day, and the version that had to be thrown away (2026-08-31)

PLAN: "Standalone Fold of the Day: one precomputed short trajectory per day, playable on the
Watch alone as a small animation with haptics. No inference, no phone required."

### The first bake looked right and showed nothing

The obvious source is the twelve bundled `.pftraj` trajectories, and the first generator used
them. Everything about it worked: it read the files, projected them, quantised them, counted
contacts and wrote an 86 kB resource. The check that killed it was one line - compare the first
frame with the last, which is what the animation is *about*:

| fold | span, frame 1 → last | contacts on frame 1 / total |
|---|---|---|
| protein G B1 | 947 → 946 (×1.00) | 137 / 210 (65%) |
| ubiquitin | 962 → 1000 (×1.04) | 160 / 232 (69%) |
| WW domain | 944 → 920 (×0.97) | 58 / 107 (54%) |

Those are ESMFold trunk readouts: the trunk is already close to its answer by the first captured
block, so as an animation this is a folded protein twitching, preceded by one enormous haptic
burst and followed by almost nothing. **Nothing in the pipeline was wrong.** The generator, the
projection, the quantisation and the contact counter were all correct, and the output was
useless, which is why it survived every intermediate check and died on the first end-to-end one.

### The second bake, from the engine the app ships

The structure-based (Gō) model, started from a self-avoiding random coil - the same engine that
was ported to Swift in P0-33 and agrees with this C to better than 1e-9 in forces. Cooling from
kT 1.0 to 0.6 rather than running longer, per P0-39.

| fold | residues | steps | wall | Q final | RMSD to native | Rg start → end |
|---|---|---|---|---|---|---|
| trp-cage TC5b | 20 | 2.0 M | 9.0 s | 0.973 | 0.68 Å | 9.5 → 6.9 Å |
| WW domain | 34 | 3.4 M | 30.7 s | 0.986 | 0.93 Å | 12.8 → 9.3 Å |
| villin HP36 | 36 | 3.6 M | 33.6 s | 0.957 | 2.06 Å | 13.9 → 9.8 Å |
| protein G B1 | 56 | 5.6 M | 76.7 s | 1.000 | 0.79 Å | 22.0 → 10.4 Å |
| alpha-3D | 73 | 7.3 M | 134.5 s | 0.952 | 3.62 Å | 21.4 → 14.0 Å |
| ubiquitin | 76 | 7.6 M | 152.0 s | 0.984 | 1.03 Å | 21.3 → 11.5 Å |

And the same end-to-end check the first version failed:

| fold | span, frame 1 → last | contacts on frame 1 / total |
|---|---|---|
| trp-cage | 561 → 260 (×0.46) | 19 / 553 (3%) |
| protein G B1 | 736 → 211 (×0.29) | 55 / 1201 (5%) |
| ubiquitin | 906 → 256 (×0.28) | 107 / 1889 (6%) |

The structure ends at 28-46% of the width it started at, and 94-97% of the contacts form after
the first frame. That is a fold you can watch.

228 kB for six folds, 90 frames each, interpolated to sixty a second on the wrist. Three
decisions in the bake that are not free:

- **One scale for the whole trajectory, from the widest frame.** Normalising each frame to fit
  would draw the coil and the folded core at the same size, which deletes the only thing the
  animation is about - and it is the kind of mistake that makes the output look *better*.
- **A fixed projection plane, from the folded structure's two principal axes.** Projected down
  the long axis of a helical bundle a fold is a blob in which nothing happens.
- **Contacts counted with the tracker's own hysteresis** (8.0 Å in, 8.5 Å out, separation 3), so
  the wrist's haptics during a daily fold land where the phone's do during a real one.

### The wrist's canvas, measured rather than reasoned about (2026-08-31)

The first working version drew the protein at about a quarter of the size it should have been.
Three rounds of guessing went nowhere, and the second round produced a **pixel-identical
screenshot** after a real layout change - which is the tell that the change was not on the path
that was broken.

`simctl` cannot touch a watch app and `--console` returns nothing for it, exactly as it returns
nothing for the phone. So the number went on the glass, in the Canvas itself, and the answer was
one screenshot away:

    204x63  n36  w0.85

The canvas was **63 pt tall**. `draw` scales by `min(width, height)`, so a 204-wide canvas was
being scaled as if it were 63 wide. The data had been right the whole time - `w0.85` is the coil
reaching 85% of the quantised box on frame 1, which is exactly what the bake wrote. The title,
the subtitle and a `.bordered` button had taken three quarters of a 46 mm screen between them,
and nothing in the layout looked unusual.

Fixed by giving the fold the screen and putting the caption over it. Two consequences worth
keeping:

- **`.aspectRatio(1, contentMode: .fit)` was buying nothing** and hiding the problem. `draw`
  already letterboxes itself by taking `min(width, height)`.
- **The projection is translated per frame and scaled once**, and both halves of that took a
  wrong turn first. Centring every frame on the *folded* structure's centroid - the obvious
  choice - put the coil off to one side, because a coil's centre of mass is nowhere near the
  core it collapses into, and the animation drifted into frame as it went. Centring instead on
  the whole trajectory's bounding box fixed the coil and broke the ending: the folded structure
  sat in a corner, and `max|coordinate|` stopped meaning "how big is this" - which silently
  disabled the one test that catches a trajectory that does not fold, and the test went from
  passing to failing for a reason that had nothing to do with folding. What a viewer actually
  does is keep the object in the middle and let it change size, so each frame is centred on its
  own centroid and the scale is taken once from the widest frame. The scale is the part that
  must not vary: a per-frame scale draws a coil and a core the same size.

Also added: `PHONEFOLD_WATCH_SCREEN` and `PHONEFOLD_WATCH_AUTOPLAY`. watchOS has no input
injection at all, so the third page of a vertical `TabView` is unreachable from a script - and
without a way to reach it the Fold of the Day could have been built, bundled and shipped
without anything outside a wrist ever seeing it draw.

## P5c-05, spatial audio placed where the residues are (2026-08-31)

PLAN: "Spatial audio finally does what the Phase 3 design always intended: notes arrive from
where their residues actually are."

**Phase 3 had already done most of it**, and the temptation was to tick this off. Each note is
already placed at its residue's live coordinate through `AVAudioEnvironmentNode` with HRTF, at
20 angstroms to the metre, with the listener at the origin so the protein wraps around them.
Two things were genuinely missing, and neither is audible as a fault - both just make the sound
subtly disagree with the picture:

- **The stage turns and the sound did not.** `FoldCanvas` rotates the protein entity; the audio
  used raw coordinates. A residue visibly on your left arrived from wherever it happened to
  start. On a phone that is a curiosity; on a headset, where the picture and the listener share
  a space, it is the whole illusion coming apart.
- **A volume is somewhere.** The Phase 3 placement puts the listener *inside* the protein, which
  is right for the concert hall and wrong for an object on a desk: audio from inside your own
  skull for something you are looking at over there is hard to name and impossible to ignore.

`SpatialStage` is the placement as a value type, with 8 tests, and the first of them is the one
that matters: **the default is bit-for-bit the Phase 3 placement**. Nothing on this machine can
hear any of this, so the surfaces where the sound was already right were left alone and visionOS
is the only one that sets anything.

| | |
|---|---|
| Concert hall | `aroundTheListener`, 20 Å/m, now carrying the stage's live rotation |
| Volume | `inAVolume(distance: 1.0, span: 0.6)`, scaled from the protein's own extent |
| Everywhere else | unchanged: origin, 20 Å/m, identity rotation |

The volume scale is derived from the protein rather than fixed, so a 20-residue peptide and a
300-residue domain both fill the volume - which is what the stage already does to the picture,
and the sound has to agree with the picture or the two are describing different objects.

**The one guess:** how far in front the volume sits. A volume is placed by the person wearing
the headset and the app is not told where it ended up, so 1.0 m is arm's length and nothing
more. In `BLOCKERS.md`.

## P5c-07, walking into the core, and two things only the headset simulator showed (2026-08-31)

PLAN: "Scale the protein up until you are standing inside it as the hydrophobic core packs
around you. Absurd, memorable, and **scientifically legible**."

### How big does it have to be? Measured, not chosen

"Legible" is the word that turns this from taste into arithmetic. Two fractions, measured on
the ten bundled structures of fifty residues or more, final frame, alpha carbons:

| | median | mean | range |
|---|---|---|---|
| How far the hydrophobic core reaches, as a fraction of the structure's own radius | **0.40** | 0.41 | 0.0 - 0.6 |
| The furthest alpha carbon from the centroid, as a fraction of the bounding-box diagonal | **0.42** | 0.43 | 0.37 - 0.51 |

The core fraction comes from binning residues by distance from the centroid and taking the mean
Kyte-Doolittle hydropathy per bin. The profile is unambiguous - lysozyme runs +3.8, +1.4, +0.3,
+0.4, +0.1, then negative to the surface; myoglobin +3.3, +2.0, +0.7, +0.6, then negative - and
the crossing is where the core ends. The 0.0 is **proinsulin**, which is a disulphide-linked
precursor rather than a globular domain and genuinely has no hydrophobic core in this sense: a
real answer rather than a failed measurement. The radius-to-diagonal ratio is tight at 0.37 to
0.51 because a folded protein is roughly globular whatever it is made of.

**A first version of the core statistic had to be thrown away.** It looked for where a *running*
mean of hydropathy crossed the whole-protein mean and took the last crossing, which returned
1.00 for eight of thirteen structures - a running mean converges on the overall mean by
construction, so the last crossing is always at the end. A statistic reading exactly 1.00 for
most of its inputs is an artefact, not a finding.

From those two numbers and a stated half-metre of personal space, the scale at which the core
has closed around a person falls out at **x2.6**, about three metres of protein. Nothing about
it is chosen. At the stage's ordinary framing the structure's radius is already 0.48 m - so in
an immersive space you are at its surface before anything is scaled - but its core is 0.19 m
across, a grapefruit at arm's length.

### Two platform facts the simulator gave up only when asked properly

- **An `ImmersiveSpace`'s origin is the floor at the wearer's feet.** A window or a volume gives
  RealityKit content a bounded box with the origin in the middle; an immersive space does not.
  The first run opened the space, the button correctly changed to "Leave the concert hall", and
  the room was **empty** - the protein was sunk into the carpet, out of view unless you looked
  down. Nothing errors, nothing logs.
- **An ornament in an `ImmersiveSpace` does not appear**, because an ornament hangs off a window
  and an immersive space has none. PLAN asks for "ornament-based transport rather than an
  overlay, so the stage stays clean", which is right for the volume and impossible in the room.
  It compiled, it ran, and the control was simply not there. The walk control moved to the
  control window, which stays open in the shared space beside it.

Also: `SimpleMaterial.faceCulling = .none`, or from inside the structure the near wall of every
far tube is culled and you look straight through the protein you are standing in. It costs
nothing from outside - the tube is a closed surface, so no back face is ever visible there.

**Measured:** all five surfaces build; the concert hall renders in the simulator at both scales
(screenshots taken); 5 `RoomScaleTests` plus the full package suite.
**Not measured:** whether three metres of protein around your head is wonderful or unpleasant,
and whether half a metre of personal space is the right number. Both are in `BLOCKERS.md`.

## P5c-06, look-and-pinch a residue (2026-08-31)

PLAN: "look-and-pinch on a residue to pin a label and solo its note."

**One collision box, not one per residue.** The obvious reading is an input target per residue,
which for a 300-residue protein is 300 entities with 300 collision shapes rebuilt as the fold
changes shape sixty times a second. The pinch already arrives with a point in space; turning
that into a residue is a search over a few hundred coordinates. So `ResiduePicking` is a pure
function in `FoldGeometry` with 6 tests, and three of its rules are not free:

- **A miss returns nil, never the least-far residue.** A protein is mostly empty space at this
  scale and a pinch into a hollow is a pinch at nothing; answering it with whatever happens to
  be nearest pins a label where the hand was not pointing.
- **The tolerance is 6 Å and has a reason.** The tube is drawn about 2 Å in radius, so a couple
  of angstroms of slack either side is generous - and it stays under the ~4.8 Å between
  neighbouring strands of a beta sheet, so a pinch aimed between two strands does not silently
  take one.
- **Ties break to the earlier residue.** A symmetric structure genuinely puts two residues
  equidistant from a pinch, and an answer that depended on iteration order would flicker.

The point is converted into the protein's space rather than the coordinates into the world: one
conversion per pinch instead of a few hundred, and the tolerance only means anything in
angstroms.

**Soloing is filtered where notes start, not by muting voices.** A muted voice is still a voice
allocated, and there are sixteen: in a busy passage a soloed residue would find them all taken
by notes nobody can hear. And **a contact counts for both of its residues** - a contact belongs
to a pair, and most of what a residue sounds like is the contacts it forms, so soloing one end
and hearing silence would be the wrong answer to the question being asked.

The label is a child of the protein, so it follows the orbit with nothing driving it, and
carries the inverse of the protein's scale so it is the same size in the room whether the
protein is 20 residues or 300 and whether or not somebody has walked into it. A label that
scaled with the protein would be a wall of text at room scale and invisible in a volume.

**Measured:** `PHONEFOLD_VISION_PIN=9` on trp-cage TC5b renders **GLY10** at the residue in the
concert hall, at a legible size, which is right: the sequence is NLYIQWLKDG..., so index 9 is
glycine 10. All five surfaces build; 23 tests across the four new suites.
**Not measured:** whether a pinch aimed by eye actually lands on the residue somebody meant,
which is the whole question and needs a headset. In `BLOCKERS.md`.

## Two more features wired on one side only (2026-08-31)

Both found while building SharePlay, both the same shape as `P5b-03`'s Watch host, and both
invisible to every test and every build.

### Handoff never advertised anything

`StageView` had `onContinueUserActivity`, `continueFold(_:)` and a `handoffPayload` computed
property. `grep -n handoffPayload Apps/PhoneFold/Sources/*.swift` returns **one line: its own
declaration.** Nothing ever called `.userActivity(...)`, so no device ever published an
activity, so no other device could ever have seen one. P5-07 was in `BLOCKERS.md` as "built;
two devices needed to confirm" - and two devices would have confirmed nothing, for a reason
that looks like a Handoff or an iCloud problem rather than a missing line.

The receiving half being complete is what made it invisible: everything about the feature reads
as finished, and the half that was missing is the half you cannot see from the device you are
holding.

### The Studio's menu bar acted on a model no window uses

`StudioCommands` bound `@ObservedObject private var player = PhoneFoldModel.shared.player`, and
**nothing in the Studio target uses `PhoneFoldModel.shared`**: every `StudioWindow` owns its own
model, deliberately, because PLAN's Phase 5a wants two proteins side by side rather than two
views of one.

So "Send MIDI to Other Apps" armed a `FoldPlayer` that was never playing anything. The virtual
CoreMIDI source appears in every DAW's device list exactly as it should - the gate's loopback
check passes, because that check drives the engine directly - and then emits nothing at all.
That is precisely the failure P5-05's human gate would have hit, and it would have looked like
a CoreMIDI problem, which is the last place anyone would find it.

Fixed with `@FocusedObject` and `.focusedSceneObject(model)`, so the menu acts on the window in
front. With no fold window the menu says so rather than offering a toggle that would arm
something invisible.

**The pattern is worth naming, because this is the third instance in one day.** A feature split
across two places, where one place is complete and reads as authoritative, and the other is a
declaration nobody assigned or a computed property nobody called. Neither a build nor a test
suite can see it: the code is correct, it is simply never reached. What finds it is asking of
each half "who calls this?" - `grep` for the symbol and count the lines.

## P5c-08, SharePlay: the teaching mode (2026-08-31)

PLAN: "two or more people in the same fold. This is the teaching mode, and the reason a
department might buy it."

**Nobody streams a trajectory.** A fold is megabytes of coordinates and none of it needs to
travel: every device already has the engines, and a fold is a deterministic function of the
protein, the engine and the seed. That is exactly what `FoldHandoff` was built to carry for
Phase 5a - "a description of what to fold, not the fold itself" - so the Phase 5a design pays
for itself a second time and there is one definition of what a fold is rather than two. The
transport messages reuse `FoldRemote.Command`, the vocabulary the Watch already speaks: a third
vocabulary for the same six verbs would be a third place to add a seventh.

`SharePlaySession` is the state machine, in `FoldSync` beside `ImmersiveSession` and for the
same reason - the system ends a session behind your back when the FaceTime call does. 7 tests.
The one that matters: **zero participants is not a session.** The count drops to nothing when
the last person leaves, and treating that as "still sharing" leaves a button offering to leave
a room that has emptied.

`canImport(GroupActivities)` rather than a platform test, and the difference is real: it does
not exist on watchOS at all, so `canImport` is false and the guard works. Contrast `ActivityKit`,
which *does* import on macOS and then marks every symbol unavailable.

**What is deliberately not synchronised: progress.** Every device computes its own fold from the
same protein, engine and seed, so they agree on *what* and not on exactly where they are in it -
two headsets fold at different speeds. Frame-locking them is a real design question about what
"together" should mean in a lecture, with several defensible answers, and it needs a headset and
Marc's judgement rather than a guess. It is in `BLOCKERS.md` as an open question, not as a bug.

**Measured:** all five surfaces build; 7 `SharePlaySessionTests`.
**Not measured:** anything at all about two devices. A custom `GroupActivity` also needs a real
FaceTime call to do anything, which no simulator provides.

## The cross-platform gate (2026-08-31)

### "All five apps build in one `xcodebuild` invocation"

Done, and the way it works is not what it looks like. The scheme names targets on four
platforms, so the obvious approach is to pass four `-destination` flags - and that fails
outright with "unable to find a destination matching the provided destination specifier".

**One destination is enough.** `-destination "generic/platform=iOS Simulator"` builds
`iphonesimulator`, `watchsimulator`, `xrsimulator` *and* `macosx` in the same pass: Xcode
resolves each target to the platform it declares rather than filtering the scheme to the
destination given. The gate asserts the four `.app` products exist afterwards, because a build
that succeeds having quietly skipped three of them is exactly the failure this check is for.

This replaces three separate per-platform builds in the gate, so it is also faster.

### "iCloud trajectory sync round-trips between two Simulators"

**Descriptions, not coordinates, and that is the third time the same argument has paid.** A
trajectory is megabytes; a fold is a deterministic function of the protein, the engine and the
seed. So what syncs is `FoldHandoff` - the payload Phase 5a defined for Handoff and Phase 5c
reuses for SharePlay - and a full forty-entry log with 60-character subjects, long
accessions, maximum seeds and a long device name encodes to **between 5 and 12 kB** against
`NSUbiquitousKeyValueStore`'s 1 MB - bounded on both sides by `FoldLogTests`, tightly, because
a generous bound would pass just as well if an entry grew tenfold and the whole argument for
syncing descriptions rests on this staying small. Syncing the coordinates
would move a hundred times the data to arrive at a fold the receiving device can compute
exactly, at *its* own residue cap rather than the sender's.

`FoldLog` is the merge, with 11 tests. Three of its rules fail silently if wrong:

- **Merge is a union, never a replacement.** Both devices can run folds while offline, so
  neither list is authoritative; writing this device's over the top is how the other device's
  afternoon disappears permanently, with nothing to notice it.
- **Unreadable remote data decodes to nil, not to an empty log.** A log that failed to decode
  and a log with nothing in it are different situations, and treating the first as the second
  is how a device with a version mismatch deletes everything the account had.
- **A fold's identity is the protein, the engine and the seed** - exactly what determines the
  trajectory - and not the progress. Otherwise watching one protein twice fills a list of forty
  with one protein.

**Two ways this feature can be inert while appearing to work**, both silent, both now surfaced
in the interface rather than assumed away: without the `ubiquity-kvstore-identifier` entitlement
`NSUbiquitousKeyValueStore` accepts a write and returns nil on the read; with the entitlement
but nobody signed into iCloud it does exactly the same. `FileManager.ubiquityIdentityToken` is
the only honest test available before anything is written, and the store now says so.

The entitlement is added to the iOS, macOS and visionOS targets. **The App ID also needs iCloud
enabled in the developer portal**, which is Marc's - see `BLOCKERS.md`.

## P4-16, the app icon (2026-08-31)

**The icon is a frame of the app doing its job**, not a drawing of one: trp-cage TC5b - the
structure the gallery opens with - rendered by the same `OffscreenStage` that makes the films,
with the same lighting rig and the app's own secondary-structure colouring. Marc's call on both
the structure and the palette. `swift run make-icon` produces it, so it is reproducible rather
than a file someone once exported.

Four things the pipeline got wrong first, three of which are silent:

- **The camera has to be applied.** `OffscreenStage` applies the transform inside `show` and
  inside `advance`, and nowhere else, so a camera changed between them is a camera nothing has
  read. Ten candidates came back identical to each other, which reads as the arguments not
  being parsed.
- **The background gradient was never visible.** The stage clears to an opaque colour and the
  render covers the canvas; every corner pixel read exactly that colour. It was removed rather
  than fixed - that colour *is* the app's stage, so an icon on a gradient would show a ground
  the app never shows.
- **Removing it took the sRGB conversion with it.** The texture is linear and the composite was
  going through an sRGB `CGContext`, which was doing the conversion incidentally. Without it the
  corner went from (13, 13, 38) to (1, 1, 5) - the same picture three stops down - and the PNG
  was tagged linear, which an asset catalogue and App Store Connect both read as too dark.
- **`CFBundleIconName` is not written when XcodeGen supplies the Info.plist.** Xcode injects it
  only under `GENERATE_INFOPLIST_FILE`. It was present on macOS and missing on iOS, watchOS and
  visionOS; the catalogue compiles, the icon appears on the home screen, and the *upload* is
  refused with "A value for the Info.plist key CFBundleIconName is missing".

### visionOS will not take a flat icon

Two requirements Xcode enforces and neither is in the interface guidance:

| | |
|---|---|
| The stack is **512 x 512**, not 1024 | a 1024 layer fails with "must exactly fill the image stack. Its current frame is {{0, 0}, {1024, 1024}} while the visionOS App Icon's size is {512, 512}" |
| **At least two layers must have content** | artwork on `Back` with empty layers in front is refused: "Although it has 3 layers, only 1 has applicable content" |

So the ground and the protein had to be separated, which needs the protein on transparency, and
`RealityRenderer` offers no alpha. **Two renders and algebra, not a colour key.** Compositing is
`C = F + (1 - a)B`, so rendering against black and against white gives `C_white - C_black =
1 - a` and alpha falls out with no threshold anywhere; the premultiplied colour is `C_black`.
Keying out the flat background is the obvious approach and it fringes, because the ribbons are
shaded and their dark faces sit near the background colour. Measured: corner alpha 0, protein
alpha 255, full range in between. `OffscreenStage` gained a background parameter for this and
nothing else.

## P5-02, the Genie 2 length buckets (2026-08-31)

PLAN 5a asks for a "higher residue cap (~640) using the unpalettised fp16 model variant from
Phase 0". That variant belongs to the **ESMFold** exports, which are dropped, and 640 was
ESMFold's length bucket rather than a property of anything that shipped. The real cap is Genie
2's, and it was 64 because there was one exported model. A model *is* a length: the export
bakes Genie 2's static features in as constants, so there is no padding or masking at run time.

| bucket | size | conversion | Core ML vs eager |
|---|---|---|---|
| 64 | 33.8 MB | (2026-08-28) | — |
| 128 | 37.3 MB | 908.9 s | passed the check |
| 256 | 51.0 MB | 938.7 s | **3.41% relative RMS**, max abs 8.96e-02 |

The size scales gently rather than with N², which is what makes bundling three of them
reasonable at all - the parameters are the same 15.73 M and only the baked features grow.

**The exporter was verifying everything except the artefact it ships.** It checked the six op
rewrites against the unpatched model and the trace against eager - exactly `0.000e+00` on an
unseen input - and then saved the converted model without ever comparing it. fp16 casting and
ninety-five MIL optimisation passes all happen *after* the trace, and they are the part most
likely to change an answer. It now predicts on the reference inputs before saving and refuses
above 10% relative RMS. 3.41% is the fp16 cast, and it sits alongside the 7.5 to 9.2% the
quaternion-sign rewrite already costs, which the network was shown to be robust to.

**Lengths are offered, not rounded.** Genie 2 is unconditional - there is no target sequence -
so the length is not a detail of the request, it *is* the request: serving 128 to somebody who
asked for 100 generates a different protein and calls it theirs. `Genie2Sampler.bundledLengths`
probes the bundle rather than declaring a list, so the phone offers one length because it
carries one model and the Studio offers three because it carries three, and nothing has to know
which app it is compiled into. The picker appears only when there is a choice.

## App Store screenshots: two identical failures, and the second was the tell (2026-09-01)

Every one of the first ten captures - five at a 26-second settle, five at 115 - showed the app
with an **empty stage** and "Folding on this device". The launch environment plainly worked: the
colour pills, the style and the highlighted gallery entry all differed correctly between shots.
Only the protein was missing.

Extending the settle by a factor of four and getting a visually identical failure is the tell,
and it is the same one the Watch canvas gave earlier: **the change was not on the broken path**.

**The captures were of a Debug build.** A debug Swift build is about 36x slower for
compute-heavy code, and a fold is 2,000,000 integration steps of nothing but arithmetic, so
trp-cage - which folds in 9 seconds - does not finish inside any settle worth having. Nothing
errors; the app is simply still working.

Rebuilt Release, measured on the same device and protein:

| settle | stage mean luminance | bright pixels on the stage |
|---|---|---|
| 15 s | 29.8 | 111,404 |
| 35 s | 33.6 | 164,157 |
| 70 s | 31.2 | 136,421 |

Against an empty stage, which is flat. The fold arrives well inside 35 seconds and the count
falls afterwards because the protein has packed. 70 seconds is the settle, and the capture
script now says why it must be Release.

The resulting screenshot is the app doing the thing it is for: trp-cage folded, native contacts
100%, radius of gyration 7.0 Å, and the disclosure line - "Simulated on device toward a known
structure, not a prediction" - in the frame rather than buried in a settings screen.

## Signing: two capabilities that are enabled and carry nothing (2026-09-01)

The first archive attempt failed on iCloud rather than on the App Group, and the error names
the symptom rather than the cause:

```
error: Provisioning profile "PhoneFold App Store" doesn't include the iCloud capability.
error: Provisioning profile "PhoneFold App Store" doesn't include the
       com.apple.developer.ubiquity-kvstore-identifier entitlement.
```

`asc_api.py capabilities` had already reported `present ICLOUD on com.mdeller.phonefold`, and
the profiles were regenerated *after* it - which is the ordering the reference is emphatic
about, because profiles are immutable snapshots. So the obvious reading is that the refresh did
not take.

**It took. The capability is genuinely enabled and genuinely carries nothing.** Decoding the
installed profile - which the reference insists is the only ground truth - the entitlements are:

```
application-identifier, beta-reports-active, com.apple.developer.team-identifier,
get-task-allow, keychain-access-groups
```

Five defaults and no iCloud. This is the App Groups pattern exactly: `APP_GROUPS` reads
enabled whether or not a *group* is attached, and `ICLOUD` reads enabled whether or not a
*container* is attached. Both need a second resource that the App Store Connect API cannot
create, and in both cases the capability's own metadata will tell you it is fine.

**So it is two portal steps, not one**, and the second was invisible until an archive was
actually attempted - which is the argument for attempting one before it is needed rather than
as the last step before shipping.

| needed | why | API? |
|---|---|---|
| App Group `group.com.mdeller.phonefold` assigned to the two watch identifiers | the complication reads what the phone wrote | no `/appGroups` resource |
| iCloud container `iCloud.com.mdeller.phonefold` assigned to `com.mdeller.phonefold` | the synced list of folds | no container resource |

Also worth knowing: `install-profiles` writes by UUID, so regenerating leaves the *old* file on
disk under its own name. There are now two files called "PhoneFold App Store". Xcode resolves
`PROVISIONING_PROFILE_SPECIFIER` by name and will pick one of them.
