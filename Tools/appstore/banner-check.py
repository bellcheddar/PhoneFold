#!/usr/bin/env python3
"""Exit 1 if a screenshot has a system notification banner across the top.

JUMPjet's interface is a near-black cockpit, so the band under the status bar
is dark in every legitimate capture. A notification banner is a large light
rounded rect in exactly that band, which makes mean luminance a reliable
discriminator: about 30 for a clean shot, about 143 with a banner.

Do NOT threshold on "fraction of bright pixels" instead. The amber LAUNCH
button sits in the same band and puts that figure at 10 to 15 per cent on a
perfectly clean capture, which reads as a banner and fails every shot.
"""
import sys
from PIL import Image
import numpy as np

THRESHOLD = 90.0

path = sys.argv[1]
image = Image.open(path).convert("L")
width, height = image.size
band = np.asarray(image.crop((0, int(height * 0.03), width, int(height * 0.115))),
                  dtype=float)
mean = band.mean()
print(f"{mean:.1f}")
sys.exit(1 if mean > THRESHOLD else 0)
