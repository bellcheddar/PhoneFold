#!/usr/bin/env python3
"""Generate the bundled .pftraj sample trajectories with real ESMFold inference.

PLAN.md Phase 0, fallback ladder item 4, built first so that Phases 1 to 5 are never
blocked on the Core ML export.

## What "a trajectory" means here, precisely

ESMFold's folding trunk runs 48 triangular-attention blocks per recycle and then invokes the
structure module **once**, at the end of the recycle. Unpatched, a 4-recycle fold therefore
yields 4 sets of coordinates, which is not a trajectory.

This script patches the trunk so the **real structure module** runs every `blocks_per_readout`
blocks on the representation as it stands at that point. Every coordinate in the output is
therefore a genuine model prediction: it is the answer to "what structure does the structure
module read out of the trunk state after block k", which is exactly the quantity PLAN.md
Phase 0 asks for. Nothing is interpolated, smoothed or synthesised here. Interpolation to
60 fps is FoldGeometry's job at playback time, and is flagged as such per frame.

pLDDT is computed the same way the model computes it for its own output: the lddt_head
applied to the structure module's states, so the confidence shown alongside a readout is the
model's confidence in *that* readout, not in the final one.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch

import pftraj
from fetch_sequences import load_all

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE.parent / "Apps/Shared/Resources/Trajectories"
MODEL_ID = "facebook/esmfold_v1"

# atom14 packs backbone atoms first, in this order, for every standard residue.
BACKBONE_ATOM14_INDICES = [0, 1, 2, 3]  # N, CA, C, O

# atom37 ordering begins N, CA, C, CB, O. Per-residue pLDDT is read at the CA.
CA_ATOM37_INDEX = 1


def _patched_trunk_forward(trunk, seq_feats, pair_feats, true_aa, residx, mask, no_recycles):
    """EsmFoldingTrunk.forward with a coordinate readout every `trunk._pf_every` blocks.

    Structurally identical to the stock implementation (transformers 4.57.1) apart from the
    readout hook: same recycling, same normalisation, same distogram binning. If the upstream
    forward changes, this must be re-derived rather than patched blindly.
    """
    from transformers.models.esm.modeling_esmfold import EsmFoldingTrunk, categorical_lddt

    device = seq_feats.device
    s_s_0, s_z_0 = seq_feats, pair_feats
    if no_recycles is None:
        no_recycles = trunk.config.max_recycles
    else:
        if no_recycles < 0:
            raise ValueError("Number of recycles must not be negative.")
        no_recycles += 1

    every = trunk._pf_every
    sink = trunk._pf_sink
    parent = trunk._pf_parent

    def read_out(s, z, recycle_idx, block_idx):
        """Run the real structure module and lddt head on the current trunk state.

        Emits one readout per structure-module IPA layer when `trunk._pf_ipa_layers` is set,
        otherwise only the final layer. See the module docstring for why that matters.
        """
        structure = trunk.structure_module(
            {"single": trunk.trunk2sm_s(s), "pair": trunk.trunk2sm_z(z)}, true_aa, mask.float())
        positions = structure["positions"]                          # (n_ipa, B, L, 14, 3)
        states = structure["states"]                                # (n_ipa, B, L, C)

        # The lddt head is applied per IPA layer, exactly as the model applies it to its own
        # final layer, so each frame carries the model's confidence in *that* frame.
        lddt = parent.lddt_head(states).reshape(states.shape[0], 1, states.shape[-2], -1,
                                                parent.lddt_bins)

        layers = range(positions.shape[0]) if trunk._pf_ipa_layers else [positions.shape[0] - 1]
        for layer in layers:
            backbone = positions[layer, 0][:, BACKBONE_ATOM14_INDICES, :]   # (L, 4, 3)
            plddt = categorical_lddt(lddt[layer], bins=parent.lddt_bins)    # (B, L, 37)
            # Per-residue pLDDT is defined at the CA, as in AlphaFold. Averaging over all 37
            # atom slots silently includes the ~20 that do not exist for a given residue and
            # depresses the value by roughly 13 points: on ubiquitin, 77.4 instead of 90.5.
            # Both look like plausible pLDDTs, which is exactly why this is pinned by a test.
            per_residue = plddt[0][:, CA_ATOM37_INDEX] * 100.0               # (L,) 0..100
            sink.append(pftraj.Readout(
                recycle=recycle_idx,
                # blockIndex encodes where in the model the frame came from: the trunk block
                # in the high digits and the IPA layer in the low ones, so the app can mark
                # recycle boundaries and refinement steps distinctly.
                block_index=block_idx * 100 + layer,
                backbone=backbone.detach().float().cpu().numpy().astype("f4"),
                plddt=per_residue.detach().float().cpu().numpy().astype("f4")))
        return structure

    s_s, s_z = s_s_0, s_z_0
    recycle_s = torch.zeros_like(s_s)
    recycle_z = torch.zeros_like(s_z)
    recycle_bins = torch.zeros(*s_z.shape[:-1], device=device, dtype=torch.int64)
    structure = None

    for recycle_idx in range(no_recycles):
        with torch.no_grad():
            recycle_s = trunk.recycle_s_norm(recycle_s.detach()).to(device)
            recycle_z = trunk.recycle_z_norm(recycle_z.detach()).to(device)
            recycle_z = recycle_z + trunk.recycle_disto(recycle_bins.detach()).to(device)

            s = s_s_0 + recycle_s
            z = s_z_0 + recycle_z
            z = z + trunk.pairwise_positional_embedding(residx, mask=mask)

            for block_idx, block in enumerate(trunk.blocks):
                s, z = block(s, z, mask=mask, residue_index=residx,
                             chunk_size=trunk.chunk_size)
                # Readout after every `every` blocks, and always after the last block so a
                # recycle always ends on a real structure-module call, exactly as upstream.
                is_last = block_idx == len(trunk.blocks) - 1
                if (block_idx + 1) % every == 0 or is_last:
                    structure = read_out(s, z, recycle_idx, block_idx + 1)

            s_s, s_z = s, z
            recycle_s, recycle_z = s_s, s_z
            recycle_bins = EsmFoldingTrunk.distogram(
                structure["positions"][-1][:, :, :3], 3.375, 21.375, trunk.recycle_bins)

    structure["s_s"] = s_s
    structure["s_z"] = s_z
    return structure


def load_model(device: str, chunk_size: int):
    from transformers import AutoTokenizer, EsmForProteinFolding
    print(f"loading {MODEL_ID} on {device} ...", flush=True)
    t0 = time.time()
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = EsmForProteinFolding.from_pretrained(MODEL_ID, dtype=torch.float32)
    model = model.eval().to(device)
    model.trunk.set_chunk_size(chunk_size)
    print(f"loaded in {time.time() - t0:.1f} s", flush=True)
    return tokenizer, model


def fold(tokenizer, model, sequence: str, *, device: str, every: int, recycles: int,
         ipa_layers: bool):
    import types
    trunk = model.trunk
    sink: list[pftraj.Readout] = []
    trunk._pf_every, trunk._pf_sink, trunk._pf_parent = every, sink, model
    trunk._pf_ipa_layers = ipa_layers
    original_forward = trunk.forward
    trunk.forward = types.MethodType(_patched_trunk_forward, trunk)
    try:
        inputs = tokenizer([sequence], return_tensors="pt", add_special_tokens=False)
        inputs = {k: v.to(device) for k, v in inputs.items()}
        t0 = time.time()
        with torch.no_grad():
            model(**inputs, num_recycles=recycles)
        elapsed = time.time() - t0
    finally:
        trunk.forward = original_forward
        del trunk._pf_every, trunk._pf_sink, trunk._pf_parent, trunk._pf_ipa_layers
    return sink, elapsed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="protein ids to generate (default: all twelve)")
    ap.add_argument("--blocks-per-readout", type=int, default=48,
                    help="trunk blocks between structure-module readouts. PLAN.md proposed 4; "
                         "measurement showed mid-trunk readouts are geometrically broken "
                         "(CA-CA 5-18 A), so the default is 48, i.e. the end of each recycle, "
                         "where the structure module is actually trained to run")
    ap.add_argument("--recycles", type=int, default=3,
                    help="recycles passed to the model; the model adds one forward pass")
    ap.add_argument("--ipa-layers", action=argparse.BooleanOptionalAction, default=True,
                    help="emit one frame per structure-module IPA layer (8x more frames, all "
                         "with valid backbone geometry) instead of only the final layer")
    ap.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    ap.add_argument("--chunk-size", type=int, default=64)
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()

    print("Resolving sequences from their accessions:")
    records = load_all()
    if args.only:
        wanted = set(args.only)
        unknown = wanted - {r["id"] for r in records}
        if unknown:
            print(f"unknown protein id(s): {sorted(unknown)}", file=sys.stderr)
            return 2
        records = [r for r in records if r["id"] in wanted]

    tokenizer, model = load_model(args.device, args.chunk_size)
    toolchain = (f"torch {torch.__version__}, transformers "
                 f"{__import__('transformers').__version__}, device {args.device}")

    args.out.mkdir(parents=True, exist_ok=True)
    summary = []
    for rec in records:
        print(f"\n{rec['name']} ({rec['length']} aa) ...", flush=True)
        readouts, elapsed = fold(tokenizer, model, rec["sequence"],
                                 device=args.device, every=args.blocks_per_readout,
                                 recycles=args.recycles, ipa_layers=args.ipa_layers)
        final_plddt = float(readouts[-1].plddt.mean())
        meta = pftraj.TrajectoryMetadata(
            name=rec["name"], sequence=rec["sequence"],
            provenance=pftraj.PROVENANCE_ESMFOLD, sourceModel=MODEL_ID,
            blocksPerReadout=args.blocks_per_readout, recycles=args.recycles + 1,
            generated=dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            accession=rec.get("accession"), organism=rec.get("organism"),
            listeningNote=rec.get("listening_note"), referencePDBID=rec.get("reference_pdb"),
            notes=(f"sequence from {rec['origin']}; {toolchain}; "
                   f"{len(readouts)} readouts every {args.blocks_per_readout} trunk blocks "
                   f"over {args.recycles + 1} recycles; "
                   f"final mean pLDDT {final_plddt:.1f}"
                   + (f". {rec['reference_note']}" if rec.get("reference_note") else "")))
        path = pftraj.write(args.out / f"{rec['id']}.pftraj", meta, readouts)
        size_mb = path.stat().st_size / 1e6
        print(f"  {len(readouts)} readouts, final mean pLDDT {final_plddt:.1f}, "
              f"{elapsed:.1f} s, {size_mb:.1f} MB -> {path.name}", flush=True)
        summary.append({"id": rec["id"], "name": rec["name"], "length": rec["length"],
                        "readouts": len(readouts), "final_mean_plddt": round(final_plddt, 1),
                        "seconds": round(elapsed, 1), "megabytes": round(size_mb, 2),
                        "file": path.name})

    (args.out / "index.json").write_text(json.dumps(
        {"generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
         "sourceModel": MODEL_ID, "toolchain": toolchain,
         "blocksPerReadout": args.blocks_per_readout, "recycles": args.recycles + 1,
         "trajectories": summary}, indent=2) + "\n")
    print(f"\n{len(summary)} trajectories written to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
