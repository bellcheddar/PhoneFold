"""Shared measurements for judging whether a trajectory shows a protein folding.

Phase 0 keeps asking one question in different clothes: *is there a fold to watch*. The
answer needs the same four numbers every time, so they live here rather than being
re-derived per script:

  - radius of gyration, and its ratio to the compact expectation 2.2 * N^0.38
  - secondary structure content per frame (CA-only P-SEA, via biotite)
  - CA-CA virtual bond length, the tell for whether a frame is a polypeptide at all
  - fraction of native contacts Q, when a reference structure exists

`biotite.structure.annotate_sse` is the *same* P-SEA the Swift `PSEA` type was validated
against in Phase 1 (METRICS.md: 678/871 residues, structure for structure). Using it here
means the secondary-structure numbers in this file and the ones the app shows come from the
same method, which is the only reason they can be compared.
"""
from __future__ import annotations

import numpy as np

import biotite.structure as struc


def radius_of_gyration(ca: np.ndarray) -> float:
    return float(np.sqrt(((ca - ca.mean(0)) ** 2).sum(1).mean()))


def compact_expectation(n: int) -> float:
    """Rg of a compact globular chain of n residues, in angstroms.

    Validated in METRICS.md before use: predicts 11.4 A for 76 residues against
    experimental ubiquitin's 11.49 A.
    """
    return 2.2 * n ** 0.38


def kabsch_rmsd(P: np.ndarray, Q: np.ndarray) -> float:
    Pc, Qc = P - P.mean(0), Q - Q.mean(0)
    V, _, Wt = np.linalg.svd(Pc.T @ Qc)
    D = np.diag([1.0, 1.0, np.sign(np.linalg.det(V @ Wt))])
    return float(np.sqrt((((Pc @ (V @ D @ Wt)) - Qc) ** 2).sum(1).mean()))


def tm_score(P: np.ndarray, Q: np.ndarray) -> float:
    """TM-score of P against reference Q, superposed by Kabsch on all residues.

    This is the TM-score *of the Kabsch superposition*, not TM-align's optimised one, so it
    is a lower bound. It is used only to compare a folding trajectory against its own
    reference, where the alignment is the identity, so the optimisation TM-align performs
    (searching alignments) has nothing to search.
    """
    n = len(P)
    d0 = 1.24 * (n - 15) ** (1 / 3) - 1.8 if n > 21 else 0.5
    Pc, Qc = P - P.mean(0), Q - Q.mean(0)
    V, _, Wt = np.linalg.svd(Pc.T @ Qc)
    D = np.diag([1.0, 1.0, np.sign(np.linalg.det(V @ Wt))])
    d = np.linalg.norm(Pc @ (V @ D @ Wt) - Qc, axis=1)
    return float(np.mean(1.0 / (1.0 + (d / d0) ** 2)))


def ca_ca(ca: np.ndarray) -> tuple[float, float]:
    b = np.linalg.norm(np.diff(ca, axis=0), axis=1)
    return float(b.mean()), float(b.std())


def _ca_atom_array(ca: np.ndarray, sequence: str | None = None):
    """Wrap CA coordinates as a biotite AtomArray so P-SEA can be run on them."""
    n = len(ca)
    arr = struc.AtomArray(n)
    arr.coord = np.asarray(ca, dtype=np.float32)
    arr.chain_id = np.full(n, "A")
    arr.res_id = np.arange(1, n + 1)
    arr.res_name = np.full(n, "GLY" if sequence is None else "GLY")
    arr.atom_name = np.full(n, "CA")
    arr.element = np.full(n, "C")
    return arr


def sse_content(ca: np.ndarray) -> dict:
    """Helix / sheet / coil fractions from CA coordinates alone, by P-SEA.

    Returns fractions in 0..1 and the raw per-residue string of 'a', 'b', 'c'.
    """
    sse = struc.annotate_sse(_ca_atom_array(ca))
    s = "".join(str(x) for x in sse)
    n = max(len(s), 1)
    return {
        "helix": s.count("a") / n,
        "sheet": s.count("b") / n,
        "coil": s.count("c") / n,
        "string": s,
    }


def native_contacts(ca: np.ndarray, cutoff: float = 8.0, min_sep: int = 3) -> np.ndarray:
    """Index pairs (i, j) within `cutoff` in the reference, with |i-j| >= min_sep."""
    d = np.linalg.norm(ca[:, None, :] - ca[None, :, :], axis=-1)
    sep = np.abs(np.arange(len(ca))[:, None] - np.arange(len(ca))[None, :])
    ii, jj = np.where((d < cutoff) & (sep >= min_sep) & (np.triu(np.ones_like(d), 1) > 0))
    return np.stack([ii, jj], axis=1)


def fraction_native_contacts(ca: np.ndarray, pairs: np.ndarray,
                             native_d: np.ndarray, tolerance: float = 1.2) -> float:
    """Q, the fraction of native contacts formed, on the usual 1.2x-native criterion."""
    if len(pairs) == 0:
        return 0.0
    d = np.linalg.norm(ca[pairs[:, 0]] - ca[pairs[:, 1]], axis=1)
    return float(np.mean(d < tolerance * native_d))


def contact_count(ca: np.ndarray, cutoff: float = 8.0, min_sep: int = 3) -> int:
    """Contacts at the app's own tracker threshold, so counts are comparable to METRICS."""
    return len(native_contacts(ca, cutoff, min_sep))


def monotonicity(values) -> float:
    """Fraction of consecutive steps that move in the majority direction.

    1.0 is a perfectly monotone trace. A trajectory that expands and re-collapses scores
    near 0.5, which is what disqualifies it as "a clear gradient from unfolded to folded".
    """
    v = np.asarray(values, dtype=float)
    d = np.diff(v)
    d = d[d != 0]
    if len(d) == 0:
        return 1.0
    return float(max((d > 0).mean(), (d < 0).mean()))
