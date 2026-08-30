#!/usr/bin/env python3
"""What a structure-based fold costs, and whether it fits inside a 60 fps frame.

Reads the `.npz` runs written by `go_model_run.py` and turns them into the only numbers
that decide on-device viability:

  us/step             measured, from the run's own wall clock
  steps to fold       first frame at Q >= 0.9, so post-folding equilibrium is not counted
  compute seconds     us/step x steps to fold
  ms per frame        that compute spread over a playback of the given length at 60 fps

The renderer costs 1.65 ms of the 16.7 ms frame at 314 residues (METRICS.md), so the
engine's share has to stay under about 15 ms for playback to be produced live rather than
buffered ahead.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import fold_metrics as fm


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("--playback", type=float, nargs="+", default=[30.0, 60.0],
                    help="playback lengths in seconds")
    ap.add_argument("--fps", type=float, default=60.0)
    args = ap.parse_args()

    head = (f"{'protein':<26}{'aa':>5}{'us/step':>9}{'steps to fold':>15}"
            f"{'compute s':>11}{'Rg first':>10}{'Rg last':>9}{'RMSD':>7}")
    for p in args.playback:
        head += f"{f'ms/f @{p:.0f}s':>12}"
    print(head)
    for f in sorted(args.files):
        d = np.load(f)
        n = d["ca"].shape[1]
        us = 1e6 * float(d["wall_seconds"]) / int(d["steps"])
        q = d["q"]
        stride = int(d["stride"])
        folded = int(np.argmax(q >= 0.9)) if (q >= 0.9).any() else len(q) - 1
        steps = (folded + 1) * stride
        compute = us * steps / 1e6
        rmsd = float(d["rmsd"][-1])
        row = (f"{str(d['name'])[:25]:<26}{n:>5}{us:>9.1f}{steps:>15,}"
               f"{compute:>11.1f}{float(d['rg'][0]):>10.1f}{float(d['rg'][-1]):>9.1f}"
               f"{rmsd:>7.1f}")
        for p in args.playback:
            row += f"{1000 * compute / (p * args.fps):>12.1f}"
        print(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
