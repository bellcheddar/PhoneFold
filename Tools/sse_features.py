"""CA-only feature extraction for secondary structure assignment.

Shared by the training pipeline and mirrored exactly by `LearnedSSE` in Swift. If this
changes, the Swift side must change with it, and the round-trip test will catch it if not.

Every feature is derived from CA positions alone, as PLAN.md Phase 1 requires: no backbone
amides, no carbonyls, no hydrogen bonds. That constraint is the whole point, because early in
a trajectory only the CA positions are trustworthy and Genie 2 emits nothing else.
"""

from __future__ import annotations

import numpy as np

# Residues either side of the centre that contribute geometry features.
WINDOW = 3
# Distance shells for the contact-count features, in angstroms. These are what let the model
# see beta pairing: a strand is a strand because it packs against another strand.
SHELLS = [(4.0, 5.5), (5.5, 7.0), (7.0, 9.0), (9.0, 12.0)]
# Sequence separation below which a pair is a neighbour along the chain, not a contact.
MIN_SEPARATION = 3

# Sentinel for a measurement that does not exist near a terminus. Paired with a validity
# flag so the model can tell "no evidence" from "a real value that happens to be zero".
MISSING = 0.0


def geometry(ca: np.ndarray):
    """Per-residue d2, d3, d4, theta and alpha, with NaN where undefined."""
    n = len(ca)
    d2 = np.full(n, np.nan)
    d3 = np.full(n, np.nan)
    d4 = np.full(n, np.nan)
    theta = np.full(n, np.nan)
    alpha = np.full(n, np.nan)

    def ang(a, b, c):
        u, v = a - b, c - b
        nu, nv = np.linalg.norm(u), np.linalg.norm(v)
        if nu < 1e-6 or nv < 1e-6:
            return np.nan
        return np.degrees(np.arccos(np.clip(np.dot(u, v) / (nu * nv), -1, 1)))

    def dih(p0, p1, p2, p3):
        b1, b2, b3 = p1 - p0, p2 - p1, p3 - p2
        n1, n2 = np.cross(b1, b2), np.cross(b2, b3)
        nb2 = np.linalg.norm(b2)
        if nb2 < 1e-6:
            return np.nan
        m = np.cross(n1, b2 / nb2)
        # Negated for the IUPAC convention: a right-handed alpha helix reads +50 degrees.
        return -np.degrees(np.arctan2(np.dot(m, n2), np.dot(n1, n2)))

    for i in range(1, n - 1):
        d2[i] = np.linalg.norm(ca[i + 1] - ca[i - 1])
        theta[i] = ang(ca[i - 1], ca[i], ca[i + 1])
    for i in range(1, n - 2):
        d3[i] = np.linalg.norm(ca[i + 2] - ca[i - 1])
        alpha[i] = dih(ca[i - 1], ca[i], ca[i + 1], ca[i + 2])
    for i in range(1, n - 3):
        d4[i] = np.linalg.norm(ca[i + 3] - ca[i - 1])
    return d2, d3, d4, theta, alpha


def contact_counts(ca: np.ndarray) -> np.ndarray:
    """(n, len(SHELLS)) counts of non-neighbour CA within each distance shell."""
    n = len(ca)
    diff = ca[:, None, :] - ca[None, :, :]
    dist = np.sqrt((diff ** 2).sum(-1))
    sep = np.abs(np.arange(n)[:, None] - np.arange(n)[None, :])
    valid = sep >= MIN_SEPARATION
    out = np.zeros((n, len(SHELLS)), dtype="f4")
    for k, (lo, hi) in enumerate(SHELLS):
        out[:, k] = ((dist >= lo) & (dist < hi) & valid).sum(1)
    return out


def featurise(ca: np.ndarray) -> np.ndarray:
    """CA coordinates (n, 3) -> feature matrix (n, FEATURE_COUNT).

    Scaling is fixed rather than fitted, so the Swift side needs no normalisation constants
    beyond what is written here.
    """
    ca = np.asarray(ca, dtype="f8")
    n = len(ca)
    d2, d3, d4, theta, alpha = geometry(ca)
    contacts = contact_counts(ca)

    rows = []
    for i in range(n):
        row = []
        for offset in range(-WINDOW, WINDOW + 1):
            j = i + offset
            if 0 <= j < n and np.isfinite(d3[j]):
                row += [
                    (d2[j] if np.isfinite(d2[j]) else MISSING) / 10.0,
                    d3[j] / 10.0,
                    (d4[j] if np.isfinite(d4[j]) else MISSING) / 10.0,
                    (theta[j] if np.isfinite(theta[j]) else MISSING) / 180.0,
                    np.cos(np.radians(alpha[j])) if np.isfinite(alpha[j]) else MISSING,
                    np.sin(np.radians(alpha[j])) if np.isfinite(alpha[j]) else MISSING,
                    1.0,                       # this window position carries evidence
                ]
            else:
                row += [MISSING] * 6 + [0.0]   # and this one does not
        row += list(contacts[i] / 10.0)
        # Position within the chain: termini behave differently and the model may use it.
        row.append(min(i, n - 1 - i) / 10.0)
        rows.append(row)
    return np.asarray(rows, dtype="f4")


FEATURE_COUNT = (2 * WINDOW + 1) * 7 + len(SHELLS) + 1
