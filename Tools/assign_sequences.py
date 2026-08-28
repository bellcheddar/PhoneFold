#!/usr/bin/env python3
"""Assign a sequence to a generated backbone by ProteinMPNN inverse folding.

foldingDiff emits a backbone with no residue identities, but the Phase 3 score needs them:
hydrophobicity of both contact partners decides the bass notes, R/K/D/E drive the Fantasy
profile's octave shifts, and the Phase 2 hydrophobicity colour mode needs them too. A
generated trajectory therefore carries `X` for every residue until this runs.

ProteinMPNN (Dauparas et al., Science 2022, MIT licence) is 1.66 M parameters in a 6.7 MB
checkpoint, which is negligible beside foldingDiff's 57.9 MB, and is the same tool the
foldingDiff paper uses to assess designability.

The sequence is designed **once, from the final backbone**, and applied to the whole
trajectory. Designing per frame would make the residue identities flicker, and the sequence
of a protein does not change while it folds.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

import pftraj

HERE = Path(__file__).resolve().parent
MPNN = HERE / ".cache/proteinmpnn-src"

BACKBONE_ATOMS = ("N", "CA", "C", "O")


def write_backbone_pdb(backbone: np.ndarray, path: Path) -> Path:
    """(L, 4, 3) -> a minimal backbone-only PDB that ProteinMPNN can parse.

    Residues are named GLY because the identities are genuinely unknown at this point.
    ProteinMPNN designs from backbone geometry, so the placeholder does not bias the result.
    """
    # Fixed-column PDB. Getting these columns wrong is silent: ProteinMPNN's parser simply
    # finds no chain and fails later with "need at least one array to concatenate".
    #   1-6 record, 7-11 serial, 13-16 atom, 17 altLoc, 18-20 resName, 22 chain,
    #   23-26 resSeq, 31-38 x, 39-46 y, 47-54 z, 55-60 occ, 61-66 B, 77-78 element
    lines, serial = [], 1
    for i, res in enumerate(backbone, start=1):
        for name, xyz in zip(BACKBONE_ATOMS, res):
            lines.append(
                f"ATOM  {serial:>5}  {name:<3}"          # 1-16
                f" GLY A{i:>4}    "                       # 17-30
                f"{xyz[0]:>8.3f}{xyz[1]:>8.3f}{xyz[2]:>8.3f}"   # 31-54
                f"  1.00  0.00          {name[0]:>2}")    # 55-78
            serial += 1
    lines.append("TER")
    lines.append("END")
    path.write_text("\n".join(lines) + "\n")
    return path


def design(backbone: np.ndarray, *, temperature: float, seed: int) -> str:
    """Design one sequence for a backbone. `seed` must be non-zero: see main()."""
    if seed == 0:
        raise ValueError("seed 0 means 'random' to ProteinMPNN; pass a non-zero seed")
    if not MPNN.exists():
        raise SystemExit(f"ProteinMPNN not found at {MPNN}. Clone it there first.")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        pdb = write_backbone_pdb(backbone, tmp / "backbone.pdb")
        out = tmp / "out"
        cmd = [sys.executable, str(MPNN / "protein_mpnn_run.py"),
               "--pdb_path", str(pdb), "--out_folder", str(out),
               "--num_seq_per_target", "1", "--sampling_temp", str(temperature),
               "--seed", str(seed), "--batch_size", "1"]
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(MPNN))
        if proc.returncode != 0:
            raise SystemExit(f"ProteinMPNN failed:\n{proc.stdout}\n{proc.stderr}")
        fastas = list((out / "seqs").glob("*.fa"))
        if not fastas:
            raise SystemExit(f"ProteinMPNN produced no sequences:\n{proc.stdout}")
        # The FASTA holds the native (poly-G placeholder) first, then the designs.
        records, header, seq = [], None, []
        for line in fastas[0].read_text().splitlines():
            if line.startswith(">"):
                if header is not None:
                    records.append((header, "".join(seq)))
                header, seq = line, []
            elif line.strip():
                seq.append(line.strip())
        if header is not None:
            records.append((header, "".join(seq)))
        if len(records) < 2:
            raise SystemExit(f"expected a design in {fastas[0]}, got {len(records)} records")
        return records[1][1].upper()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trajectory", type=Path)
    ap.add_argument("--temperature", type=float, default=0.1,
                    help="ProteinMPNN sampling temperature; 0.1 is the usual design default")
    # ProteinMPNN's own argument parser does `if args.seed:` and picks a RANDOM seed when
    # it is falsy, so --seed 0 means "not seeded" rather than "seed zero". The flag looks
    # deterministic and is not. Phase 3 requires the same protein to yield the same piece,
    # so 0 is refused here rather than silently producing a different sequence each run.
    ap.add_argument("--seed", type=int, default=1,
                    help="ProteinMPNN random seed; must be non-zero, because 0 means "
                         "'pick a random seed' in ProteinMPNN's own argument handling")
    args = ap.parse_args()
    if args.seed == 0:
        print("--seed 0 means 'random seed' to ProteinMPNN, not 'seed zero'. "
              "Pass a non-zero seed so the design is reproducible.", file=sys.stderr)
        return 2

    meta, readouts = pftraj.read(args.trajectory)
    if meta["provenance"] != pftraj.PROVENANCE_FOLDINGDIFF:
        print(f"{args.trajectory.name} has provenance {meta['provenance']!r}; inverse "
              f"folding only applies to generated backbones", file=sys.stderr)
        return 2
    if set(meta["sequence"]) != {"X"}:
        print(f"{args.trajectory.name} already carries a sequence; refusing to overwrite it",
              file=sys.stderr)
        return 2

    final = readouts[-1].backbone
    print(f"designing a sequence for the final backbone ({len(final)} residues, "
          f"T={args.temperature}, seed {args.seed}) ...")
    sequence = design(final, temperature=args.temperature, seed=args.seed)
    if len(sequence) != len(meta["sequence"]):
        raise SystemExit(f"ProteinMPNN returned {len(sequence)} residues, "
                         f"expected {len(meta['sequence'])}")
    print(f"  {sequence}")

    composition = {a: sequence.count(a) for a in sorted(set(sequence))}
    print(f"  composition: {composition}")

    meta["sequence"] = sequence
    meta["notes"] = (meta.get("notes") or "") + (
        f" Sequence designed by ProteinMPNN v_48_020 (1.66M params) from the final "
        f"backbone, T={args.temperature}, seed {args.seed}, applied to every frame.")
    metadata = pftraj.TrajectoryMetadata(**{
        k: meta.get(k) for k in pftraj.TrajectoryMetadata.__dataclass_fields__})
    path = pftraj.write(args.trajectory, metadata, readouts)
    print(f"\nrewrote {path} ({path.stat().st_size/1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
