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
