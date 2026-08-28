#!/usr/bin/env python3
"""Measure a foldingDiff denoising trajectory on the same criteria that decided against ESMFold.

foldingDiff is UNCONDITIONAL: it generates a novel backbone from noise and has no sequence
input, so it cannot fold a named protein and cannot be PhoneFold's main engine. This script
exists to answer one question with numbers rather than impressions: what does a genuinely
watchable folding trajectory look like, against ESMFold's measured 0.76-1.52 A of total motion?
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / ".cache/foldingdiff-src"))

from foldingdiff import modelling, sampling                      # noqa: E402
from foldingdiff import datasets as dsets                        # noqa: E402
from foldingdiff import angles_and_coords as ac                  # noqa: E402
from huggingface_hub import snapshot_download                    # noqa: E402
import json                                                      # noqa: E402


def kabsch_rmsd(P, Q):
    Pc, Qc = P - P.mean(0), Q - Q.mean(0)
    V, _, Wt = np.linalg.svd(Pc.T @ Qc)
    D = np.diag([1.0, 1.0, np.sign(np.linalg.det(V @ Wt))])
    return float(np.sqrt((((Pc @ (V @ D @ Wt)) - Qc) ** 2).sum(1).mean()))


def rg(ca):
    return float(np.sqrt(((ca - ca.mean(0)) ** 2).sum(1).mean()))


def main() -> int:
    length = int(sys.argv[1]) if len(sys.argv) > 1 else 76
    model_dir = snapshot_download("wukevin/foldingdiff")
    training_args = json.loads((Path(model_dir) / "training_args.json").read_text())

    model = modelling.BertForDiffusionBase.from_dir(model_dir).eval()
    n_params = sum(p.numel() for p in model.parameters())
    print(f"foldingDiff: {n_params/1e6:.1f} M parameters, "
          f"{training_args['timesteps']} denoising steps, max length "
          f"{model.config.max_position_embeddings}")

    dummy = dsets.AnglesEmptyDataset.from_dir(model_dir)
    noised = dsets.NoisedAnglesDataset(
        dset=dummy, dset_key="angles", timesteps=training_args["timesteps"],
        exhaustive_t=False, beta_schedule=training_args["variance_schedule"],
        nonangular_variance=1.0, angular_variance=training_args["variance_scale"])

    print(f"\nsampling one {length}-residue backbone, capturing every denoising step ...")
    torch.manual_seed(0)
    sampled = sampling.sample(model, noised, n=1, sweep_lengths=(length, length + 1),
                              batch_size=1, disable_pbar=True)
    traj = sampled[0]                    # (timesteps, length, n_angle_features)
    print(f"trajectory: {traj.shape[0]} steps x {traj.shape[1]} residues "
          f"x {traj.shape[2]} angle features")

    # Convert a subset of steps to Cartesian coordinates via NeRF. Doing all 1000 is
    # needless; the shape of the curve is what matters.
    names = noised.feature_names["angles"]
    steps = sorted({0, 1, 2, 5, 10, 25, 50, 100, 200, 400, 600, 800, 900, 950, 990,
                    traj.shape[0] - 1})
    out = HERE / ".cache/foldingdiff_traj"
    out.mkdir(parents=True, exist_ok=True)

    coords = {}
    for s in steps:
        df = pd.DataFrame(traj[s], columns=names)
        pdb = ac.create_new_chain_nerf(str(out / f"step_{s:04d}.pdb"), df)
        xyz, atom = [], []
        for line in Path(pdb).read_text().splitlines():
            if line.startswith("ATOM"):
                atom.append(line[12:16].strip())
                xyz.append([float(line[30:38]), float(line[38:46]), float(line[46:54])])
        xyz = np.array(xyz)
        coords[s] = xyz[[i for i, a in enumerate(atom) if a == "CA"]]

    final = coords[steps[-1]]
    print(f"\n{'step':>6} {'RMSD to final':>14} {'Rg (A)':>8} {'CA-CA mean':>11} {'CA-CA sd':>9}")
    for s in steps:
        ca = coords[s]
        d = np.linalg.norm(np.diff(ca, axis=0), axis=1)
        print(f"{s:>6} {kabsch_rmsd(ca, final):>13.2f}A {rg(ca):>8.2f} "
              f"{d.mean():>11.3f} {d.std():>9.3f}")

    rmsds = [kabsch_rmsd(coords[s], final) for s in steps]
    rgs = [rg(coords[s]) for s in steps]
    print(f"\nmax RMSD across the trajectory: {max(rmsds):.2f} A")
    print(f"radius of gyration range:       {min(rgs):.1f} - {max(rgs):.1f} A")
    print(f"\nfor comparison, ESMFold on {length}-residue ubiquitin: "
          f"max RMSD 0.87 A, Rg 11.3-12.0 A")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
