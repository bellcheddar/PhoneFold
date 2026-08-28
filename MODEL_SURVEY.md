# PhoneFold — diffusion model survey

**Question:** which generative model gives PhoneFold a folding trajectory that is worth
watching, is small enough to run on an iPhone, and can be exported to Core ML?

Opened 2026-08-28 after the ESMFold finding in BLOCKERS.md: ESMFold produces no watchable
trajectory, because the protein is already folded by the time any coordinate exists.

## The constraint that eliminates most candidates

There are two different problems, and most protein diffusion models solve the wrong one for
this app:

- **De novo generation.** Sample a *novel* backbone from noise. The trajectory is beautiful
  and the model is usually small. But you cannot ask it for ubiquitin: it has no sequence
  input. PhoneFold's premise is "type an accession, watch *that* protein fold", and the
  sample gallery is twelve *named* proteins.
- **Sequence-conditioned structure generation.** Given a sequence, sample structures for it.
  This is what PhoneFold needs.

A de novo model could power a "generate a protein" mode, but it cannot be the main engine
without changing what the app is.

## Candidates

| Model | Sequence-conditioned | Framework | MSA needed | Steps | Licence | Verdict |
|---|---|---|---|---|---|---|
| **ESMFlow-PDB** | **yes** | PyTorch | **no** | 10, configurable | MIT | **leading, needs a port** |
| PathDiffusion | yes | PyTorch | **yes** | not stated | MIT | on-point but heavy |
| EigenFold | yes | PyTorch | no (needs OmegaFold) | ~100 | MIT | second choice |
| SALAD | no | **JAX** | no | 500 | Apache-2.0 / CC-BY-4.0 | rejected |
| foldingDiff | no | PyTorch | no | 1000 | MIT | tested: 0/14 designable, superseded |
| **Genie 2** | no | PyTorch | no | 1000 | Apache-2.0 | **TESTED: 8/8 designable — adopt** |
| Boltz-2 | yes | PyTorch | yes (has single-seq mode) | 20-200 | MIT | too large for ANE |

### ESMFlow-PDB — the leading candidate

Jing, Berger & Jaakkola, ICML 2024 (arXiv 2402.04845), MIT licence.

ESMFold fine-tuned under flow matching, so it is **sequence-conditioned and needs no MSA**.
Inference default is `--tmax 1.0 --steps 10`, configurable. Each step is a full trunk pass
that emits a complete structure, so every frame on the path is a real protein rather than a
mid-trunk artefact. The path starts from a prior sample, so the first frame genuinely is an
unfolded chain that collapses.

Why it fits this project specifically:

1. **It reuses the Phase 0 work.** Same ESMFold architecture, same ESM-2 650M language model
   run once up front, same trunk iterated. The split PLAN.md Phase 0 already specifies
   (expensive LM once, cheap module repeatedly) maps onto it unchanged, and the working
   trunk-patching harness in `Tools/make_sample_trajectories.py` transfers.
2. **The checkpoint is 2.58 GiB**, the folding trunk only, against ESMFold's own 8.4 GiB
   fp32. A distilled variant of the same size is published for faster sampling.
3. **10 steps is a trajectory, not a refinement.** Contrast the 0.8 A of total motion
   measured for ESMFold in BLOCKERS.md.

Known cost: ten trunk passes instead of one. Ubiquitin took 7.6 s for a single ESMFold pass
on this Mac's CPU, so roughly 80 s for a 10-step path. Whether that is viable on the ANE is
exactly what P0-10 has to measure, and it may push live folding into Cinema Mode.

### PathDiffusion — the most scientifically on-point, and the heaviest

Zhao et al., bioRxiv January 2026, MIT licence, from the Yang lab at Shandong University.
`github.com/YangLab-SDU/PathDiffusion`.

This is the only candidate that explicitly models the **folding pathway** rather than an
equilibrium ensemble, and it reconstructs the order of folding events against a benchmark of
52 proteins with experimentally validated pathways. It ships a sequence-conditional model
for structured regions and a second model for unstructured regions, which would handle the
intrinsically disordered case the app wants to showcase.

The blocker is the input pipeline: MSA generation, then MSTA construction and derivation of
the position-specific noise schedule, then ESM representations, and only then sampling. An
MSA search against UniRef-scale databases cannot happen on an iPhone.

That does not rule it out. It splits the app:

- **Bundled gallery:** precompute the twelve pathways offline and ship them as `.pftraj`.
  This works today and would be the most scientifically defensible trajectory in the app.
- **Arbitrary user sequences:** needs either a server or a different on-device model.

### EigenFold — the fallback

Jing et al., ICLR 2023 workshop, MIT licence. Sequence to structure by harmonic diffusion,
around 100 steps, median TM-score 0.84 on CAMEO. Architecturally attractive: an SE(3)
equivariant GNN denoiser, which is far smaller than a folding trunk. But it consumes
**OmegaFold** embeddings, so the one-shot half of the pipeline becomes OmegaFold rather than
ESM-2, and the repository pins torch 1.11.

### Rejected, with reasons

