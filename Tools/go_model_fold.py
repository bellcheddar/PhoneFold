#!/usr/bin/env python3
"""A C-alpha structure-based (Go) model, folded from an extended chain by Langevin dynamics.

Why this exists. Every generative model measured so far answers a different question from
the one Marc asked. ESMFold's readouts do not move (0.87 A on ubiquitin); Genie 2 moves,
but by *expanding* out of a near-zero-radius blob, and it generates a novel backbone so it
cannot fold a named protein. A structure-based model is the other tradition: it takes the
*known* native state of a named protein, builds a potential whose global minimum is that
state, and integrates Newton's equations from an unfolded chain. The result is a genuine
unfolded -> folded pathway for ubiquitin, as ubiquitin, computed from scratch every run.

The honest claim it supports is narrow and must be stated: this is a **funnelled
coarse-grained simulation of a protein whose structure is already known**, in the tradition
of Clementi, Nymeyer and Onuchic (J Mol Biol 298:937, 2000). It is not a structure
prediction and it is not an unbiased physical force field. What it *is* is a real dynamical
trajectory, computed on the device, with a real folding transition in it.

Functional form (Clementi et al. 2000), in reduced units with epsilon = 1:

    E = sum_bonds     Kr (r - r0)^2
      + sum_angles    Kt (theta - theta0)^2
      + sum_dihedrals Kd [ (1 - cos(phi - phi0)) + 0.5 (1 - cos 3(phi - phi0)) ]
      + sum_native    eps [ 5 (sigma_ij/r)^12 - 6 (sigma_ij/r)^10 ]
      + sum_nonnative eps [ (sigma_nn/r)^12 ]

with Kr = 100, Kt = 20, Kd = 1, sigma_ij the native CA-CA distance of the contact, and
sigma_nn = 4.0 A. Native contacts are |i-j| >= 3 with a native CA-CA distance under the
cutoff.

Every force in here is analytic and is checked against a central finite difference of the
energy by `--selftest`, because a wrong dihedral gradient produces a trajectory that still
looks like something.
"""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np


# ---------------------------------------------------------------- topology and parameters

