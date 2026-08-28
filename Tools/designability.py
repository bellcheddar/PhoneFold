#!/usr/bin/env python3
"""Measure the designability of foldingDiff backbones by self-consistency.

The standard metric, and the one the foldingDiff paper itself reports: generate a backbone,
design a sequence for it with ProteinMPNN, fold that sequence back with a structure
predictor, and compare. If the prediction matches the generated backbone, the backbone is
something a real protein could adopt. scTM above 0.5 is the usual threshold.

This matters for PhoneFold beyond structural plausibility. A backbone that designs to
poly-alanine gives the score nothing to work with: no hydrophobicity contrast for the
colour mode, no charged residues for the Fantasy octave triggers, and a uniform note
velocity. The app needs backbones that are designable *and* compositionally interesting.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

import pftraj
import assign_sequences as A
import make_foldingdiff_trajectories as FD

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / ".cache/foldingdiff-src"))

import biotite.structure as struc                                  # noqa: E402
from foldingdiff import modelling, sampling                        # noqa: E402
from foldingdiff import datasets as dsets                          # noqa: E402
from huggingface_hub import snapshot_download                      # noqa: E402
import pandas as pd, json                                          # noqa: E402


def ca_array(coords: np.ndarray) -> struc.AtomArray:
    """(L, 3) CA coordinates -> a biotite AtomArray that tm_score will accept."""
    arr = struc.AtomArray(len(coords))
    arr.coord = coords.astype("f4")
    arr.chain_id = np.full(len(coords), "A")
    arr.res_id = np.arange(1, len(coords) + 1)
    arr.res_name = np.full(len(coords), "GLY")
    arr.atom_name = np.full(len(coords), "CA")
    arr.element = np.full(len(coords), "C")
    return arr


def sc_tm(generated_ca: np.ndarray, predicted_ca: np.ndarray) -> float:
    a, b = ca_array(generated_ca), ca_array(predicted_ca)
    idx = np.arange(len(generated_ca))
    fitted, _ = struc.superimpose(a, b)
    return float(struc.tm_score(a, fitted, idx, idx))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--length", type=int, default=76)
    ap.add_argument("--n", type=int, default=8, help="backbones to generate")
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=0.1)
    args = ap.parse_args()

    print("loading foldingDiff ...", flush=True)
    model_dir = snapshot_download(FD.MODEL_ID)
    targs = json.loads((Path(model_dir) / "training_args.json").read_text())
    fd = modelling.BertForDiffusionBase.from_dir(model_dir).eval()
    dummy = dsets.AnglesEmptyDataset.from_dir(model_dir)
    noised = dsets.NoisedAnglesDataset(
        dset=dummy, dset_key="angles", timesteps=targs["timesteps"], exhaustive_t=False,
        beta_schedule=targs["variance_schedule"], nonangular_variance=1.0,
        angular_variance=targs["variance_scale"])
    names = noised.feature_names["angles"]

    print("loading ESMFold for the fold-back step ...", flush=True)
    from transformers import AutoTokenizer, EsmForProteinFolding
    tok = AutoTokenizer.from_pretrained("facebook/esmfold_v1")
    esm = EsmForProteinFolding.from_pretrained("facebook/esmfold_v1",
                                               dtype=torch.float32).eval()
    esm.trunk.set_chunk_size(64)

    # A compact globular chain has Rg ~ 2.2 * N^0.38 A. The ratio to that is computable
    # from the backbone alone, with no model, so it is the one filter an on-device app
    # could actually afford before committing to a fold.
    expected_rg = 2.2 * args.length ** 0.38
    print(f"\n{'seed':>5} {'Rg':>6} {'Rg/exp':>7} {'scTM':>6} {'RMSD':>7} {'types':>6} "
          f"{'top1':>6} {'charged':>8} {'pLDDT':>7}")
    print("-" * 72)
    rows = []
    for seed in range(args.first_seed, args.first_seed + args.n):
        traj, _ = FD.sample_trajectory(fd, noised, args.length, seed)
        backbone = FD.build_backbone(pd.DataFrame(traj[-1], columns=names))
        if not np.isfinite(backbone).all():
            print(f"{seed:>5}  non-finite backbone, skipped"); continue
        seq = A.design(backbone, temperature=args.temperature, seed=seed)

        inp = tok([seq], return_tensors="pt", add_special_tokens=False)
        with torch.no_grad():
            out = esm(**inp, num_recycles=3)
        pred_ca = out.positions[-1, 0][:, 1, :].numpy()
        plddt = float((out.plddt[0][:, 1] * 100).mean())

        gen_ca = backbone[:, 1, :]
        rg = float(np.sqrt(((gen_ca - gen_ca.mean(0)) ** 2).sum(1).mean()))
        tm = sc_tm(gen_ca, pred_ca)
        Pc, Qc = gen_ca - gen_ca.mean(0), pred_ca - pred_ca.mean(0)
        V, _, Wt = np.linalg.svd(Pc.T @ Qc)
        D = np.diag([1.0, 1.0, np.sign(np.linalg.det(V @ Wt))])
        rmsd = float(np.sqrt((((Pc @ (V @ D @ Wt)) - Qc) ** 2).sum(1).mean()))

        comp = sorted({a: seq.count(a) for a in set(seq)}.items(), key=lambda kv: -kv[1])
        top1 = comp[0][1] / len(seq) * 100
        charged = sum(seq.count(a) for a in "RKDE") / len(seq) * 100
        print(f"{seed:>5} {rg:>6.1f} {rg/expected_rg:>7.2f} {tm:>6.3f} {rmsd:>6.2f}A "
              f"{len(comp):>6} {top1:>5.0f}% {charged:>7.0f}% {plddt:>7.1f}")
        rows.append({"seed": seed, "rg": rg, "rg_ratio": rg / expected_rg, "sctm": tm,
                     "rmsd": rmsd, "types": len(comp), "top1_pct": top1,
                     "charged_pct": charged, "plddt": plddt})

    if not rows:
        return 1
    tms = [r["sctm"] for r in rows]
    designable = [r for r in rows if r["sctm"] > 0.5]
    print(f"\nscTM: median {np.median(tms):.3f}, range {min(tms):.3f}-{max(tms):.3f}")
    print(f"designable (scTM > 0.5): {len(designable)}/{len(rows)} "
          f"= {len(designable)/len(rows)*100:.0f}%")
    print(f"median charged residues: {np.median([r['charged_pct'] for r in rows]):.0f}% "
          f"(a real fold designs to ~41%)")
    print(f"median most-common residue: {np.median([r['top1_pct'] for r in rows]):.0f}% "
          f"of the protein (ubiquitin's design: 17%)")

    # Does a cheap, model-free compactness filter select for designability?
    for cutoff in (1.2, 1.35, 1.5):
        kept = [r for r in rows if r["rg_ratio"] <= cutoff]
        if kept:
            print(f"\nRg/expected <= {cutoff}: kept {len(kept)}/{len(rows)}, "
                  f"median scTM {np.median([r['sctm'] for r in kept]):.3f}, "
                  f"best {max(r['sctm'] for r in kept):.3f}, "
                  f"designable {sum(1 for r in kept if r['sctm'] > 0.5)}")
        else:
            print(f"\nRg/expected <= {cutoff}: nothing kept")
    import numpy as _np
    if len(rows) > 2:
        c = _np.corrcoef([r["rg_ratio"] for r in rows], [r["sctm"] for r in rows])[0, 1]
        print(f"\ncorrelation between Rg ratio and scTM: {c:+.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
