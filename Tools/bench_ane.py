#!/usr/bin/env python3
"""Benchmark the exported Genie 2 denoising step across Core ML compute units.

The number that matters for PhoneFold is **seconds per denoising step**, because a
trajectory is 1000 of them. The PyTorch baseline on this Mac's CPU is 142 s per 1000-step
sample at 76 residues, i.e. about 142 ms per step.

Figures produced here are Mac figures. They say nothing about iPhone performance and are
recorded as such: PLAN.md is explicit that Simulator and desktop numbers are meaningless for
ANE work, and on-device measurement is a human-verifiable gate.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
MODELS = HERE.parent / "Models"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", type=Path, default=MODELS / "Genie2Step_L64.mlpackage")
    ap.add_argument("--length", type=int, default=64)
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=3)
    args = ap.parse_args()

    import coremltools as ct
    if not args.model.exists():
        print(f"missing {args.model}", file=sys.stderr)
        return 2

    rng = np.random.default_rng(0)
    trans = rng.standard_normal((1, args.length, 3)).astype(np.float32)
    # A valid rotation batch, via QR of random matrices.
    a = rng.standard_normal((args.length, 3, 3))
    q, r = np.linalg.qr(a)
    q = q * np.sign(np.einsum("...ii->...i", r))[:, None, :]
    q[np.linalg.det(q) < 0] *= -1
    rots = q[None].astype(np.float32)
    timesteps = np.array([500], dtype=np.int32)
    feed = {"trans": trans, "rots": rots, "timesteps": timesteps}

    units = [("CPU only", ct.ComputeUnit.CPU_ONLY),
             ("CPU + GPU", ct.ComputeUnit.CPU_AND_GPU),
             ("CPU + ANE", ct.ComputeUnit.CPU_AND_NE),
             ("all", ct.ComputeUnit.ALL)]

    print(f"model: {args.model.name}, length {args.length}, "
          f"{args.iters} iterations after {args.warmup} warm-up")
    print(f"\n{'compute units':<14} {'load (s)':>9} {'ms/step':>10} {'sd':>7} "
          f"{'s per 1000 steps':>17}")
    print("-" * 62)

    results = {}
    for label, unit in units:
        try:
            t0 = time.time()
            model = ct.models.MLModel(str(args.model), compute_units=unit)
            load = time.time() - t0
            for _ in range(args.warmup):
                model.predict(feed)
            times = []
            for _ in range(args.iters):
                t0 = time.time()
                model.predict(feed)
                times.append(time.time() - t0)
            ms = np.array(times) * 1000
            print(f"{label:<14} {load:>9.1f} {ms.mean():>10.1f} {ms.std():>7.1f} "
                  f"{ms.mean():>16.0f}")
            results[label] = ms.mean()
        except Exception as exc:
            print(f"{label:<14} FAILED: {type(exc).__name__}: {str(exc)[:60]}")

    print("\nPyTorch CPU baseline: ~142 ms/step (142 s per 1000-step sample at 76 residues)")
    if results:
        best = min(results, key=results.get)
        print(f"Best here: {best} at {results[best]:.1f} ms/step "
              f"= {results[best]:.0f} s per 1000-step trajectory")
    print("\nThese are Mac figures and say nothing about iPhone or real ANE residency, "
          "which are human-verifiable gates.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