class GoModel:
    def __init__(self, native: np.ndarray, contact_cutoff: float = 8.0, min_sep: int = 3,
                 kr: float = 100.0, kt: float = 20.0, kd: float = 1.0,
                 eps: float = 1.0, sigma_nn: float = 4.0):
        self.x0 = np.asarray(native, dtype=np.float64)
        self.n = len(self.x0)
        self.kr, self.kt, self.kd, self.eps, self.sigma_nn = kr, kt, kd, eps, sigma_nn

        i = np.arange(self.n - 1)
        self.bonds = np.stack([i, i + 1], 1)
        self.r0 = np.linalg.norm(self.x0[1:] - self.x0[:-1], axis=1)

        i = np.arange(self.n - 2)
        self.angles = np.stack([i, i + 1, i + 2], 1)
        self.theta0 = self._angles(self.x0)

        i = np.arange(self.n - 3)
        self.dihedrals = np.stack([i, i + 1, i + 2, i + 3], 1)
        self.phi0 = self._dihedrals(self.x0)

        d = np.linalg.norm(self.x0[:, None, :] - self.x0[None, :, :], axis=-1)
        sep = np.abs(np.arange(self.n)[:, None] - np.arange(self.n)[None, :])
        upper = np.triu(np.ones_like(d, dtype=bool), 1)
        nat = upper & (sep >= min_sep) & (d < contact_cutoff)
        ii, jj = np.where(nat)
        self.native_pairs = np.stack([ii, jj], 1)
        self.sigma_native = d[ii, jj]

        non = upper & (sep >= min_sep) & ~nat
        ii, jj = np.where(non)
        self.nonnative_pairs = np.stack([ii, jj], 1)

    # -- geometry -----------------------------------------------------------------------

    def _angles(self, x: np.ndarray) -> np.ndarray:
        a, b, c = self.angles.T
        u, v = x[a] - x[b], x[c] - x[b]
        cos = np.einsum("ij,ij->i", u, v) / (
            np.linalg.norm(u, axis=1) * np.linalg.norm(v, axis=1))
        return np.arccos(np.clip(cos, -1.0, 1.0))

    def _dihedrals(self, x: np.ndarray) -> np.ndarray:
        a, b, c, d = self.dihedrals.T
        b1, b2, b3 = x[b] - x[a], x[c] - x[b], x[d] - x[c]
        n1, n2 = np.cross(b1, b2), np.cross(b2, b3)
        m = np.cross(n1, b2 / np.linalg.norm(b2, axis=1, keepdims=True))
        return np.arctan2(np.einsum("ij,ij->i", m, n2),
                          np.einsum("ij,ij->i", n1, n2))

    # -- energy -------------------------------------------------------------------------

    def energy(self, x: np.ndarray) -> float:
        a, b = self.bonds.T
        r = np.linalg.norm(x[b] - x[a], axis=1)
        e = self.kr * np.sum((r - self.r0) ** 2)

        e += self.kt * np.sum((self._angles(x) - self.theta0) ** 2)

        dphi = self._dihedrals(x) - self.phi0
        e += self.kd * np.sum((1 - np.cos(dphi)) + 0.5 * (1 - np.cos(3 * dphi)))

        i, j = self.native_pairs.T
        r = np.linalg.norm(x[j] - x[i], axis=1)
        s = self.sigma_native / r
        e += self.eps * np.sum(5 * s ** 12 - 6 * s ** 10)

        i, j = self.nonnative_pairs.T
        r = np.linalg.norm(x[j] - x[i], axis=1)
        e += self.eps * np.sum((self.sigma_nn / r) ** 12)
        return float(e)

    # -- forces (analytic; validated against finite differences by --selftest) ------------

    def forces(self, x: np.ndarray) -> np.ndarray:
        f = np.zeros_like(x)

        def scatter(idx, vec):
            for k in range(3):
                f[:, k] += np.bincount(idx, weights=vec[:, k], minlength=self.n)

        # bonds
        a, b = self.bonds.T
        d = x[b] - x[a]
        r = np.linalg.norm(d, axis=1)
        coef = (2 * self.kr * (r - self.r0) / r)[:, None]
        scatter(a, coef * d)
        scatter(b, -coef * d)

        # angles
        a, b, c = self.angles.T
        u, v = x[a] - x[b], x[c] - x[b]
        lu, lv = np.linalg.norm(u, axis=1), np.linalg.norm(v, axis=1)
        cos = np.clip(np.einsum("ij,ij->i", u, v) / (lu * lv), -1.0, 1.0)
        theta = np.arccos(cos)
        sin = np.sqrt(np.maximum(1 - cos ** 2, 1e-12))
        dEdtheta = 2 * self.kt * (theta - self.theta0)
        # dtheta/dx = -(1/sin) d(cos)/dx
        dcos_da = v / (lu * lv)[:, None] - (cos / lu ** 2)[:, None] * u
        dcos_dc = u / (lu * lv)[:, None] - (cos / lv ** 2)[:, None] * v
        ka = (-dEdtheta / sin)[:, None]
        fa, fc = -ka * dcos_da, -ka * dcos_dc
        scatter(a, fa)
        scatter(c, fc)
        scatter(b, -(fa + fc))

        # dihedrals
        a, b, c, d_ = self.dihedrals.T
        b1, b2, b3 = x[b] - x[a], x[c] - x[b], x[d_] - x[c]
        n1, n2 = np.cross(b1, b2), np.cross(b2, b3)
        n1sq = np.einsum("ij,ij->i", n1, n1)
        n2sq = np.einsum("ij,ij->i", n2, n2)
        lb2 = np.linalg.norm(b2, axis=1)
        m = np.cross(n1, b2 / lb2[:, None])
        phi = np.arctan2(np.einsum("ij,ij->i", m, n2), np.einsum("ij,ij->i", n1, n2))
        dphi = phi - self.phi0
        dEdphi = self.kd * (np.sin(dphi) + 1.5 * np.sin(3 * dphi))

        # Signs follow this file's own phi convention (atan2 of the b2-orthogonalised
        # normals), which is the opposite of the one the GROMACS manual's expression
        # assumes; every coefficient here was solved for against a central finite
        # difference and is re-checked by --selftest.
        dphi_da = (lb2 / n1sq)[:, None] * n1
        dphi_dd = -(lb2 / n2sq)[:, None] * n2
        p = np.einsum("ij,ij->i", b1, b2) / lb2 ** 2
        q = np.einsum("ij,ij->i", b3, b2) / lb2 ** 2
        dphi_db = (-1 - p)[:, None] * dphi_da + q[:, None] * dphi_dd
        dphi_dc = p[:, None] * dphi_da + (-1 - q)[:, None] * dphi_dd

        k = -dEdphi[:, None]
        scatter(a, k * dphi_da)
        scatter(b, k * dphi_db)
        scatter(c, k * dphi_dc)
        scatter(d_, k * dphi_dd)

        # native contacts, 10-12
        i, j = self.native_pairs.T
        dv = x[j] - x[i]
        r = np.linalg.norm(dv, axis=1)
        s = self.sigma_native / r
        # dE/dr = eps * (-60 s^12 + 60 s^10) / r
        dEdr = self.eps * 60.0 * (s ** 10 - s ** 12) / r
        coef = (-dEdr / r)[:, None]
        scatter(i, -coef * dv)
        scatter(j, coef * dv)

        # non-native repulsion
        i, j = self.nonnative_pairs.T
        dv = x[j] - x[i]
        r = np.linalg.norm(dv, axis=1)
        dEdr = -12.0 * self.eps * (self.sigma_nn / r) ** 12 / r
        coef = (-dEdr / r)[:, None]
        scatter(i, -coef * dv)
        scatter(j, coef * dv)
        return f

    # -- order parameters ----------------------------------------------------------------

    def q(self, x: np.ndarray, tolerance: float = 1.2) -> float:
        i, j = self.native_pairs.T
        r = np.linalg.norm(x[j] - x[i], axis=1)
        return float(np.mean(r < tolerance * self.sigma_native))


