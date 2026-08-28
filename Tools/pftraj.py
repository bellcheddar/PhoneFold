"""Writer for the .pftraj container consumed by FoldCore/TrajectoryBundleCodec.swift.

The layout is documented in Tools/README.md and must stay byte-compatible with the Swift
reader. Tests/FoldCoreTests round-trips the Swift side; Tools/test_pftraj.py round-trips
this one, and the Swift test suite reads a file this module wrote.
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, asdict, field
from pathlib import Path

import numpy as np

MAGIC = b"PFTRAJ01"
VERSION = 1

# Mirrors TrajectoryProvenance in FoldCore. There is deliberately no case for a
# synthesised trajectory: PLAN.md section 0.6 forbids a file that would need one.
PROVENANCE_ESMFOLD = "esmfold-trunk-readout"
PROVENANCE_COREML = "coreml-trunk-step"
PROVENANCE_TEST_FIXTURE = "test-fixture"
PROVENANCE_FOLDINGDIFF = "foldingdiff-denoising"
PROVENANCE_PATHDIFFUSION = "pathdiffusion-pathway"

# Must stay in step with TrajectoryProvenance in FoldCore. A value the Swift side does not
# know decodes as an error, not as a default, which is the behaviour we want.
VALID_PROVENANCE = {
    PROVENANCE_ESMFOLD, PROVENANCE_COREML, PROVENANCE_TEST_FIXTURE,
    PROVENANCE_FOLDINGDIFF, PROVENANCE_PATHDIFFUSION,
}


@dataclass
class TrajectoryMetadata:
    """Mirrors TrajectoryMetadata in FoldCore. Field names must match exactly: the Swift
    side decodes this with a plain JSONDecoder and no key mapping."""

    name: str
    sequence: str
    provenance: str
    sourceModel: str
    blocksPerReadout: int
    recycles: int
    generated: str
    accession: str | None = None
    organism: str | None = None
    listeningNote: str | None = None
    referencePDBID: str | None = None
    notes: str | None = None

    def to_json_bytes(self) -> bytes:
        # sort_keys mirrors Swift's .sortedKeys so encoding is deterministic and a bundle
        # can be hashed into Models/manifest.json.
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":")).encode("utf-8")


@dataclass
class Readout:
    """One raw coordinate readout. backbone is (N_res, 4, 3) float32 in the atom order
    N, CA, C, O; plddt is (N_res,) on the AlphaFold 0...100 scale."""

    recycle: int
    block_index: int
    backbone: np.ndarray
    plddt: np.ndarray


def write(path: Path, metadata: TrajectoryMetadata, readouts: list[Readout]) -> Path:
    if metadata.provenance not in VALID_PROVENANCE:
        raise ValueError(
            f"unknown provenance {metadata.provenance!r}; FoldCore would fail to decode it. "
            f"Known values: {sorted(VALID_PROVENANCE)}")
    n = len(metadata.sequence)
    if n == 0:
        raise ValueError("refusing to write a trajectory with an empty sequence")
    if not readouts:
        raise ValueError("refusing to write a trajectory with no readouts")

    for k, r in enumerate(readouts):
        if r.backbone.shape != (n, 4, 3):
            raise ValueError(
                f"readout {k}: backbone is {r.backbone.shape}, expected {(n, 4, 3)}"
            )
        if r.plddt.shape != (n,):
            raise ValueError(f"readout {k}: plddt is {r.plddt.shape}, expected {(n,)}")
        if not np.isfinite(r.backbone).all():
            raise ValueError(f"readout {k}: backbone contains non-finite coordinates")
        if not np.isfinite(r.plddt).all():
            raise ValueError(f"readout {k}: plddt contains non-finite values")

    meta_json = metadata.to_json_bytes()

    out = bytearray()
    out += MAGIC
    out += struct.pack("<II", VERSION, len(meta_json))
    out += meta_json
    out += struct.pack("<II", n, len(readouts))
    for r in readouts:
        out += struct.pack("<II", r.recycle, r.block_index)
        out += np.ascontiguousarray(r.backbone, dtype="<f4").tobytes()
        out += np.ascontiguousarray(r.plddt, dtype="<f4").tobytes()

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))
    return path


def read(path: Path) -> tuple[dict, list[Readout]]:
    """Reader, used only to verify what we wrote. The app reads these in Swift."""
    data = path.read_bytes()
    if data[:8] != MAGIC:
        raise ValueError(f"{path} is not a PhoneFold trajectory")
    version, meta_len = struct.unpack_from("<II", data, 8)
    if version > VERSION:
        raise ValueError(f"{path} is format version {version}, this writer knows {VERSION}")
    meta = json.loads(data[16 : 16 + meta_len])
    off = 16 + meta_len
    n, frames = struct.unpack_from("<II", data, off)
    off += 8
    if n != len(meta["sequence"]):
        raise ValueError(f"{path}: header says {n} residues, sequence has {len(meta['sequence'])}")

    readouts = []
    for _ in range(frames):
        recycle, block_index = struct.unpack_from("<II", data, off)
        off += 8
        bb = np.frombuffer(data, dtype="<f4", count=n * 12, offset=off).reshape(n, 4, 3)
        off += n * 12 * 4
        pl = np.frombuffer(data, dtype="<f4", count=n, offset=off)
        off += n * 4
        readouts.append(Readout(recycle, block_index, bb.copy(), pl.copy()))

    if off != len(data):
        raise ValueError(f"{path}: {len(data) - off} trailing bytes after the last readout")
    return meta, readouts
