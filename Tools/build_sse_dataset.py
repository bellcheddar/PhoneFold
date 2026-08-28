#!/usr/bin/env python3
"""Build the training set for the CA-only secondary structure classifier.

Fetches X-ray PDB entries, runs mkdssp, and stores CA-only features with DSSP labels.

**The ten evaluation entries are excluded here, by PDB id.** A gate measured on training data
is not a gate, so the exclusion is enforced in this script rather than left to discipline
later, and the exclusion list is written into the output so it can be audited.

X-ray only: mkdssp 4.4.5 segfaults on several NMR entries (2A3D, 1VII, 1L2Y and 2GB1 were all
hit), so restricting the query avoids losing a chunk of the set to a crash.
"""

from __future__ import annotations

import json
import subprocess
import sys
import urllib.request
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import sse_features as F                                          # noqa: E402

CACHE = HERE / ".cache/pdb_train"
OUT = HERE / ".cache/sse_dataset.npz"
EVAL_FIXTURES = HERE.parent / "PhoneFoldKit/Tests/FoldGeometryTests/Fixtures/dssp_reference.json"
MKDSSP = "/Applications/ccp4-9/bin/mkdssp"
SEARCH = "https://search.rcsb.org/rcsbsearch/v2/query"

SS8_TO_SS3 = {"H": 0, "G": 0, "I": 0, "E": 1, "B": 1}     # else coil (2)
CLASS_NAMES = ["helix", "sheet", "coil"]


def evaluation_entries() -> set[str]:
    data = json.loads(EVAL_FIXTURES.read_text())
    return {e["pdb"].upper() for e in data["structures"]}


def search_entries(limit: int) -> list[str]:
    """Non-redundant-ish X-ray entries at decent resolution."""
    query = {
        "query": {"type": "group", "logical_operator": "and", "nodes": [
            {"type": "terminal", "service": "text", "parameters": {
                "attribute": "exptl.method", "operator": "exact_match",
                "value": "X-RAY DIFFRACTION"}},
            {"type": "terminal", "service": "text", "parameters": {
                "attribute": "rcsb_entry_info.resolution_combined", "operator": "less",
                "value": 2.0}},
            {"type": "terminal", "service": "text", "parameters": {
                "attribute": "rcsb_entry_info.polymer_entity_count_protein",
                "operator": "equals", "value": 1}},
            {"type": "terminal", "service": "text", "parameters": {
                "attribute": "rcsb_entry_info.deposited_polymer_monomer_count",
                "operator": "range", "value": {"from": 60, "to": 300}}},
        ]},
        "return_type": "entry",
        "request_options": {
            "paginate": {"start": 0, "rows": limit},
            "results_content_type": ["experimental"],
            "sort": [{"sort_by": "rcsb_accession_info.initial_release_date",
                      "direction": "desc"}],
        },
    }
    req = urllib.request.Request(
        SEARCH, data=json.dumps(query).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "PhoneFold/0.1"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return [r["identifier"] for r in json.loads(resp.read())["result_set"]]


def dssp_for(pdb_id: str):
    """Return (CA coordinates, 8-state string) for the first protein chain."""
    CACHE.mkdir(parents=True, exist_ok=True)
    pdb_path = CACHE / f"{pdb_id}.pdb"
    if not pdb_path.exists():
        url = f"https://files.rcsb.org/download/{pdb_id}.pdb"
        req = urllib.request.Request(url, headers={"User-Agent": "PhoneFold/0.1"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            pdb_path.write_bytes(resp.read())

    out_path = CACHE / f"{pdb_id}.dssp"
    r = subprocess.run([MKDSSP, "--output-format", "dssp", str(pdb_path), str(out_path)],
                       capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"mkdssp returned {r.returncode}")

    lines = out_path.read_text().splitlines()
    header = next(i for i, l in enumerate(lines) if l.startswith("  #  RESIDUE"))
    x0 = lines[header].index("X-CA")
    by_chain: dict[str, list] = {}
    for line in lines[header + 1:]:
        if len(line) < 14 or line[13] == "!":
            continue
        parts = line[x0 - 1:].split()
        if len(parts) < 3:
            continue
        chain = line[11]
        by_chain.setdefault(chain, []).append(
            ([float(parts[0]), float(parts[1]), float(parts[2])],
             line[16] if line[16] != " " else "-"))
    if not by_chain:
        raise RuntimeError("no chains parsed")
    chain = max(by_chain, key=lambda c: len(by_chain[c]))
    records = by_chain[chain]
    ca = np.asarray([r[0] for r in records], dtype="f4")
    ss8 = "".join(r[1] for r in records)
    return ca, ss8


def main() -> int:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 220
    excluded = evaluation_entries()
    print(f"excluded evaluation entries: {sorted(excluded)}")

    ids = [i for i in search_entries(limit) if i.upper() not in excluded]
    print(f"{len(ids)} candidate entries after exclusion")

    X, y, groups = [], [], []
    used, failed = [], 0
    for k, pdb_id in enumerate(ids):
        try:
            ca, ss8 = dssp_for(pdb_id)
        except Exception as exc:                       # noqa: BLE001
            failed += 1
            continue
        if len(ca) < 40:
            continue
        feats = F.featurise(ca)
        labels = np.asarray([SS8_TO_SS3.get(c, 2) for c in ss8], dtype="i8")
        X.append(feats)
        y.append(labels)
        groups.append(np.full(len(labels), len(used)))
        used.append(pdb_id)
        if len(used) % 25 == 0:
            print(f"  {len(used)} chains, {sum(len(a) for a in y)} residues", flush=True)

    if not used:
        print("no usable chains", file=sys.stderr)
        return 1

    X = np.concatenate(X); y = np.concatenate(y); groups = np.concatenate(groups)
    counts = np.bincount(y, minlength=3)
    print(f"\n{len(used)} chains, {len(y)} residues ({failed} entries failed mkdssp)")
    print(f"  helix {counts[0]} ({counts[0]/len(y)*100:.0f}%), "
          f"sheet {counts[1]} ({counts[1]/len(y)*100:.0f}%), "
          f"coil {counts[2]} ({counts[2]/len(y)*100:.0f}%)")
    np.savez_compressed(OUT, X=X, y=y, groups=groups,
                        chains=np.array(used), excluded=np.array(sorted(excluded)))
    print(f"-> {OUT} ({OUT.stat().st_size/1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
