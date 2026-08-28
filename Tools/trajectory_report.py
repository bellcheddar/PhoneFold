#!/usr/bin/env python3
"""Quantify how much a .pftraj actually moves.

The question Phase 0 has to answer is not "are the coordinates correct" but "is there a
trajectory to watch". These are different questions and a model can pass the first while
failing the second, which is exactly what ESMFold does.

Reports, per trajectory: RMSD of each frame to the final frame after Kabsch superposition
(the honest measure of how much motion a viewer would see), radius of gyration, mean pLDDT,
and the CA-CA virtual bond length, which is the tell for whether a frame is a real
polypeptide at all.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import pftraj


def kabsch_rmsd(P: np.ndarray, Q: np.ndarray) -> float:
    Pc, Qc = P - P.mean(0), Q - Q.mean(0)
    V, _, Wt = np.linalg.svd(Pc.T @ Qc)
    D = np.diag([1.0, 1.0, np.sign(np.linalg.det(V @ Wt))])
    return float(np.sqrt((((Pc @ (V @ D @ Wt)) - Qc) ** 2).sum(1).mean()))


def radius_of_gyration(ca: np.ndarray) -> float:
    return float(np.sqrt(((ca - ca.mean(0)) ** 2).sum(1).mean()))


def summarise(path: Path) -> dict:
    meta, readouts = pftraj.read(path)
    final = readouts[-1].backbone[:, 1, :]
    rows = []
    for ro in readouts:
        ca = ro.backbone[:, 1, :]
        bonds = np.linalg.norm(np.diff(ca, axis=0), axis=1)
        rows.append({
            "recycle": ro.recycle, "block": ro.block_index,
            "rmsd_to_final": kabsch_rmsd(ca, final),
            "rg": radius_of_gyration(ca),
            "plddt": float(ro.plddt.mean()),
            "ca_ca_mean": float(bonds.mean()), "ca_ca_sd": float(bonds.std()),
        })
    rmsds = [r["rmsd_to_final"] for r in rows]
    rgs = [r["rg"] for r in rows]
    plddts = [r["plddt"] for r in rows]
    # A frame is a real polypeptide only if its virtual bonds are near 3.8 A with a tight
    # spread. 0.30 A of scatter is generous; a broken chain is 2-6 A of scatter.
    valid = [r for r in rows if abs(r["ca_ca_mean"] - 3.8) < 0.3 and r["ca_ca_sd"] < 0.3]
    return {
        "name": meta["name"], "residues": len(meta["sequence"]), "frames": len(rows),
        "max_rmsd_to_final": max(rmsds), "rg_min": min(rgs), "rg_max": max(rgs),
        "plddt_min": min(plddts), "plddt_max": max(plddts),
        "valid_geometry_frames": len(valid), "rows": rows,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument("--verbose", action="store_true", help="print every frame")
    args = ap.parse_args()

    print(f"{'protein':<26} {'aa':>4} {'frames':>6} {'valid':>6} {'max RMSD':>9} "
          f"{'Rg range':>14} {'pLDDT range':>13}")
    print("-" * 90)
    for p in args.paths:
        s = summarise(p)
        print(f"{s['name'][:26]:<26} {s['residues']:>4} {s['frames']:>6} "
              f"{s['valid_geometry_frames']:>6} {s['max_rmsd_to_final']:>8.2f}A "
              f"{s['rg_min']:>6.1f}-{s['rg_max']:<7.1f} "
              f"{s['plddt_min']:>5.1f}-{s['plddt_max']:<7.1f}")
        if args.verbose:
            for r in s["rows"]:
                print(f"    rec{r['recycle']} blk{r['block']:>5}  "
                      f"rmsd {r['rmsd_to_final']:>6.2f}  rg {r['rg']:>6.2f}  "
                      f"pLDDT {r['plddt']:>5.1f}  CA-CA {r['ca_ca_mean']:>5.2f}"
                      f"+-{r['ca_ca_sd']:<5.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
