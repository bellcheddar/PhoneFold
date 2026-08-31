# Third-party software, models and data

PhoneFold's own code is MIT (see `LICENSE`). It does not stand on its own: it converts
somebody else's model, trains on somebody else's labels, and fetches somebody else's
structures. Everything it leans on is listed here with its licence, what PhoneFold uses it for,
and — where it matters — what PhoneFold changed.

Licences were read from each project's own repository on 2026-08-31 rather than recalled.

## Models

| Project | Licence | What PhoneFold does with it |
|---|---|---|
| [Genie 2](https://github.com/aqlaboratory/genie2) — AQ Laboratory | Apache-2.0 | **Shipped in the app.** One reverse-diffusion step is exported to Core ML as `Genie2Step_L64.mlpackage` and run on the Apple Neural Engine. See "Changes to Genie 2" below. |
| [ESMFold](https://huggingface.co/facebook/esmfold_v1) — Meta AI | MIT | Phase 0 exploration and reference trajectories, via `transformers`' `EsmForProteinFolding`. Not shipped in the app. |
| [FoldingDiff](https://huggingface.co/wukevin/foldingdiff_cath) — Kevin Wu et al. | MIT | Generating sample trajectories offline. Not shipped in the app. |

**Changes to Genie 2**, as Apache-2.0 §4(b) asks to be stated. The reverse process is
re-implemented in Swift (`PhoneFoldKit/Sources/FoldEngine/Genie2Sampler.swift`) against a Core ML
export of a single trunk step; the schedule is recomputed in `Genie2Schedule.swift`; and the
sampler projects the translations back onto the zero-centre-of-mass subspace at every step. That
last one is a fix rather than a variation — without it half the seeds diverged to NaN, and the
measurement is in `METRICS.md` under P4-14. The upstream repository carries no `NOTICE` file, so
there is none to propagate.

**The weights are not in this repository.** `Models/*.mlpackage/` is gitignored. Obtain Genie 2
from its own repository under its own licence and run `Tools/export_genie2_coreml.py`.

## Structural and sequence data

| Source | Licence | Used for |
|---|---|---|
| [RCSB PDB](https://www.rcsb.org) | CC0 1.0 | Reference structures, the bundled sample trajectories, and the secondary-structure training set |
| [AlphaFold Protein Structure Database](https://alphafold.ebi.ac.uk) | CC BY 4.0 | Structures fetched by accession at runtime — EMBL-EBI and DeepMind |
| [UniProt](https://www.uniprot.org) | CC BY 4.0 | Sequences and accession lookup |

## Tools

None of these ship in the app; the app itself depends on Apple frameworks only.

| Project | Licence | Used for |
|---|---|---|
| [DSSP / mkdssp](https://github.com/PDB-REDO/dssp) | BSD-2-Clause | Generating the secondary-structure labels the bundled classifier is trained against |
| [PyTorch](https://github.com/pytorch/pytorch) | BSD-3-Clause (GitHub's classifier reports NOASSERTION; the file carries several copyright holders) | Model export |
| [Hugging Face Transformers](https://github.com/huggingface/transformers) | Apache-2.0 | ESMFold |
| [Hugging Face Accelerate](https://github.com/huggingface/accelerate) | Apache-2.0 | Model export |
| [Core ML Tools](https://github.com/apple/coremltools) | BSD-3-Clause | Converting Genie 2 to Core ML |
| [Biotite](https://github.com/biotite-dev/biotite) | BSD-3-Clause | Validating exported mmCIF in the phase gate |
| [NumPy](https://github.com/numpy/numpy) | BSD-3-Clause (NOASSERTION on GitHub: the licence file bundles vendored licences) | Everywhere in the tooling |
| [SciPy](https://github.com/scipy/scipy) | BSD-3-Clause | Tooling |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT | Generating the Xcode project |

## Published methods

PhoneFold implements these rather than depending on code; each is cited where it is used.

- Kyte, J. & Doolittle, R. F. (1982) *J. Mol. Biol.* **157**, 105–132 — hydropathy, which sets pitch
- Zamyatnin, A. A. (1972) *Prog. Biophys. Mol. Biol.* **24**, 107–123 — residue volumes, used by the mutation model
- Clementi, C., Nymeyer, H. & Onuchic, J. N. (2000) *J. Mol. Biol.* **298**, 937–953 — structure-based (Gō) models, and how a substitution is represented as a perturbation of native contact energies
- Kohn, J. E. *et al.* (2004) *PNAS* **101**, 12491–12496 — denatured-state radius of gyration
- Dima, R. I. & Thirumalai, D. (2004) *J. Phys. Chem. B* **108**, 6564–6570 — native-state radius of gyration
- ITU-R BS.1770-4 — integrated loudness, both gates, used to normalise every export