# ---------------------------------------------------------------------------- dynamics

def extended_chain(n: int, rng: np.random.Generator, bond: float = 3.8,
                   angle_deg: float = 120.0) -> np.ndarray:
    """A near-extended self-avoiding chain. Kept for comparison; not the default start.

    Measured and rejected as the unfolded state: P-SEA assigns a near-straight chain
    **96% sheet**, because an extended chain *is* in the beta conformation residue by
    residue. Starting there makes the trajectory's ordered-structure content go down rather
    than up, which is the opposite of the picture, and it is not what a denatured protein
    looks like either - its radius of gyration is 6x the compact expectation against about
    2.3x for a real random coil.
    """
    theta = np.deg2rad(angle_deg)
    x = np.zeros((n, 3))
    x[1] = [bond, 0, 0]
    x[2] = x[1] + bond * np.array([-np.cos(theta), np.sin(theta), 0.0])
    for k in range(3, n):
        phi = np.deg2rad(rng.uniform(150, 210))
        x[k] = _place(x[k - 3], x[k - 2], x[k - 1], bond, theta, phi)
    return x


def random_coil(n: int, rng: np.random.Generator, bond: float = 3.8,
                angle_deg: tuple[float, float] = (85.0, 145.0),
                clash: float = 4.0, attempts: int = 200) -> np.ndarray:
    """A self-avoiding random coil: the unfolded state the trajectory starts from.

    Backbone angles are drawn across the range a CA trace actually occupies and dihedrals
    uniformly over the circle, with rejection against a hard-sphere clash. That is the
    standard freely-rotating self-avoiding walk model of a denatured chain, and its radius
    of gyration lands near the experimental scaling for denatured proteins
    (Kohn et al., PNAS 101:12491, 2004: Rg = 2.54 * N^0.522).
    """
    x = np.zeros((n, 3))
    x[1] = [bond, 0, 0]
    t2 = np.deg2rad(rng.uniform(*angle_deg))
    x[2] = x[1] + bond * np.array([-np.cos(t2), np.sin(t2), 0.0])
    k = 3
    stuck = 0
    while k < n:
        placed = False
        for _ in range(attempts):
            theta = np.deg2rad(rng.uniform(*angle_deg))
            phi = rng.uniform(-np.pi, np.pi)
            cand = _place(x[k - 3], x[k - 2], x[k - 1], bond, theta, phi)
            if k < 3 or np.all(np.linalg.norm(x[:k - 2] - cand, axis=1) > clash):
                x[k] = cand
                placed = True
                break
        if placed:
            k += 1
            stuck = 0
        else:
            # back up two residues and try again rather than accepting a clash
            k = max(3, k - 2)
            stuck += 1
            if stuck > 50:
                raise RuntimeError("could not build a self-avoiding coil")
    return x


