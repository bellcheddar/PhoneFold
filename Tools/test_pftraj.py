"""Round-trip and rejection tests for the Python .pftraj writer."""

import tempfile
from pathlib import Path

import numpy as np
import pytest

import pftraj


def fixture(n=7, frames=5):
    meta = pftraj.TrajectoryMetadata(
        name="Codec fixture", sequence="MKVFGRC"[:n].ljust(n, "G"),
        provenance=pftraj.PROVENANCE_TEST_FIXTURE, sourceModel="none/test-fixture",
        blocksPerReadout=4, recycles=2, generated="2026-08-28T00:00:00Z")
    rng = np.random.default_rng(0)
    readouts = [
        pftraj.Readout(f // 3, f * 4,
                       rng.standard_normal((n, 4, 3)).astype("f4") * 10,
                       (rng.random(n).astype("f4") * 100))
        for f in range(frames)]
    return meta, readouts


def test_round_trip():
    meta, readouts = fixture()
    with tempfile.TemporaryDirectory() as d:
        p = pftraj.write(Path(d) / "x.pftraj", meta, readouts)
        got_meta, got = pftraj.read(p)
        assert got_meta["sequence"] == meta.sequence
        assert got_meta["provenance"] == pftraj.PROVENANCE_TEST_FIXTURE
        assert len(got) == len(readouts)
        for a, b in zip(got, readouts):
            assert a.recycle == b.recycle and a.block_index == b.block_index
            np.testing.assert_array_equal(a.backbone, b.backbone)
            np.testing.assert_array_equal(a.plddt, b.plddt)


def test_deterministic():
    meta, readouts = fixture()
    with tempfile.TemporaryDirectory() as d:
        a = pftraj.write(Path(d) / "a.pftraj", meta, readouts).read_bytes()
        b = pftraj.write(Path(d) / "b.pftraj", meta, readouts).read_bytes()
        assert a == b


@pytest.mark.parametrize("mutate,message", [
    (lambda m, r: r.__setitem__(0, pftraj.Readout(0, 0, r[0].backbone[:-1], r[0].plddt)), "backbone is"),
    (lambda m, r: r.__setitem__(0, pftraj.Readout(0, 0, r[0].backbone, r[0].plddt[:-1])), "plddt is"),
    (lambda m, r: r[0].backbone.__setitem__((0, 0, 0), np.nan), "non-finite coordinates"),
    (lambda m, r: r[0].plddt.__setitem__(0, np.inf), "non-finite values"),
])
def test_rejects_bad_input(mutate, message):
    meta, readouts = fixture()
    mutate(meta, readouts)
    with tempfile.TemporaryDirectory() as d:
        with pytest.raises(ValueError, match=message):
            pftraj.write(Path(d) / "x.pftraj", meta, readouts)


def test_rejects_empty():
    meta, readouts = fixture()
    with tempfile.TemporaryDirectory() as d:
        with pytest.raises(ValueError, match="no readouts"):
            pftraj.write(Path(d) / "x.pftraj", meta, [])
