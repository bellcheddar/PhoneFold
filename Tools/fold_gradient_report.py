#!/usr/bin/env python3
"""Does this trajectory show a protein folding?

`trajectory_report.py` answers "is there motion". This asks the harder question Marc put:
is there **a gradation from fully unfolded to fully folded with ordered secondary
structure**. Motion is necessary and not sufficient - Genie 2 moves 10.7 A and does it by
expanding from a blob, which is motion without folding.

Four things are measured per frame, and three summary judgements are made from them:

  Rg                  radius of gyration, and its ratio to the compact expectation
  helix/sheet/coil    CA-only P-SEA content, the same method the app itself uses
  CA-CA               virtual bond length: a frame outside 3.8 +- 0.3 A is not a polypeptide
  contacts            at the app's own 8 A, |i-j| >= 3 threshold

  direction           does Rg go down (collapse) or up (expansion)?
  monotonicity        fraction of steps moving the majority way; 1.0 is a clean gradient
  SS formed           ordered content at the end minus ordered content at the start

Usage:
    fold_gradient_report.py FILE [FILE ...]         .pftraj, or .npz with a 'ca' array
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import fold_metrics as fm
import pftraj


def load(path: Path) -> tuple[str, np.ndarray]:
    """Return (name, (F, N, 3) CA coordinates)."""
    if path.suffix == ".pftraj":
        meta, readouts = pftraj.read(path)
        ca = np.stack([r.backbone[:, 1 if r.backbone.shape[1] == 4 else 0, :]
                       for r in readouts])
        return meta["name"], ca
    if path.suffix == ".npz":
        d = np.load(path)
        return str(d.get("name", path.stem)), d["ca"]
    raise ValueError(f"{path}: expected .pftraj or .npz")


def per_frame(ca_traj: np.ndarray, stride: int = 1) -> list[dict]:
    rows = []
    final = ca_traj[-1]
    for k in range(0, len(ca_traj), stride):
        ca = ca_traj[k]
        m, s = fm.ca_ca(ca)
        sse = fm.sse_content(ca)
        rows.append({
            "frame": k,
            "rg": fm.radius_of_gyration(ca),
            "helix": sse["helix"], "sheet": sse["sheet"], "coil": sse["coil"],
            "ordered": sse["helix"] + sse["sheet"],
            "ca_ca_mean": m, "ca_ca_sd": s,
            "contacts": fm.contact_count(ca),
            "rmsd_to_final": fm.kabsch_rmsd(ca, final),
        })
    return rows


def report(path: Path, stride: int = 1, reference: np.ndarray | None = None) -> dict:
    name, traj = load(path)
    n = traj.shape[1]
    rows = per_frame(traj, stride)
    rg = [r["rg"] for r in rows]
    ordered = [r["ordered"] for r in rows]
    expected = fm.compact_expectation(n)

    print(f"\n=== {name}  ({n} residues, {len(traj)} frames, every {stride}) ===")
    print(f"{'frame':>7} {'Rg':>7} {'Rg/exp':>7} {'helix':>6} {'sheet':>6} "
          f"{'ord':>6} {'CA-CA':>13} {'contacts':>9} {'RMSDf':>7}")
    for r in rows:
        print(f"{r['frame']:>7} {r['rg']:>7.2f} {r['rg'] / expected:>7.2f} "
              f"{r['helix']:>6.2f} {r['sheet']:>6.2f} {r['ordered']:>6.2f} "
              f"{r['ca_ca_mean']:>6.2f}+-{r['ca_ca_sd']:<5.2f} "
              f"{r['contacts']:>9} {r['rmsd_to_final']:>7.2f}")

    summary = {
        "name": name, "residues": n, "frames": len(traj),
        "rg_first": rg[0], "rg_last": rg[-1], "rg_expected": expected,
        "rg_ratio_last": rg[-1] / expected,
        "direction": "collapse" if rg[-1] < rg[0] else "expansion",
        "rg_monotonicity": fm.monotonicity(rg),
        "rg_monotonicity_smoothed": fm.monotonicity(
            np.convolve(rg, np.ones(5) / 5, mode="valid")),
        "ordered_first": ordered[0], "ordered_last": ordered[-1],
        "ordered_gain": ordered[-1] - ordered[0],
        "ca_ca_valid_frames": sum(1 for r in rows if abs(r["ca_ca_mean"] - 3.8) < 0.3
                                  and r["ca_ca_sd"] < 0.3),
        "rmsd_first_to_last": rows[0]["rmsd_to_final"],
    }
    if reference is not None:
        summary["tm_first"] = fm.tm_score(traj[0], reference)
        summary["tm_last"] = fm.tm_score(traj[-1], reference)
        summary["rmsd_to_reference_last"] = fm.kabsch_rmsd(traj[-1], reference)

    print(f"\n  direction            {summary['direction']}  "
          f"(Rg {summary['rg_first']:.2f} -> {summary['rg_last']:.2f} A, "
          f"compact expectation {expected:.2f})")
    print(f"  Rg monotonicity      {summary['rg_monotonicity']:.2f} raw, "
          f"{summary['rg_monotonicity_smoothed']:.2f} over a 5-frame mean   "
          f"(1.00 = a clean gradient)")
    print(f"  ordered SS           {summary['ordered_first']:.2f} -> "
          f"{summary['ordered_last']:.2f}  (gain {summary['ordered_gain']:+.2f})")
    print(f"  polypeptide frames   {summary['ca_ca_valid_frames']} / {len(rows)}")
    print(f"  motion, first->last  {summary['rmsd_first_to_last']:.2f} A RMSD")
    if reference is not None:
        print(f"  vs reference         TM {summary['tm_first']:.3f} -> "
              f"{summary['tm_last']:.3f}, final RMSD "
              f"{summary['rmsd_to_reference_last']:.2f} A")
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("--stride", type=int, default=1)
    ap.add_argument("--reference", type=Path, default=None,
                    help=".pftraj whose final frame is the native reference")
    args = ap.parse_args()

    ref = None
    if args.reference is not None:
        _, rtraj = load(args.reference)
        ref = rtraj[-1]

    for f in args.files:
        report(f, args.stride, ref)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