- **SALAD** (Jendrusch & Korbel, Nat Mach Intell 2025). Genuinely excellent and fast, with
  sub-quadratic sparse attention scaling to 1,000 residues. Two disqualifiers: it is **JAX**,
  so there is no Core ML path without reimplementing it, and it is a de novo generator that
  cannot be conditioned on an arbitrary input sequence to predict that protein's structure.
- **foldingDiff** (Microsoft, Nat Commun 2024). **Tested, and it produces by far the best
  trajectory of anything measured** (numbers in METRICS.md): 15.29 A of motion against
  ESMFold's 0.87 A, a radius of gyration sweeping 5.7 to 20.8 A, and CA-CA staying between
  2.3 and 3.8 A the whole way so a backbone tube can be swept through every frame. It
  converges to 3.823 +- 0.007 A, tighter geometry than ESMFold's own readouts. It is also
  **14.5 M parameters in a 57.9 MB checkpoint**, which is roughly 1/50th of ESMFold and
  would fit the ANE without palettisation.

  It solves the wrong problem. It is unconditional, so it generates a *novel* backbone and
  has no sequence input: it cannot fold ubiquitin, cannot do the mutation duet, and cannot
  drive a gallery of twelve named proteins. The published weights also cap at 128 residues.
  Excellent for a "generate a protein" mode; not an engine for PhoneFold as specified.
- **Boltz-2.** Sequence-conditioned with a real denoising trajectory and already familiar
  from BoltzMaker, but far too large for the ANE and MSA-dependent for best accuracy.

## Test plan

1. **ESMFlow-PDB base and distilled.** Download both (2.58 GiB each, in progress), run
   against the same twelve sequences, and capture every intermediate step as `.pftraj`.
   Measure with `Tools/trajectory_report.py` on the criteria that decided against ESMFold:
   max RMSD across the trajectory, fraction of frames with valid CA-CA geometry, radius of
   gyration range, and final accuracy against the experimental reference.
2. **Compare like for like.** The same table as BLOCKERS.md, so the two models are judged on
   identical measurements rather than on impressions.
3. **Only then** decide whether PathDiffusion's precomputed-gallery route is worth the MSA
   pipeline.

The bar to beat, from BLOCKERS.md: ESMFold moves 0.76 to 1.52 A across a whole trajectory on
confident targets. A model worth switching to should show a collapse, not a twitch.


---

## Genie 2 — tested after foldingDiff's backbones proved mostly extended

Lin, Yang, Zhang & AlQuraishi, arXiv 2405.15489, **Apache-2.0**, `aqlaboratory/genie2`.

SE(3)-equivariant diffusion over residue frames. Like foldingDiff it is **unconditional and
sequence-agnostic**, so it shares foldingDiff's fundamental limitation: it cannot fold a
named protein. It is being tested because the question after foldingDiff is narrower, namely
whether a small unconditional generator can produce *compact, designable* backbones at all.

| Property | Genie 2 | foldingDiff |
|---|---|---|
| Parameters | **15.73 M** | 14.5 M |
| Weights on disk | ~63 MB fp32 (181 MB checkpoint carries optimiser state) | 57.9 MB |
| Licence | Apache-2.0 | MIT |
| Framework | PyTorch, no CUDA-only kernels | PyTorch |
| Denoising steps | 1000 DDPM | 1000 |
| Maximum length | 256 | 128 |
| Output | **CA trace only** | N, CA, C (O constructed) |
| Seconds/sample, 76 aa, M1 Max CPU | **134 s** | 18 s |

Two practical consequences of the differences.

**It emits a CA trace, not a backbone.** That is not fatal: PhoneFold's renderer sweeps a
tube through CA positions anyway, and the P-SEA secondary-structure assignment PLAN.md
specifies is CA-only by design, precisely so it works when only CA is trustworthy. But
`.pftraj` stores four atoms per residue, so either the format grows a CA-only mode or N, C
and O are built by idealised geometry. ProteinMPNN ships CA-only weights, so inverse folding
is unaffected.

**It is seven times slower per sample.** 134 s against 18 s on the same CPU for the same
1000 steps, because each step runs a much heavier SE(3)-equivariant network. That is the
figure to watch for live on-device generation, and it is the one thing that might rule
Genie 2 out where foldingDiff was comfortable.

First sample measured before the full run: **Rg 10.44 A at 76 residues against a compact
expectation of 11.4, a ratio of 0.92**, with CA-CA at 3.863 +- 0.010 A. For comparison
foldingDiff's median ratio was 1.55 and its best was 1.12. One sample is not a result, but
it is the right sign.


### Result

**Genie 2 wins decisively and should be the live engine.** 8/8 compact and 8/8 designable
against foldingDiff's 2/14 and 0/14, median scTM 0.939 against 0.118, and 49% charged
residues against 13% — which is what the Phase 3 score actually consumes. Full table in
METRICS.md.

It costs 142 s per sample on CPU against foldingDiff's 18 s. That is the only open question,
and it is a Core ML question rather than a modelling one: 15.73 M parameters is small enough
that the ANE should close much of the gap.