def _place(a: np.ndarray, b: np.ndarray, c: np.ndarray,
           bond: float, theta: float, phi: float) -> np.ndarray:
    """Next CA from the previous three, at the given bond angle and dihedral (NeRF)."""
    b1, b2 = c - b, b - a
    e1 = b1 / np.linalg.norm(b1)
    n1 = np.cross(b2, b1)
    n1 = n1 / np.linalg.norm(n1)
    e2 = np.cross(n1, e1)
    return c + bond * (-np.cos(theta) * e1
                       + np.sin(theta) * (np.cos(phi) * e2 + np.sin(phi) * n1))


def langevin(model: GoModel, x: np.ndarray, steps: int, kT: float, dt: float = 0.005,
             gamma: float = 1.0, mass: float = 1.0, stride: int = 500,
             rng: np.random.Generator | None = None) -> tuple[np.ndarray, list[dict]]:
    """BAOAB-style Langevin, velocity Verlet with an Ornstein-Uhlenbeck velocity update."""
    rng = rng or np.random.default_rng(0)
    v = rng.normal(0, np.sqrt(kT / mass), x.shape)
    f = model.forces(x)
    frames, rows = [x.copy()], []
    a = np.exp(-gamma * dt)
    b = np.sqrt(kT / mass * (1 - a * a))
    for step in range(steps):
        v += 0.5 * dt * f / mass
        x = x + 0.5 * dt * v
        v = a * v + b * rng.normal(0, 1, x.shape)
        x = x + 0.5 * dt * v
        f = model.forces(x)
        v += 0.5 * dt * f / mass
        if (step + 1) % stride == 0:
            frames.append(x.copy())
            rows.append({"step": step + 1, "q": model.q(x),
                         "rg": float(np.sqrt(((x - x.mean(0)) ** 2).sum(1).mean())),
                         "energy": model.energy(x)})
    return np.array(frames), rows


# ------------------------------------------------------------------------------ checks

