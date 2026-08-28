#!/usr/bin/env python3
"""Generate .pftraj trajectories by real Genie 2 sampling.

Genie 2 (Lin et al., arXiv 2405.15489, Apache-2.0) is an SE(3)-equivariant diffusion model
over residue frames: 15.73 M parameters, 1000 DDPM steps, trained to a maximum length of 256.
It was adopted as PhoneFold's live engine after measurement (METRICS.md): 8/8 compact and
8/8 designable at 76 residues, against foldingDiff's 2/14 and 0/14.

Like foldingDiff it is a **generator**, so the same two honest gaps apply and are handled the
same way. The sequence is written as `X` until `assign_sequences.py` runs ProteinMPNN, and
the per-residue value is **denoising progress**, not pLDDT, recorded as such in the
provenance so nothing downstream can mistake one for the other.

Unlike foldingDiff, Genie 2 emits a **CA trace** and nothing else. That is stored as a
CA-trace `.pftraj` rather than padded out with constructed N and C atoms: the renderer sweeps
its tube through CA anyway, and the P-SEA assignment PLAN.md specifies is CA-only by design.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch

import pftraj

HERE = Path(__file__).resolve().parent
GENIE = HERE / ".cache/genie2-src"
sys.path.insert(0, str(GENIE))

MODEL_ID = "aqlaboratory/genie2"


def load_genie(epoch: int = 40):
    from genie.utils.model_io import load_pretrained_model
    cwd = os.getcwd()
    os.chdir(GENIE)
    try:
        return load_pretrained_model("results", "base", epoch).eval().to("cpu")
    finally:
        os.chdir(cwd)


def sample_with_trajectory(model, length: int, seed: int, scale: float):
    """Run Genie 2's own reverse diffusion, capturing the CA trace at every step.

    This mirrors `genie.sampler.base.BaseSampler.sample` exactly, apart from recording the
    intermediate translations. If the upstream sampler changes, this must be re-derived
    rather than patched blindly.

    Verified equivalent to the upstream sampler: for the same seed, all 1000 `randn_like`
    draws are identical and the final structure matches to a Kabsch RMSD of 0.00048 A, which
    is PDB write rounding. (A raw coordinate comparison shows an 85 A difference, because
    upstream centres the structure in its PDB writer; that is a rigid-body offset, not a
    disagreement. Compare structures after superposition, never coordinate-wise.)
    """
    from genie.sampler.unconditional import UnconditionalSampler
    from genie.utils.affine_utils import T
    from genie.utils.geo_utils import compute_frenet_frames
    from genie.utils.feat_utils import (create_empty_np_features,
                                        convert_np_features_to_tensor,
                                        batchify_np_features)

    torch.manual_seed(seed)
    np.random.seed(seed)

    sampler = UnconditionalSampler(model)
    params = {"length": length, "scale": scale, "num_samples": 1,
              "outdir": "/tmp", "prefix": str(length), "offset": 0}
    features = convert_np_features_to_tensor(
        batchify_np_features([sampler.create_np_features(params)]), model.device)

    trans = torch.randn_like(features["atom_positions"])
    rots = compute_frenet_frames(trans, features["chain_index"], features["residue_mask"])
    ts = T(rots, trans)

    n_timestep = model.config.diffusion["n_timestep"]
    frames = []
    for step in reversed(np.arange(1, n_timestep + 1)):
        timesteps = torch.Tensor([step]).int().to(model.device)
        with torch.no_grad():
            z_pred = model.model(ts, timesteps, features)["z"]

        w_z = (1.0 - model.alphas[timesteps]) / model.sqrt_one_minus_alphas_cumprod[timesteps]
        trans_mean = (1.0 / model.sqrt_alphas[timesteps]).view(-1, 1, 1) * (
            ts.trans - w_z.view(-1, 1, 1) * z_pred)
        trans_mean = trans_mean * features["residue_mask"].unsqueeze(-1)

        if step == 1:
            rots_mean = compute_frenet_frames(trans_mean, features["chain_index"],
                                              features["residue_mask"])
            ts = T(rots_mean.detach(), trans_mean.detach())
        else:
            trans_z = torch.randn_like(ts.trans) * features["residue_mask"].unsqueeze(-1)
            trans_sigma = model.sqrt_betas[timesteps].view(-1, 1, 1)
            trans = trans_mean + params["scale"] * trans_sigma * trans_z
            rots = compute_frenet_frames(trans, features["chain_index"],
                                         features["residue_mask"])
            ts = T(rots.detach(), trans.detach())

        # Centre each frame on its own centroid, which is what Genie 2's own PDB writer
        # does. This removes translational drift only; the rotational alignment between
        # consecutive frames is FoldGeometry's Kabsch step at playback, per PLAN.md Phase 1.
        ca = ts.trans[0].cpu().numpy().astype("f4")
        frames.append((int(n_timestep - step), ca - ca.mean(axis=0)))

    return frames


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--length", type=int, default=76,
                    help="residues to generate (Genie 2 is trained to 256)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--scale", type=float, default=0.6, help="sampling noise scale")
    ap.add_argument("--stride", type=int, default=5,
                    help="keep every Nth denoising step; the final step is always kept")
    ap.add_argument("--name", default=None)
    ap.add_argument("--out", type=Path,
                    default=HERE.parent / "Apps/Shared/Resources/Trajectories")
    args = ap.parse_args()

    if not 1 <= args.length <= 256:
        print(f"length {args.length} is outside Genie 2's trained range of 1-256",
              file=sys.stderr)
        return 2

    print(f"loading Genie 2 ...", flush=True)
    model = load_genie()
    n_params = sum(p.numel() for p in model.parameters())
    n_timestep = model.config.diffusion["n_timestep"]
    print(f"Genie 2: {n_params/1e6:.2f} M parameters, {n_timestep} DDPM steps")

    print(f"\nsampling {args.length} residues, seed {args.seed}, scale {args.scale} ...",
          flush=True)
    t0 = time.time()
    frames = sample_with_trajectory(model, args.length, args.seed, args.scale)
    elapsed = time.time() - t0

    keep = sorted(set(range(0, len(frames), args.stride)) | {len(frames) - 1})
    readouts = []
    for i in keep:
        step, ca = frames[i]
        if not np.isfinite(ca).all():
            print(f"  step {step}: non-finite coordinates, skipped", file=sys.stderr)
            continue
        progress = np.float32(100.0 * step / (len(frames) - 1))
        readouts.append(pftraj.Readout(
            recycle=0, block_index=step,
            backbone=ca.reshape(args.length, 1, 3),      # CA trace: one atom per residue
            plddt=np.full(args.length, progress, dtype="f4")))

    if not readouts:
        print("no usable frames", file=sys.stderr)
        return 1

    final_ca = readouts[-1].backbone[:, 0, :]
    rg = float(np.sqrt(((final_ca - final_ca.mean(0)) ** 2).sum(1).mean()))
    expected_rg = 2.2 * args.length ** 0.38
    bonds = np.linalg.norm(np.diff(final_ca, axis=0), axis=1)
    print(f"{len(frames)} steps in {elapsed:.0f} s; keeping {len(readouts)} frames")
    print(f"final: Rg {rg:.2f} A (compact expectation {expected_rg:.2f}, "
          f"ratio {rg/expected_rg:.2f}), CA-CA {bonds.mean():.3f}+-{bonds.std():.3f} A")

    label = args.name or f"Generated {args.length}aa seed {args.seed}"
    meta = pftraj.TrajectoryMetadata(
        name=label,
        sequence="X" * args.length,
        provenance=pftraj.PROVENANCE_GENIE2,
        sourceModel=MODEL_ID,
        blocksPerReadout=args.stride,
        recycles=1,
        generated=dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        organism="none: this protein is generated, not natural",
        listeningNote=("A protein that has never existed, folding from noise. Nothing here "
                       "is a prediction of a real structure."),
        notes=(f"Genie 2 {n_params/1e6:.2f}M params, {n_timestep} DDPM steps, seed "
               f"{args.seed}, scale {args.scale}, every {args.stride}th step kept "
               f"({len(readouts)} frames), sampled in {elapsed:.0f} s on CPU; "
               f"torch {torch.__version__}. CA TRACE ONLY: Genie 2 emits no other atoms. "
               f"Per-residue value is DENOISING PROGRESS, not pLDDT. Sequence is X until "
               f"ProteinMPNN inverse folding assigns one. "
               f"Final Rg {rg:.2f} A against a compact expectation of {expected_rg:.2f} A."))

    stem = (args.name.lower().replace(" ", "_") if args.name
            else f"genie2_{args.length}aa_seed{args.seed}")
    path = pftraj.write(args.out / f"{stem}.pftraj", meta, readouts)
    print(f"\n{len(readouts)} frames -> {path} ({path.stat().st_size/1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
