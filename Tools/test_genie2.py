#!/usr/bin/env python3
"""Measure Genie 2 backbones on exactly the criteria that ruled foldingDiff out.

Genie 2 (Lin et al., arXiv 2405.15489, Apache-2.0) is an SE(3)-equivariant diffusion model
that generates **CA traces**, not full backbones, and is sequence-agnostic. 15.73 M
parameters, 1000 DDPM steps, trained to a maximum length of 256.

Same measurements as METRICS.md reports for foldingDiff, so the two are directly comparable:
radius of gyration against the compact-fold expectation, CA-CA virtual bond geometry,
ProteinMPNN composition, and self-consistency TM. The scTM here carries the same caveat: the
fold-back uses ESMFold rather than OmegaFold, so it is biased low for designed sequences.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
GENIE = HERE / ".cache/genie2-src"
MPNN = HERE / ".cache/proteinmpnn-src"

sys.path.insert(0, str(GENIE))


def load_genie(epoch: int = 40):
    from genie.utils.model_io import load_pretrained_model
    cwd = os.getcwd()
    os.chdir(GENIE)
    try:
        model = load_pretrained_model("results", "base", epoch).eval().to("cpu")
    finally:
        os.chdir(cwd)
    return model


def sample_ca_trace(model, length: int, seed: int, scale: float = 0.6) -> np.ndarray:
    """One unconditional sample -> (L, 3) CA coordinates."""
    from genie.sampler.unconditional import UnconditionalSampler
    torch.manual_seed(seed)
    np.random.seed(seed)
    with tempfile.TemporaryDirectory() as tmp:
        UnconditionalSampler(model).sample({
            "length": length, "scale": scale, "num_samples": 1,
            "outdir": tmp, "prefix": str(length), "offset": 0})
        pdbs = sorted(Path(tmp).glob("pdbs/*.pdb"))
        if not pdbs:
            raise RuntimeError("Genie 2 produced no structure")
        coords = [[float(l[30:38]), float(l[38:46]), float(l[46:54])]
                  for l in pdbs[0].read_text().splitlines()
                  if l.startswith("ATOM") and l[12:16].strip() == "CA"]
    return np.asarray(coords, dtype="f4")


def write_ca_pdb(ca: np.ndarray, path: Path) -> Path:
    lines = []
    for i, xyz in enumerate(ca, start=1):
        lines.append(f"ATOM  {i:>5}  CA  GLY A{i:>4}    "
                     f"{xyz[0]:>8.3f}{xyz[1]:>8.3f}{xyz[2]:>8.3f}  1.00  0.00           C")
    path.write_text("\n".join(lines) + "\nTER\nEND\n")
    return path


def design_ca(ca: np.ndarray, *, temperature: float, seed: int) -> str:
    """ProteinMPNN in CA-only mode, which is what a CA trace requires."""
    if seed == 0:
        raise ValueError("seed 0 means 'random' to ProteinMPNN; pass a non-zero seed")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        pdb = write_ca_pdb(ca, tmp / "trace.pdb")
        out = tmp / "out"
        proc = subprocess.run(
            [sys.executable, str(MPNN / "protein_mpnn_run.py"),
             "--ca_only", "--path_to_model_weights", str(MPNN / "ca_model_weights"),
             "--model_name", "v_48_020",
             "--pdb_path", str(pdb), "--out_folder", str(out),
             "--num_seq_per_target", "1", "--sampling_temp", str(temperature),
             "--seed", str(seed), "--batch_size", "1"],
            capture_output=True, text=True, cwd=str(MPNN))
        if proc.returncode != 0:
            raise RuntimeError(f"ProteinMPNN failed:\n{proc.stdout}\n{proc.stderr}")
        fa = sorted(out.glob("seqs/*.fa"))
        if not fa:
            raise RuntimeError(f"no sequences produced:\n{proc.stdout}")
        recs, header, seq = [], None, []
        for line in fa[0].read_text().splitlines():
            if line.startswith(">"):
                if header is not None:
                    recs.append("".join(seq))
                header, seq = line, []
            elif line.strip():
                seq.append(line.strip())
        if header is not None:
            recs.append("".join(seq))
        return recs[1].upper()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--length", type=int, default=76)
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--scale", type=float, default=0.6)
    ap.add_argument("--temperature", type=float, default=0.1)
    args = ap.parse_args()

    print("loading Genie 2 ...", flush=True)
    genie = load_genie()
    n_params = sum(p.numel() for p in genie.parameters())
    print(f"Genie 2: {n_params/1e6:.2f} M parameters, "
          f"{genie.config.diffusion['n_timestep']} DDPM steps")

    print("loading ESMFold for the fold-back ...", flush=True)
    from transformers import AutoTokenizer, EsmForProteinFolding
    tok = AutoTokenizer.from_pretrained("facebook/esmfold_v1")
    esm = EsmForProteinFolding.from_pretrained("facebook/esmfold_v1",
                                               dtype=torch.float32).eval()
    esm.trunk.set_chunk_size(64)

    import biotite.structure as struc
    sys.path.insert(0, str(HERE))
    from designability import sc_tm

    expected_rg = 2.2 * args.length ** 0.38
    print(f"\ncompact-fold expectation for {args.length} residues: Rg {expected_rg:.2f} A")
    print(f"\n{'seed':>5} {'secs':>6} {'Rg':>6} {'Rg/exp':>7} {'CA-CA':>13} {'scTM':>6} "
          f"{'RMSD':>7} {'types':>6} {'top1':>6} {'charged':>8}")
    print("-" * 92)

    rows = []
    for seed in range(args.first_seed, args.first_seed + args.n):
        t0 = time.time()
        ca = sample_ca_trace(genie, args.length, seed, args.scale)
        secs = time.time() - t0
        bonds = np.linalg.norm(np.diff(ca, axis=0), axis=1)
        rg = float(np.sqrt(((ca - ca.mean(0)) ** 2).sum(1).mean()))

        seq = design_ca(ca, temperature=args.temperature, seed=seed)
        inp = tok([seq], return_tensors="pt", add_special_tokens=False)
        with torch.no_grad():
            out = esm(**inp, num_recycles=3)
        pred = out.positions[-1, 0][:, 1, :].numpy()
        tm = sc_tm(ca, pred)
        Pc, Qc = ca - ca.mean(0), pred - pred.mean(0)
        V, _, Wt = np.linalg.svd(Pc.T @ Qc)
        D = np.diag([1.0, 1.0, np.sign(np.linalg.det(V @ Wt))])
        rmsd = float(np.sqrt((((Pc @ (V @ D @ Wt)) - Qc) ** 2).sum(1).mean()))

        comp = sorted({a: seq.count(a) for a in set(seq)}.items(), key=lambda kv: -kv[1])
        top1 = comp[0][1] / len(seq) * 100
        charged = sum(seq.count(a) for a in "RKDE") / len(seq) * 100
        print(f"{seed:>5} {secs:>6.0f} {rg:>6.1f} {rg/expected_rg:>7.2f} "
              f"{bonds.mean():>6.3f}+-{bonds.std():<5.3f} {tm:>6.3f} {rmsd:>6.2f}A "
              f"{len(comp):>6} {top1:>5.0f}% {charged:>7.0f}%", flush=True)
        rows.append({"rg_ratio": rg / expected_rg, "sctm": tm, "rmsd": rmsd,
                     "types": len(comp), "top1": top1, "charged": charged, "secs": secs})

    r = lambda k: [x[k] for x in rows]
    print(f"\nGenie 2, {len(rows)} samples at {args.length} residues")
    print(f"  Rg/expected : median {np.median(r('rg_ratio')):.2f}, "
          f"range {min(r('rg_ratio')):.2f}-{max(r('rg_ratio')):.2f}   "
          f"(foldingDiff: median 1.55, range 1.12-2.78)")
    print(f"  compact (<=1.2): {sum(1 for x in r('rg_ratio') if x <= 1.2)}/{len(rows)}"
          f"   (foldingDiff: 2/14)")
    print(f"  scTM        : median {np.median(r('sctm')):.3f}, "
          f"max {max(r('sctm')):.3f}   (foldingDiff: median 0.118, max 0.229)")
    print(f"  designable  : {sum(1 for x in r('sctm') if x > 0.5)}/{len(rows)}"
          f"   (foldingDiff: 0/14)")
    print(f"  charged     : median {np.median(r('charged')):.0f}%"
          f"   (foldingDiff: 13%, a real fold: 41%)")
    print(f"  seconds/sample: median {np.median(r('secs')):.0f} s"
          f"   (foldingDiff: 18 s)")
    print("\nscTM caveat: fold-back is ESMFold, not the OmegaFold the authors use, so these "
          "are biased low for designed sequences. Rg needs no predictor.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
