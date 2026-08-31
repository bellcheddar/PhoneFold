#!/usr/bin/env python3
"""Turn assets/icon/master.png into the asset catalogues each platform wants.

The master is rendered by `swift run make-icon` - a real frame of a real fold, drawn by the
same offscreen stage that makes the films. This only slices it.

**Four platforms want four different things**, and only one of them is a plain PNG set:

- **iOS and iPadOS** take a single 1024 in the `universal` idiom (Xcode 14 and later). The
  older ladder of 20 through 180 px is no longer needed and Xcode warns if it is present.
- **macOS** still wants the full ladder, 16 through 512 at 1x and 2x, in the `mac` idiom.
  One `.appiconset` can carry both idioms, which is what a multiplatform target needs.
- **watchOS** takes a single 1024 in `universal`, like iOS.
- **visionOS** takes a `.solidimagestack`, not an `.appiconset`: three layers, back to front,
  which the system parallaxes as the wearer moves. A flat icon is expressed as the artwork on
  `Back` with the two layers in front of it left empty - valid, and honest about the fact that
  nothing here is a layered design yet.

    Tools/.venv/bin/python Tools/appstore/make_icon_sets.py
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent.parent
MASTER = REPO / "assets/icon/master.png"

# (size in points, scale) for the macOS ladder.
MAC_SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]


def load_master() -> Image.Image:
    if not MASTER.exists():
        raise SystemExit(f"missing {MASTER}. Run: swift run --package-path PhoneFoldKit "
                         "make-icon --colour secondaryStructure --distance 1.15 --yaw 0.8 "
                         "--size 1024 --out assets/icon/master.png")
    image = Image.open(MASTER).convert("RGB")
    if image.size != (1024, 1024):
        raise SystemExit(f"the master is {image.size}, not 1024x1024")
    return image


def write(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # **RGB, never RGBA.** App Store Connect rejects an icon with an alpha channel outright,
    # and an asset catalogue will happily compile one, so the refusal arrives at upload.
    image.resize((size, size), Image.LANCZOS).convert("RGB").save(path, format="PNG")


def appiconset(directory: Path, *, mac: bool) -> None:
    shutil.rmtree(directory, ignore_errors=True)
    master = load_master()
    images = []

    write(master, directory / "icon-1024.png", 1024)
    images.append({"filename": "icon-1024.png", "idiom": "universal",
                   "platform": "ios" if not mac else "ios", "size": "1024x1024"})
    if mac:
        for points, scale in MAC_SIZES:
            pixels = points * scale
            name = f"mac-{points}x{points}@{scale}x.png"
            write(master, directory / name, pixels)
            images.append({"filename": name, "idiom": "mac",
                           "scale": f"{scale}x", "size": f"{points}x{points}"})

    (directory / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"{directory.relative_to(REPO)}  {len(images)} entries")


def watch_iconset(directory: Path) -> None:
    shutil.rmtree(directory, ignore_errors=True)
    master = load_master()
    write(master, directory / "icon-1024.png", 1024)
    (directory / "Contents.json").write_text(json.dumps(
        {"images": [{"filename": "icon-1024.png", "idiom": "universal",
                     "platform": "watchos", "size": "1024x1024"}],
         "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"{directory.relative_to(REPO)}  1 entry")


VISION_SIZE = 512
PROTEIN = REPO / "assets/icon/protein.png"


def solid_image_stack(directory: Path) -> None:
    """visionOS: layers, back to front, which the system parallaxes as the wearer moves.

    Two things Xcode enforces and neither is in the human-interface guidance:

    - **The stack is 512 x 512, not 1024.** A 1024 layer fails with "must exactly fill the
      image stack. Its current frame is {{0, 0}, {1024, 1024}} while the visionOS App Icon's
      size is {512, 512}".
    - **At least two layers must have content.** A flat icon expressed as artwork on `Back`
      with empty layers in front of it is refused: "Although it has 3 layers, only 1 has
      applicable content." So visionOS does not accept a flat icon at all, and the layering is
      a requirement rather than a flourish.

    So the ground and the protein are separated: `Back` is the stage's own colour, filling the
    square, and `Front` is the protein on transparency - solved exactly by `make-icon
    --transparent` rather than keyed out of the flat render, which fringes on the shaded faces
    of the ribbons.
    """
    if not PROTEIN.exists():
        raise SystemExit(f"missing {PROTEIN}. Run make-icon with --transparent.")
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1},
         "layers": [{"filename": "Front.solidimagestacklayer"},
                    {"filename": "Middle.solidimagestacklayer"},
                    {"filename": "Back.solidimagestacklayer"}]}, indent=2) + "\n")

    # The ground, sampled from the master rather than computed from the renderer's linear
    # constant: the master has been through the linear-to-sRGB conversion and the layer must
    # match it exactly, or the visionOS icon is a different colour from every other platform's.
    ground = load_master().getpixel((4, 4))
    back = Image.new("RGB", (VISION_SIZE, VISION_SIZE), ground)
    protein = Image.open(PROTEIN).convert("RGBA").resize(
        (VISION_SIZE, VISION_SIZE), Image.LANCZOS)

    for name, image in (("Front", protein), ("Middle", None), ("Back", back)):
        layer = directory / f"{name}.solidimagestacklayer"
        content = layer / "Content.imageset"
        content.mkdir(parents=True, exist_ok=True)
        (layer / "Contents.json").write_text(json.dumps(
            {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        if image is None:
            images = [{"idiom": "universal", "scale": "1x"}]
        else:
            image.save(content / "icon.png", format="PNG")
            images = [{"filename": "icon.png", "idiom": "universal", "scale": "1x"}]
        (content / "Contents.json").write_text(json.dumps(
            {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"{directory.relative_to(REPO)}  ground {ground}, 512x512, 2 layers with content")


def main() -> None:
    appiconset(REPO / "Apps/PhoneFold/Assets.xcassets/AppIcon.appiconset", mac=True)
    (REPO / "Apps/PhoneFold/Assets.xcassets/Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    watch_iconset(REPO / "Apps/PhoneFold-watchOS/Assets.xcassets/AppIcon.appiconset")
    (REPO / "Apps/PhoneFold-watchOS/Assets.xcassets/Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    solid_image_stack(
        REPO / "Apps/PhoneFold-visionOS/Assets.xcassets/AppIcon.solidimagestack")
    (REPO / "Apps/PhoneFold-visionOS/Assets.xcassets/Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