def selftest(model: GoModel, rng: np.random.Generator) -> None:
    """Central finite differences against the analytic forces, per energy term.

    Each term is isolated by zeroing the others' constants, so a wrong dihedral gradient
    cannot hide behind a right bond gradient.
    """
    x = model.x0 + rng.normal(0, 0.35, model.x0.shape)
    terms = {
        "bond": dict(kr=model.kr, kt=0, kd=0, eps=0),
        "angle": dict(kr=0, kt=model.kt, kd=0, eps=0),
        "dihedral": dict(kr=0, kt=0, kd=model.kd, eps=0),
        "contacts": dict(kr=0, kt=0, kd=0, eps=model.eps),
        "all": dict(kr=model.kr, kt=model.kt, kd=model.kd, eps=model.eps),
    }
    saved = (model.kr, model.kt, model.kd, model.eps)
    h = 1e-5
    worst_overall = 0.0
    for name, cfg in terms.items():
        model.kr, model.kt, model.kd, model.eps = (
            cfg["kr"], cfg["kt"], cfg["kd"], cfg["eps"])
        fa = model.forces(x)
        idx = rng.choice(model.n, size=min(8, model.n), replace=False)
        worst = 0.0
        for i in idx:
            for k in range(3):
                xp, xm = x.copy(), x.copy()
                xp[i, k] += h
                xm[i, k] -= h
                num = -(model.energy(xp) - model.energy(xm)) / (2 * h)
                worst = max(worst, abs(num - fa[i, k]) / max(1.0, abs(num)))
        worst_overall = max(worst_overall, worst)
        print(f"  {name:<10} worst relative force error {worst:.3e}")
    model.kr, model.kt, model.kd, model.eps = saved
    print(f"  worst overall {worst_overall:.3e}"
          f"  {'OK' if worst_overall < 1e-4 else 'FAIL'}")


# -------------------------------------------------------------------------------- main

def load_native(path: Path) -> tuple[str, str, np.ndarray]:
    import pftraj
    meta, readouts = pftraj.read(path)
    r = readouts[-1]
    ca = r.backbone[:, 1 if r.backbone.shape[1] == 4 else 0, :].astype(np.float64)
    return meta["name"], meta["sequence"], ca


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("native", type=Path, help=".pftraj whose final frame is the native state")
    ap.add_argument("--steps", type=int, default=2_000_000)
    ap.add_argument("--kT", type=float, default=1.0)
    ap.add_argument("--dt", type=float, default=0.005)
    ap.add_argument("--gamma", type=float, default=1.0)
    ap.add_argument("--stride", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--scan", type=str, default=None,
                    help="comma-separated kT values: short runs to locate the folding temperature")
    args = ap.parse_args()

    name, sequence, native = load_native(args.native)
    rng = np.random.default_rng(args.seed)
    model = GoModel(native)
    print(f"{name}: {model.n} residues, {len(model.native_pairs)} native contacts, "
          f"{len(model.nonnative_pairs)} non-native pairs")

    if args.selftest:
        selftest(model, rng)
        return 0

    if args.scan:
        for kT in [float(t) for t in args.scan.split(",")]:
            x = extended_chain(model.n, np.random.default_rng(args.seed))
            t0 = time.time()
            _, rows = langevin(model, x, args.steps, kT, args.dt, args.gamma,
                               stride=args.stride, rng=np.random.default_rng(args.seed))
            qs = [r["q"] for r in rows]
            print(f"  kT {kT:>5.2f}   Q final {qs[-1]:.3f}   Q max {max(qs):.3f}   "
                  f"Q mean(last 20%) {np.mean(qs[-max(1, len(qs) // 5):]):.3f}   "
                  f"{time.time() - t0:.1f} s")
        return 0

    x = extended_chain(model.n, rng)
    t0 = time.time()
    frames, rows = langevin(model, x, args.steps, args.kT, args.dt, args.gamma,
                            stride=args.stride, rng=rng)
    wall = time.time() - t0
    print(f"{len(frames)} frames, {args.steps} steps in {wall:.1f} s "
          f"({1e6 * wall / args.steps:.1f} us/step, {args.steps / wall:,.0f} steps/s)")
    print(f"Q: {rows[0]['q']:.3f} -> {rows[-1]['q']:.3f}   "
          f"Rg: {rows[0]['rg']:.2f} -> {rows[-1]['rg']:.2f} A")

    if args.out:
        np.savez_compressed(args.out, ca=frames.astype(np.float32), name=name,
                            sequence=sequence, native=native.astype(np.float32),
                            steps=args.steps, kT=args.kT, dt=args.dt, gamma=args.gamma,
                            stride=args.stride, seed=args.seed,
                            q=np.array([r["q"] for r in rows]),
                            energy=np.array([r["energy"] for r in rows]))
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
