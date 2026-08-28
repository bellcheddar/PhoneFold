#!/usr/bin/env python3
"""Build the DSSP reference fixtures for the Phase 1 P-SEA agreement gate.

PLAN.md Phase 1 requires P-SEA to agree with a DSSP reference on 10 PDB structures at 85% or
better per residue, using CA positions only.

The reference is **mkdssp 4.4.5** (the real DSSP), read from its own output so that the CA
coordinates and the secondary structure states are guaranteed to be in register: the DSSP
file carries both.

**Biotite's `annotate_sse` is deliberately not used**: it is itself a P-SEA implementation,
so it would compare the method against itself and prove nothing.

DSSP's eight states are reduced with the conventional mapping, **H, G and I to helix; E and B
to sheet; everything else to coil**. That mapping matters. `pydssp`, tried first, detects only
H and E, so it scores 3-10 helices, pi-helices and beta-bridges as coil and penalises P-SEA
for finding them correctly. Against pydssp a correct P-SEA reaches only 77.8%; the same
implementation is measured against real DSSP here.

The ten structures deliberately span all-alpha, all-beta and mixed folds, plus one very small
peptide, because a method that only works on helices would otherwise pass.
"""

from __future__ import annotations

import json
from pathlib import Path

import subprocess

import numpy as np
import biotite.database.rcsb as rcsb

MKDSSP = "/Applications/ccp4-9/bin/mkdssp"

# The conventional DSSP 8-state to 3-state reduction.
SS8_TO_SS3 = {"H": "H", "G": "H", "I": "H",
              "E": "E", "B": "E",
              "T": "C", "S": "C", "P": "C", " ": "C", "-": "C"}

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache/pdb"
OUT = HERE.parent / "PhoneFoldKit/Tests/FoldGeometryTests/Fixtures/dssp_reference.json"

STRUCTURES = [
    ("1UBQ", "A", "Ubiquitin, beta-grasp, mixed alpha/beta"),
    ("1MBN", "A", "Myoglobin, all-alpha"),
    ("1LYZ", "A", "Hen egg white lysozyme, alpha plus beta"),
    ("2A3D", "A", "Alpha-3D, de novo three-helix bundle, all-alpha"),
    ("1VII", "A", "Villin headpiece HP36, all-alpha"),
    ("1PGB", "A", "Protein G B1 domain, alpha/beta"),
    ("1EMA", "A", "Green fluorescent protein, all-beta barrel"),
    ("1CRN", "A", "Crambin, small mixed"),
    ("1SHG", "A", "Alpha-spectrin SH3 domain, all-beta"),
    ("1L2Y", "A", "Trp-cage TC5b, minimal"),
    # Spares, used only if one of the above fails. mkdssp 4.4.5 segfaults on some entries
    # (2A3D, a de novo NMR bundle, is one), so the set is built from whatever works until it
    # reaches TARGET_COUNT rather than assuming every fetch succeeds.
    ("1BDD", "A", "Protein A B domain, all-alpha"),
    ("256B", "A", "Cytochrome b562, four-helix bundle, all-alpha"),
    ("2GB1", "A", "Protein G B1 domain, NMR, alpha/beta"),
    ("1TEN", "A", "Tenascin fibronectin type III, all-beta"),
]

TARGET_COUNT = 10

