#!/usr/bin/env python3
"""Bake the Fold of the Day resource the Watch plays on its own.

PLAN.md Phase 5b: "Standalone Fold of the Day: one precomputed short trajectory per day,
playable on the Watch alone as a small animation with haptics. No inference, no phone
required."

**The first version of this used the bundled `.pftraj` gallery and had to be thrown away.**
Those are ESMFold trunk readouts, and measured on the thing the animation is actually about
they show almost no folding: for protein G, 137 of 210 contacts form on **frame 1** and the
structure's width changes by nothing (947 to 946 quantised units over 32 frames). Baked as an
animation that is an already-folded protein twitching, preceded by one enormous haptic burst
and followed by nothing. It looked plausible in every intermediate step, which is why it was
only caught by measuring the first frame against the last.

So the source is the structure-based (Go) model - the same engine the app ships, ported to
Swift in P0-33 and agreeing with this C to better than 1e-9 in forces. It starts from a
self-avoiding random coil and folds, which is the thing being shown.

**Precomputed all the way down, and that is a design constraint rather than an optimisation.**
The Watch runs no inference and should not run geometry either: decoding a `.pftraj`, building
a tube mesh and tracking contacts on a wrist is exactly the ambition PLAN warns Watch apps die
of. Everything the wrist needs is computed here and written flat:

- **A fixed 2D projection**, not a per-frame one: the plane is the folded structure's two
  principal axes, so it is seen face-on and the collapse into it reads as a collapse.
- **One scale for the whole trajectory**, from the widest frame. Normalising each frame to fit
  would draw an extended coil and a folded core at the same size, deleting the only thing the
  animation is about.
- **Contacts counted here**, with the same 8.0 A formation, 8.5 A break and minimum separation
  of 3 that `ContactTracker` uses, so the wrist's haptics fall where the phone's would.

Coordinates are quantised to integers in a +/-1000 box: a tenth of a per cent of the
structure's width, far below what a 40 mm screen resolves.

    Tools/.venv/bin/python Tools/make_fold_of_the_day.py
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path

import numpy as np

import fold_metrics as fm
from go_model_fold import load_native, random_coil
from go_model_run import run as go_run

REPO = Path(__file__).resolve().parent.parent
TRAJECTORIES = REPO / "Apps/Shared/Resources/Trajectories"
OUTPUT = REPO / "Apps/PhoneFold-watchOS/Resources/FoldOfTheDay.json"

# The short ones, and short is the whole criterion: a six-second animation on a 40 mm screen
# cannot show a 314-residue receptor as anything but a smudge, and the point is legibility.
CHOSEN = ["trp_cage", "ww_domain", "villin_hp36", "protein_g_b1", "alpha3d",
          "ubiquitin"]

FRAME_CAP = 90          # about six seconds, interpolated on the wrist
QUANTISED_RANGE = 1000
FORMATION_CUTOFF = 8.0
BREAK_CUTOFF = 8.5
MINIMUM_SEPARATION = 3

# Cooling rather than running longer: P0-39 measured 0.86 A to 0.23 A for free by ending
# colder instead of by taking more steps.
KT_START, KT_FINAL = 1.0, 0.6
STEPS_PER_RESIDUE = 100_000
SEED = 1


def projection_plane(final: np.ndarray) -> np.ndarray:
    """The two principal axes of the folded structure, as a 3x2 matrix.

    Face-on rather than down an arbitrary axis: projected along the long axis of a helical
    bundle a fold shows a blob with no helices in it, and the animation would look like
    nothing happening.
    """
    centred = final - final.mean(axis=0)
    _, _, vt = np.linalg.svd(centred, full_matrices=False)
    return vt[:2].T


def new_contacts(frames: list[np.ndarray]) -> list[int]:
    """Contacts formed on each frame, with the hysteresis `ContactTracker` uses."""
    counts = []
    held: set[tuple[int, int]] = set()
    for ca in frames:
        delta = ca[:, None, :] - ca[None, :, :]
        distance = np.sqrt((delta * delta).sum(-1))
        formed = 0
        n = len(ca)
        for i in range(n - MINIMUM_SEPARATION):
            for j in range(i + MINIMUM_SEPARATION, n):
                d = distance[i, j]
                if (i, j) in held:
                    if d > BREAK_CUTOFF:
                        held.discard((i, j))
                elif d <= FORMATION_CUTOFF:
                    held.add((i, j))
                    formed += 1
        counts.append(formed)
    return counts


CACHE = REPO / "Tools/.fold_of_the_day_cache"


def fold(path: Path) -> tuple[str, np.ndarray, np.ndarray, dict]:
    """Fold this protein, reusing the last run's coordinates when they still apply.

    The Go runs are deterministic in the seed and take between nine seconds and two and a
    half minutes each; the projection and the quantisation take milliseconds and are the part
    that gets iterated on. Two rounds of that were paid for at full price before this existed.
    The key carries every parameter the trajectory depends on, so changing one re-folds.
    """
    name, _sequence, native = load_native(path)
    n = len(native)
    rng = np.random.default_rng(SEED)
    start = random_coil(n, rng)
    steps = STEPS_PER_RESIDUE * n
    stride = max(steps // (FRAME_CAP * 2), 1)
    print(f"{path.stem:16s} {n:3d} residues, {steps:,} steps", end="", flush=True)
    key = f"{path.stem}-{steps}-{stride}-{KT_START}-{KT_FINAL}-{SEED}.npz"
    cached = CACHE / key
    if cached.exists():
        with np.load(cached) as store:
            ca, wall = store["ca"].astype(np.float64), float(store["wall"])
        print("  (cached)")
    else:
        print()
        ca, wall = go_run(native, start, steps=steps, stride=stride, kT=KT_START,
                          dt=0.005, gamma=1.0, seed=SEED, kT_final=KT_FINAL)
        CACHE.mkdir(exist_ok=True)
        np.savez_compressed(cached, ca=ca.astype(np.float32), wall=wall)
    pairs = fm.native_contacts(native)
    native_d = np.linalg.norm(native[pairs[:, 0]] - native[pairs[:, 1]], axis=1)
    quality = {
        "nativeFraction": round(float(fm.fraction_native_contacts(ca[-1], pairs, native_d)), 3),
        "rmsdToNative": round(float(fm.kabsch_rmsd(ca[-1], native)), 2),
        "radiusOfGyrationStart": round(float(fm.radius_of_gyration(ca[0])), 1),
        "radiusOfGyrationEnd": round(float(fm.radius_of_gyration(ca[-1])), 1),
        "seconds": round(wall, 1),
    }
    return name, ca, native, quality


def bake(path: Path) -> dict:
    name, ca, _native, quality = fold(path)
    frames = list(ca)
    if len(frames) > FRAME_CAP:
        indices = np.linspace(0, len(frames) - 1, FRAME_CAP).round().astype(int)
        # Always including the last: it is the folded structure, and it is what the
        # projection plane was chosen for.
        frames = [frames[i] for i in sorted(set(indices.tolist()))]

    plane = projection_plane(frames[-1])

    # **Translate per frame, scale once.** Both halves of that took a wrong turn first.
    #
    # Centring every frame on the *folded* structure's centroid put the coil off to one side,
    # because a coil's centre of mass is nowhere near the core it will collapse into, and the
    # animation drifted into frame as it went. Centring instead on the whole trajectory's
    # bounding box fixed the coil and broke the ending: the folded structure then sat in a
    # corner, and `max|coordinate|` stopped meaning "how big is this" - which quietly disabled
    # the one test that catches a trajectory that does not fold.
    #
    # What a viewer actually does is keep the object in the middle and let it change size. So
    # each frame is centred on its own centroid, and the scale - the part that must not vary,
    # or a coil and a core are drawn the same size - is taken once from the widest frame.
    flat = [(f - f.mean(axis=0)) @ plane for f in frames]
    half = max(float(np.abs(p).max()) for p in flat)
    scale = QUANTISED_RANGE / max(half, 1e-6)
    projected = flat

    contacts = new_contacts(frames)
    print(f"    {len(frames)} frames, {sum(contacts)} contacts formed, "
          f"Q {quality['nativeFraction']}, RMSD {quality['rmsdToNative']} A, "
          f"Rg {quality['radiusOfGyrationStart']} -> {quality['radiusOfGyrationEnd']} A")
    return {
        "id": path.stem,
        "name": name,
        "residueCount": int(len(frames[0])),
        "provenance": "structure-based-go",
        "quality": quality,
        "frames": [
            {"points": np.round(p * scale).astype(int).reshape(-1).tolist(),
             "newContacts": int(c)}
            for p, c in zip(projected, contacts)
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUTPUT)
    parser.add_argument("--only", type=str, default=None,
                        help="comma-separated ids, for trying one without baking all")
    args = parser.parse_args()

    chosen = args.only.split(",") if args.only else CHOSEN
    folds = []
    for stem in chosen:
        path = TRAJECTORIES / f"{stem}.pftraj"
        if not path.exists():
            raise SystemExit(f"missing trajectory: {path}")
        folds.append(bake(path))

    payload = {
        "version": 1,
        "generated": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "quantisedRange": QUANTISED_RANGE,
        "folds": folds,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    try:
        shown = args.out.relative_to(REPO)
    except ValueError:
        shown = args.out
    print(f"\nwrote {shown}  "
          f"{args.out.stat().st_size / 1024:.0f} kB, {len(folds)} folds")


if __name__ == "__main__":
    main()
