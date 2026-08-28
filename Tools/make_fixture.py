#!/usr/bin/env python3
"""Regenerate the cross-language .pftraj fixture read by FoldCoreTests.

The values are chosen to be exactly representable in float32 so the Swift assertions can be
exact equality rather than a tolerance. If this file changes, CrossLanguageCodecTests.swift
must change with it: the point of the fixture is that both sides agree on specific numbers.
"""

from pathlib import Path

import numpy as np

import pftraj

OUT = Path(__file__).resolve().parent.parent / \
    "PhoneFoldKit/Tests/FoldCoreTests/Fixtures/python-written.pftraj"

N, FRAMES = 9, 4


def main() -> None:
    meta = pftraj.TrajectoryMetadata(
        name="Cross-language fixture",
        sequence="MKVFGRCEL",
        provenance=pftraj.PROVENANCE_TEST_FIXTURE,
        sourceModel="none/test-fixture",
        blocksPerReadout=4,
        recycles=2,
        generated="2026-08-28T00:00:00Z",
        accession="P00698",
        organism="Gallus gallus",
        listeningNote="not shipped: proves the Python writer and the Swift reader agree",
        referencePDBID="1UBQ",
        notes="written by Tools/pftraj.py, read by FoldCoreTests")

    readouts = []
    for f in range(FRAMES):
        bb = np.zeros((N, 4, 3), dtype="f4")
        for k in range(N):
            base = np.array([k * 3.75 - 11.25, f * -0.5, k * 0.25], dtype="f4")
            bb[k, 0] = base + np.array([-0.5, 0.125, -0.625], dtype="f4")
            bb[k, 1] = base
            bb[k, 2] = base + np.array([0.5, -0.125, 0.625], dtype="f4")
            bb[k, 3] = base + np.array([0.875, 0.5, 0.75], dtype="f4")
        pl = np.array([k * 1.5 + f * 3.25 for k in range(N)], dtype="f4")
        readouts.append(pftraj.Readout(f // 2, f * 4, bb, pl))

    path = pftraj.write(OUT, meta, readouts)
    print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