def run_dssp(pdb_id: str, chain: str):
    """Run mkdssp and return (CA coordinates, 3-state string, 8-state string).

    Both come out of the same DSSP record, so they cannot fall out of register. A residue
    DSSP could not place (chain break, marked "!") is skipped.
    """
    pdb_path = Path(rcsb.fetch(pdb_id, "pdb", CACHE))
    out_path = CACHE / f"{pdb_id}.dssp"

    def attempt(source: Path) -> bool:
        try:
            subprocess.run([MKDSSP, "--output-format", "dssp", str(source), str(out_path)],
                           check=True, capture_output=True)
            return True
        except subprocess.CalledProcessError:
            return False

    if not attempt(pdb_path):
        # mkdssp 4.4.5 segfaults on some multi-model NMR entries. Feed it model 1 alone.
        single = CACHE / f"{pdb_id}_model1.pdb"
        kept, in_model = [], True
        for line in pdb_path.read_text().splitlines():
            if line.startswith("MODEL"):
                in_model = line.split()[1] == "1"
                continue
            if line.startswith("ENDMDL"):
                in_model = False
                continue
            if in_model:
                kept.append(line)
        single.write_text("\n".join(kept) + "\nEND\n")
        if not attempt(single):
            raise RuntimeError(f"mkdssp failed on {pdb_id} even with a single model")

    lines = out_path.read_text().splitlines()
    header = next(i for i, l in enumerate(lines) if l.startswith("  #  RESIDUE"))
    x0 = lines[header].index("X-CA")

    ca, ss8 = [], []
    for line in lines[header + 1:]:
        # The three CA coordinates are the last fields on the line. Slicing by fixed width
        # here is wrong: the final field is narrower than the others, so a width-based
        # bounds check rejects every line (136 characters against an expected 139).
        if len(line) < 14 or line[13] == "!" or line[11] != chain:
            continue
        parts = line[x0 - 1:].split()
        if len(parts) < 3:
            continue
        ss8.append(line[16] if line[16] != " " else "-")
        ca.append([float(parts[0]), float(parts[1]), float(parts[2])])
    ss3 = "".join(SS8_TO_SS3.get(c, "C") for c in ss8)
    return np.asarray(ca, dtype="f4"), ss3, "".join(ss8)


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    entries = []
    print(f"{'pdb':>6} {'residues':>9} {'H':>5} {'E':>5} {'C':>5}  description")
    print("-" * 78)
    for pdb_id, chain, description in STRUCTURES:
        if len(entries) >= TARGET_COUNT:
            break
        try:
            ca, ss3, ss8 = run_dssp(pdb_id, chain)
        except (RuntimeError, Exception) as exc:      # noqa: BLE001 - report and move on
            print(f"{pdb_id:>6}  SKIPPED: {type(exc).__name__}: {str(exc)[:60]}")
            continue
        if len(ca) < 10:
            print(f"{pdb_id:>6}  SKIPPED: only {len(ca)} residues")
            continue
        counts = {c: ss3.count(c) for c in "HEC"}
        print(f"{pdb_id:>6} {len(ca):>9} {counts['H']:>5} {counts['E']:>5} "
              f"{counts['C']:>5}  {description}")
        entries.append({
            "pdb": pdb_id, "chain": chain, "description": description,
            "residueCount": len(ca),
            # CA only: P-SEA is a CA-only method and must not see the rest.
            "ca": [[round(float(v), 3) for v in atom] for atom in ca],
            "dssp": ss3,
            "dssp8": ss8,
        })

    payload = {
        "note": ("DSSP computed with mkdssp 4.4.5. CA coordinates are read from the same "
                 "DSSP records as the states, so they cannot fall out of register. Reduced "
                 "with the conventional mapping H/G/I -> H, E/B -> E, rest -> C. Biotite's "
                 "annotate_sse is deliberately NOT used: it is itself a P-SEA implementation "
                 "and would compare the method against itself."),
        "states": "H helix, E sheet, C coil; dssp8 keeps the original eight states",
        "structures": entries,
    }
    OUT.write_text(json.dumps(payload, indent=1) + "\n")
    total = sum(e["residueCount"] for e in entries)
    print(f"\n{len(entries)} structures, {total} residues -> {OUT.name} "
          f"({OUT.stat().st_size/1000:.0f} kB)")
    if len(entries) < TARGET_COUNT:
        print(f"WARNING: only {len(entries)} of {TARGET_COUNT} structures were usable",
              file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
