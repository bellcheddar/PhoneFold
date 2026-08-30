#!/usr/bin/env python3
"""The interpolation baseline: a coil morphed into the native structure.

This is the cheapest thing that produces a perfect unfolded-to-folded gradient, and it is
**not folding**. It is measured here so the decision in BLOCKERS.md compares like with
like, and so the failure modes are numbers rather than an argument.

Two variants, because they fail differently:

  cartesian   straight-line interpolation of every CA position. Free, and it tears the
              chain: intermediate frames have CA-CA bond lengths well under 3.8 A because
              the straight line between two conformations passes through configurations
              that are not chains at all.
  torsion     interpolate the CA-trace internal coordinates (bond angle and dihedral) and
              rebuild. Bond lengths are exact by construction, so every frame *is* a
              polypeptide - but the path is a parameter sweep, not a trajectory, and
              nothing in it corresponds to any physical or statistical process.

Usage: morph_baseline.py ubiquitin.pftraj [--frames 200]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import fold_metrics as fm
from go_model_fold import _place, load_native, random_coil


def internal_coordinates(x: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    b = np.linalg.norm(np.diff(x, axis=0), axis=1)
    u, v = x[:-2] - x[1:-1], x[2:] - x[1:-1]
    cos = np.einsum("ij,ij->i", u, v) / (
        np.linalg.norm(u, axis=1) * np.linalg.norm(v, axis=1))
    theta = np.arccos(np.clip(cos, -1, 1))
    b1, b2, b3 = x[1:-2] - x[:-3], x[2:-1] - x[1:-2], x[3:] - x[2:-1]
    n1, n2 = np.cross(b1, b2), np.cross(b2, b3)
    m = np.cross(n1, b2 / np.linalg.norm(b2, axis=1, keepdims=True))
    phi = np.arctan2(np.einsum("ij,ij->i", m, n2), np.einsum("ij,ij->i", n1, n2))
    return b, theta, phi


def rebuild(b: np.ndarray, theta: np.ndarray, phi: np.ndarray) -> np.ndarray:
    n = len(b) + 1
    x = np.zeros((n, 3))
    x[1] = [b[0], 0, 0]
    x[2] = x[1] + b[1] * np.array([-np.cos(theta[0]), np.sin(theta[0]), 0.0])
    for k in range(3, n):
        x[k] = _place(x[k - 3], x[k - 2], x[k - 1], b[k - 1], theta[k - 2], phi[k - 3])
    return x


def angular_lerp(a: np.ndarray, b: np.ndarray, t: float) -> np.ndarray:
    """Interpolate along the shorter arc, so a morph does not spin through 2 pi."""
    d = (b - a + np.pi) % (2 * np.pi) - np.pi
    return a + t * d


def morph(start: np.ndarray, native: np.ndarray, frames: int, mode: str) -> np.ndarray:
    ts = np.linspace(0, 1, frames)
    if mode == "cartesian":
        return np.stack([(1 - t) * start + t * native for t in ts])
    b0, th0, ph0 = internal_coordinates(start)
    b1, th1, ph1 = internal_coordinates(native)
    return np.stack([rebuild((1 - t) * b0 + t * b1,
                             angular_lerp(th0, th1, t),
                             angular_lerp(ph0, ph1, t)) for t in ts])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("native", type=Path)
    ap.add_argument("--frames", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()

    name, sequence, native = load_native(args.native)
    start = random_coil(len(native), np.random.default_rng(args.seed))
    print(f"{name}: {len(native)} residues")
    for mode in ("cartesian", "torsion"):
        traj = morph(start, native, args.frames, mode)
        bonds = [fm.ca_ca(f) for f in traj]
        rg = [fm.radius_of_gyration(f) for f in traj]
        ordered = [fm.sse_content(f)["helix"] + fm.sse_content(f)["sheet"] for f in traj]
        worst = min(m for m, _ in bonds)
        valid = sum(1 for m, s in bonds if abs(m - 3.8) < 0.3 and s < 0.3)
        print(f"  {mode:<10} Rg {rg[0]:.1f} -> {rg[-1]:.1f} A, "
              f"monotonicity {fm.monotonicity(rg):.2f}, "
              f"ordered SS {ordered[0]:.2f} -> {ordered[-1]:.2f}, "
              f"shortest mean CA-CA {worst:.2f} A, polypeptide frames {valid}/{len(traj)}")
        if args.out:
            out = args.out.with_name(f"{args.out.stem}_{mode}{args.out.suffix}")
            np.savez_compressed(out, ca=traj.astype(np.float32), name=f"{name} ({mode} morph)",
                                sequence=sequence, native=native.astype(np.float32))
            print(f"    wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
