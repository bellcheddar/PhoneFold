#!/usr/bin/env python3
"""Generate .pftraj trajectories by real foldingDiff sampling.

foldingDiff (Wu et al., Nat Commun 2024) denoises six backbone dihedrals from noise to a
folded backbone over 1000 steps. Unlike ESMFold it is a **generator**: the protein it
produces is novel and has no accession, and the trajectory is a genuine collapse rather than
a refinement. Measured at 76 residues: 15.29 A of motion against ESMFold's 0.87 A.

Two honest gaps this script does not paper over:

* **No sequence.** foldingDiff emits a backbone with no residue identities. The sequence is
  written as `X` (AminoAcid.unknown), which is what it actually is, until
  `assign_sequences.py` runs ProteinMPNN inverse folding over the final backbone.
* **No pLDDT.** foldingDiff is not a predictor and has no confidence. The per-residue value
  written here is the **denoising progress** of the frame, uniform across residues, and the
  provenance records it as `denoising-progress` so nothing downstream can mistake it for a
  pLDDT. Per-residue variation, if wanted, must be derived at playback from how much each
  residue is still moving. It is not invented here.

The carbonyl oxygen is not produced by the model either. It is placed by **idealised
geometry**: CA-C=O 120.8 degrees, C=O 1.231 A, torsion N-CA-C-O of psi + 180 degrees, using
the psi that foldingDiff itself sampled for that residue. That is a deterministic
construction from real model output, applied uniformly including at the C-terminus, not a
guess at data.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
import torch

import pftraj

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / ".cache/foldingdiff-src"))

from foldingdiff import modelling, sampling, nerf                 # noqa: E402
from foldingdiff import datasets as dsets                         # noqa: E402
from huggingface_hub import snapshot_download                     # noqa: E402

MODEL_ID = "wukevin/foldingdiff"

# Idealised carbonyl geometry, Engh & Huber. Used only to place O, which the model does not
# emit; every other coordinate comes from the model's own sampled dihedrals.
CA_C_O_ANGLE = np.deg2rad(120.8)
C_O_LENGTH = 1.231


def build_backbone(angles: pd.DataFrame) -> np.ndarray:
    """Six sampled dihedrals for L residues -> (L, 4, 3) backbone with N, CA, C, O.

    N, CA and C come from foldingDiff's own NeRF reconstruction, with the same angle mapping
    that `angles_and_coords.create_new_chain_nerf` uses. O is placed by idealised geometry.
    """
    builder = nerf.NERFBuilder(
        phi_dihedrals=angles["phi"],
        psi_dihedrals=angles["psi"],
        omega_dihedrals=angles["omega"],
        bond_angle_ca_c=angles["tau"],
        bond_angle_c_n=angles["CA:C:1N"],
        bond_angle_n_ca=angles["C:1N:1CA"],
    )
    flat = builder.centered_cartesian_coords          # (3L, 3), interleaved N, CA, C
    n_res = len(angles)
    if flat.shape != (3 * n_res, 3):
        raise ValueError(f"NeRF returned {flat.shape}, expected {(3 * n_res, 3)}")
    ncac = np.asarray(flat, dtype="f8").reshape(n_res, 3, 3)

    psi = np.asarray(angles["psi"], dtype="f8")
    out = np.zeros((n_res, 4, 3), dtype="f8")
    out[:, 0] = ncac[:, 0]          # N
    out[:, 1] = ncac[:, 1]          # CA
    out[:, 2] = ncac[:, 2]          # C
    for i in range(n_res):
        out[i, 3] = nerf.place_dihedral(
            ncac[i, 0], ncac[i, 1], ncac[i, 2],
            bond_angle=CA_C_O_ANGLE, bond_length=C_O_LENGTH,
            torsion_angle=psi[i] + np.pi)
    return out.astype("f4")


def sample_trajectory(model, noised, length: int, seed: int):
    torch.manual_seed(seed)
    t0 = time.time()
    sampled = sampling.sample(model, noised, n=1, sweep_lengths=(length, length + 1),
                              batch_size=1, disable_pbar=True)
    return sampled[0], time.time() - t0      # (timesteps, L, 6)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--length", type=int, default=76,
                    help="residues to generate (published weights cap at 128)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--stride", type=int, default=5,
                    help="keep every Nth denoising step; the final step is always kept")
    ap.add_argument("--name", default=None, help="display name for the generated protein")
    ap.add_argument("--out", type=Path,
                    default=HERE.parent / "Apps/Shared/Resources/Trajectories")
    args = ap.parse_args()

    model_dir = snapshot_download(MODEL_ID)
    training_args = json.loads((Path(model_dir) / "training_args.json").read_text())
    model = modelling.BertForDiffusionBase.from_dir(model_dir).eval()
    max_len = model.config.max_position_embeddings
    if args.length > max_len:
        print(f"length {args.length} exceeds the published weights' cap of {max_len}",
              file=sys.stderr)
        return 2

    n_params = sum(p.numel() for p in model.parameters())
    timesteps = training_args["timesteps"]
    print(f"foldingDiff: {n_params/1e6:.1f} M parameters, {timesteps} denoising steps, "
          f"max length {max_len}")

    dummy = dsets.AnglesEmptyDataset.from_dir(model_dir)
    noised = dsets.NoisedAnglesDataset(
        dset=dummy, dset_key="angles", timesteps=timesteps, exhaustive_t=False,
        beta_schedule=training_args["variance_schedule"], nonangular_variance=1.0,
        angular_variance=training_args["variance_scale"])
    names = noised.feature_names["angles"]

    print(f"\nsampling a {args.length}-residue backbone, seed {args.seed} ...", flush=True)
    traj, elapsed = sample_trajectory(model, noised, args.length, args.seed)
    n_steps = traj.shape[0]
    keep = sorted(set(range(0, n_steps, args.stride)) | {n_steps - 1})
    print(f"{n_steps} steps sampled in {elapsed:.1f} s; keeping {len(keep)} frames "
          f"(stride {args.stride})")

    readouts = []
    for frame_index, step in enumerate(keep):
        backbone = build_backbone(pd.DataFrame(traj[step], columns=names))
        if not np.isfinite(backbone).all():
            print(f"  step {step}: NeRF produced non-finite coordinates, skipping",
                  file=sys.stderr)
            continue
        # Denoising progress, 0 at the noisiest step and 100 at the final one. Uniform
        # across residues because that is genuinely all the model provides.
        progress = np.float32(100.0 * step / (n_steps - 1))
        readouts.append(pftraj.Readout(
            recycle=0, block_index=step,
            backbone=backbone,
            plddt=np.full(args.length, progress, dtype="f4")))

    if not readouts:
        print("no usable frames were produced", file=sys.stderr)
        return 1

    label = args.name or f"Generated backbone {args.length}aa seed {args.seed}"
    meta = pftraj.TrajectoryMetadata(
        name=label,
        sequence="X" * args.length,      # genuinely unknown until inverse folding runs
        provenance=pftraj.PROVENANCE_FOLDINGDIFF,
        sourceModel=MODEL_ID,
        blocksPerReadout=args.stride,
        recycles=1,
        generated=dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        organism="none: this protein is generated, not natural",
        listeningNote=("A protein that has never existed, folding from noise. Nothing here "
                       "is a prediction of a real structure."),
        notes=(f"foldingDiff {n_params/1e6:.1f}M params, {timesteps} denoising steps, "
               f"seed {args.seed}, every {args.stride}th step kept ({len(readouts)} frames), "
               f"sampled in {elapsed:.1f} s; torch {torch.__version__}. "
               f"Per-residue value is DENOISING PROGRESS, not pLDDT. "
               f"Sequence is X until ProteinMPNN inverse folding assigns one. "
               f"Carbonyl O placed by idealised geometry (CA-C=O 120.8 deg, C=O 1.231 A, "
               f"torsion psi+180) from the model's own sampled psi."))

    stem = args.name.lower().replace(" ", "_") if args.name else \
        f"generated_{args.length}aa_seed{args.seed}"
    path = pftraj.write(args.out / f"{stem}.pftraj", meta, readouts)
    print(f"\n{len(readouts)} frames -> {path} ({path.stat().st_size/1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
