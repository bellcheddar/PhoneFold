#!/usr/bin/env python3
"""Resolve the twelve bundled proteins in proteins.json to sequences, from their accessions.

Sequences are never pasted into this repository. They are fetched from RCSB or UniProt and
checked against an expected length, because a plausible-but-wrong sequence is the easiest
way to silently ship the wrong protein: a catalytic-knockout construct named as the wild
type, a dead accession returning an empty body rather than a 404, or an ungapped count that
disagrees with the numbering everyone quotes.

Network hosts used: data.rcsb.org and rest.uniprot.org. Results are cached under
Tools/.cache/sequences so a regeneration does not re-hit either service.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache" / "sequences"
SPEC = HERE / "proteins.json"

RCSB_ENTITY = "https://data.rcsb.org/rest/v1/core/polymer_entity/{pdb}/{entity}"
UNIPROT_FASTA = "https://rest.uniprot.org/uniprotkb/{acc}.fasta"

STANDARD = set("ACDEFGHIKLMNPQRSTVWY")


class FetchError(RuntimeError):
    pass


def _get(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "PhoneFold/0.1 (marc@marcdeller.com)"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8")
    except Exception as exc:  # noqa: BLE001 - want the URL in the message
        raise FetchError(f"{url}: {exc}") from exc
    # A dead accession can return 200 with an empty body rather than a 404. Treat that as
    # the failure it is instead of producing a zero-length sequence.
    if not body.strip():
        raise FetchError(f"{url}: empty response body (dead or withdrawn accession?)")
    return body


def fetch_pdb_entity(pdb: str, entity: str) -> tuple[str, str]:
    doc = json.loads(_get(RCSB_ENTITY.format(pdb=pdb, entity=entity)))
    poly = doc.get("entity_poly") or {}
    # ..._can is the canonical one-letter sequence with modified residues mapped back to
    # their parent. The non-canonical field carries (MSE) style parentheses and would give
    # a wrong length.
    seq = (poly.get("pdbx_seq_one_letter_code_can") or "").replace("\n", "").strip().upper()
    if not seq:
        raise FetchError(f"{pdb} entity {entity}: no canonical one-letter sequence in the response")
    names = (doc.get("rcsb_polymer_entity") or {}).get("pdbx_description") or pdb
    return seq, names


def fetch_uniprot(accession: str) -> tuple[str, str]:
    fasta = _get(UNIPROT_FASTA.format(acc=accession))
    lines = fasta.strip().splitlines()
    if not lines[0].startswith(">"):
        raise FetchError(f"{accession}: response is not FASTA")
    seq = "".join(l.strip() for l in lines[1:]).upper()
    if not seq:
        raise FetchError(f"{accession}: FASTA header with no sequence")
    return seq, lines[0][1:]


def resolve(spec: dict, *, refresh: bool = False) -> dict:
    CACHE.mkdir(parents=True, exist_ok=True)
    cache_file = CACHE / f"{spec['id']}.json"
    if cache_file.exists() and not refresh:
        return json.loads(cache_file.read_text())

    if spec["source"] == "pdb":
        full, description = fetch_pdb_entity(spec["pdb"], spec["entity"])
        origin = f"RCSB polymer entity {spec['pdb']}_{spec['entity']}"
    elif spec["source"] == "uniprot":
        full, description = fetch_uniprot(spec["accession"])
        origin = f"UniProt {spec['accession']}"
    else:
        raise FetchError(f"{spec['id']}: unknown source {spec['source']!r}")

    full_length = len(full)
    if rng := spec.get("range"):
        lo, hi = rng
        if hi > full_length:
            raise FetchError(
                f"{spec['id']}: range {lo}-{hi} exceeds the {full_length}-residue "
                f"sequence from {origin}")
        seq = full[lo - 1 : hi]
        origin += f", residues {lo}-{hi} of {full_length}"
    else:
        seq = full

    # Hard failure, not a warning. This is the check that catches the wrong entity, a
    # renumbered construct, or an entry that has changed under us.
    expected = spec.get("expect_length")
    if expected is not None and len(seq) != expected:
        raise FetchError(
            f"{spec['id']}: got {len(seq)} residues from {origin}, expected {expected}. "
            f"Check the accession, the entity id and the range before changing the "
            f"expectation - the expectation is the safety net, not the nuisance.")

    nonstandard = sorted(set(seq) - STANDARD)
    if nonstandard:
        print(f"  note: {spec['id']} contains non-standard codes {nonstandard}, "
              f"which fold as X", file=sys.stderr)

    record = {
        "id": spec["id"], "name": spec["name"], "sequence": seq,
        "length": len(seq), "origin": origin, "description": description,
        "organism": spec.get("organism"),
        "accession": spec.get("accession") or f"{spec.get('pdb')}_{spec.get('entity')}",
        "reference_pdb": spec.get("reference_pdb"),
        "reference_note": spec.get("reference_note"),
        "listening_note": spec.get("listening_note"),
    }
    cache_file.write_text(json.dumps(record, indent=2))
    return record


def load_all(refresh: bool = False) -> list[dict]:
    specs = json.loads(SPEC.read_text())["proteins"]
    out, failures = [], []
    for spec in specs:
        try:
            rec = resolve(spec, refresh=refresh)
            print(f"  {rec['id']:<18} {rec['length']:>4} aa   {rec['origin']}")
            out.append(rec)
        except FetchError as exc:
            print(f"  {spec['id']:<18} FAILED: {exc}", file=sys.stderr)
            failures.append(spec["id"])
    if failures:
        raise SystemExit(f"\n{len(failures)} sequence(s) could not be resolved: {failures}")
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--refresh", action="store_true", help="ignore the cache and refetch")
    args = ap.parse_args()
    print("Resolving bundled protein sequences from their accessions:")
    records = load_all(refresh=args.refresh)
    print(f"\n{len(records)} sequences resolved, "
          f"{sum(r['length'] for r in records)} residues total")
