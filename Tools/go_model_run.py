#!/usr/bin/env python3
"""Drive the C structure-based model: fold a named protein from an extended chain.

The native state is the final frame of a bundled `.pftraj` - for the twelve gallery
proteins that is ESMFold's own prediction, which for ubiquitin sits 0.83 A from
experimental 1UBQ (METRICS.md). Nothing here is downloaded and nothing is precomputed
except the native state itself, which is what "fold *this* protein" means.

Outputs an .npz that `fold_gradient_report.py` reads, so a physics trajectory and a
diffusion trajectory are judged by exactly the same measurements.

    go_model_run.py ubiquitin.pftraj --steps 5000000 --kT 0.9 --out /tmp/ubq.npz
    go_model_run.py ubiquitin.pftraj --scan 0.6,0.8,1.0 --steps 2000000
"""
from __future__ import annotations

import argparse
import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np

import fold_metrics as fm
from go_model_fold import GoModel, load_native, random_coil

HERE = Path(__file__).resolve().parent
BINARY = HERE / "go_model_fold_bin"
SOURCE = HERE / "go_model_fold.c"


def ensure_binary() -> Path:
    if not BINARY.exists() or BINARY.stat().st_mtime < SOURCE.stat().st_mtime:
        subprocess.run(["clang", "-O2", "-o", str(BINARY), str(SOURCE), "-lm"], check=True)
    return BINARY


def run(native: np.ndarray, start: np.ndarray, steps: int, kT: float, dt: float,
        gamma: float, stride: int, seed: int, cutoff: float = 8.0,
        min_sep: int = 3, kT_final: float | None = None) -> tuple[np.ndarray, float]:
    exe = ensure_binary()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        np.savetxt(tmp / "native.xyz", native)
        np.savetxt(tmp / "start.xyz", start)
        t0 = time.time()
        proc = subprocess.run(
            [str(exe), "--native", str(tmp / "native.xyz"), "--start", str(tmp / "start.xyz"),
             "--out", str(tmp / "frames.bin"), "--steps", str(steps), "--stride", str(stride),
             "--kT", str(kT), "--kT-final", str(kT if kT_final is None else kT_final),
             "--dt", str(dt), "--gamma", str(gamma), "--seed", str(seed),
             "--cutoff", str(cutoff), "--min-sep", str(min_sep)],
            check=True, capture_output=True, text=True)
        wall = time.time() - t0
        raw = (tmp / "frames.bin").read_bytes()
    n, frames = np.frombuffer(raw, dtype="<i4", count=2)
    ca = np.frombuffer(raw, dtype="<f4", offset=8).reshape(-1, n, 3).astype(np.float64)
    print(f"    {proc.stderr.strip()}")
    return ca, wall


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("native", type=Path)
    ap.add_argument("--steps", type=int, default=5_000_000)
    ap.add_argument("--stride", type=int, default=25_000)
    ap.add_argument("--kT", type=float, default=0.9)
    ap.add_argument("--kT-final", type=float, default=None,
                    help="anneal linearly to this temperature by the last step")
    ap.add_argument("--dt", type=float, default=0.005)
    ap.add_argument("--gamma", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cutoff", type=float, default=8.0)
    ap.add_argument("--min-sep", type=int, default=3)
    ap.add_argument("--scan", type=str, default=None)
    ap.add_argument("--replicas", type=int, default=1)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()

    name, sequence, native = load_native(args.native)
    model = GoModel(native, contact_cutoff=args.cutoff, min_sep=args.min_sep)
    expected = fm.compact_expectation(model.n)
    print(f"{name}: {model.n} residues, {len(model.native_pairs)} native contacts, "
          f"native Rg {fm.radius_of_gyration(native):.2f} A "
          f"(compact expectation {expected:.2f})")

    temperatures = ([float(t) for t in args.scan.split(",")] if args.scan else [args.kT])
    for kT in temperatures:
        for rep in range(args.replicas):
            seed = args.seed + rep
            start = random_coil(model.n, np.random.default_rng(seed))
            print(f"  kT {kT:.2f} seed {seed}: start Rg "
                  f"{fm.radius_of_gyration(start):.1f} A, Q {model.q(start):.3f}")
            ca, wall = run(native, start, args.steps, kT, args.dt, args.gamma,
                           args.stride, seed, args.cutoff, args.min_sep, args.kT_final)
            q = np.array([model.q(f) for f in ca])
            rg = np.array([fm.radius_of_gyration(f) for f in ca])
            rmsd = np.array([fm.kabsch_rmsd(f, native) for f in ca])
            tm = fm.tm_score(ca[-1], native)
            ss0, ss1 = fm.sse_content(ca[0]), fm.sse_content(ca[-1])
            ssn = fm.sse_content(native)
            print(f"    Q {q[0]:.3f} -> {q[-1]:.3f} (max {q.max():.3f}), "
                  f"Rg {rg[0]:.1f} -> {rg[-1]:.1f} A, "
                  f"RMSD to native {rmsd[0]:.1f} -> {rmsd[-1]:.1f} A, TM {tm:.3f}, "
                  f"{wall:.1f} s")
            print(f"    ordered SS {ss0['helix'] + ss0['sheet']:.2f} -> "
                  f"{ss1['helix'] + ss1['sheet']:.2f}  (native "
                  f"{ssn['helix'] + ssn['sheet']:.2f}); helix "
                  f"{ss0['helix']:.2f} -> {ss1['helix']:.2f} (native {ssn['helix']:.2f}), "
                  f"sheet {ss0['sheet']:.2f} -> {ss1['sheet']:.2f} "
                  f"(native {ssn['sheet']:.2f})")
            if args.out:
                out = args.out if len(temperatures) == 1 and args.replicas == 1 else \
                    args.out.with_name(f"{args.out.stem}_kT{kT}_s{seed}{args.out.suffix}")
                np.savez_compressed(out, ca=ca.astype(np.float32), name=name,
                                    sequence=sequence, native=native.astype(np.float32),
                                    q=q, rg=rg, rmsd=rmsd, kT=kT, dt=args.dt,
                                    gamma=args.gamma, steps=args.steps,
                                    stride=args.stride, seed=seed, wall_seconds=wall)
                print(f"    wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
