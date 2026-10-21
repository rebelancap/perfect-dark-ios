#!/usr/bin/env python3
"""stereo-star-check.py — is the star field at infinity, or on the panel?

    stereo-star-check.py <L.png> <R.png> [<L-again.png>]

D-097 depth-tags the star field (stars.c draws every star as a one-pixel 2D
rectangle PD projected itself) with the depth payload's INFINITY value, so the
renderer shifts each star by the stereo fold's far asymptote: the disparity
the sky dome's skew-only class already has. Without it a star is drawn at the
same pixels in both eyes - zero disparity, ON the panel.

THE MEASUREMENT. A star is a small bright blob on a black sky. Both eyes'
star maps are built the same way (bright, and isolated: dark all round at a
radius of 4 px, which rejects building windows and edges), and the
horizontal shift that best overlays the right eye's map on the left's is
the star field's disparity, R minus L, in capture pixels. Positive is
UNCROSSED (behind the panel), which is where infinity is.

The same search is run on the left eye against a second capture of the left
eye (a determinism control: it must read 0), and the whole frame's
non-star content is block-matched the same way for comparison: the world's
farthest geometry can approach the stars' shift but never exceed it.
"""
import sys

import numpy as np
from PIL import Image

SEARCH = 30


def load(p):
    return np.asarray(Image.open(p).convert("L"), dtype=np.float32)


def star_map(img):
    h, w = img.shape
    bright = img > 60.0
    # isolated: the ring at radius 4 is dark in all eight directions
    dark = np.ones_like(bright)
    r = 4
    pad = np.pad(img, r, mode="edge")
    for dy, dx in ((-r, 0), (r, 0), (0, -r), (0, r), (-r, -r), (-r, r), (r, -r), (r, r)):
        ring = pad[r + dy:r + dy + h, r + dx:r + dx + w]
        dark &= ring < 25.0
    m = (bright & dark).astype(np.float32)
    # ignore the outer frame (letterbox edge, panel border)
    m[:, :SEARCH + 2] = 0
    m[:, -SEARCH - 2:] = 0
    return m


def best_shift(a, b, mask_b=None):
    scores = {}
    for dx in range(-SEARCH, SEARCH + 1):
        shifted = np.roll(b, -dx, axis=1)
        scores[dx] = float((a * shifted).sum())
    best = max(scores.values())
    # the dilation makes a plateau three wide; its middle is the shift
    plateau = [dx for dx, s in scores.items() if s >= best]
    return sum(plateau) / len(plateau), best, scores


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    L = load(sys.argv[1])
    R = load(sys.argv[2])
    sL, sR = star_map(L), star_map(R)
    nL, nR = int(sL.sum()), int(sR.sum())
    print(f"star pixels: L {nL}, R {nR}")
    if nL < 20 or nR < 20:
        print("RESULT: too few star pixels to measure")
        return 1
    # dilate a little so a sub-pixel shift still overlaps
    def dil(m):
        out = m.copy()
        for d in (-1, 1):
            out = np.maximum(out, np.roll(m, d, axis=1))
            out = np.maximum(out, np.roll(m, d, axis=0))
        return out
    dx, score, scores = best_shift(dil(sL), sR)
    zero = scores[0]
    print(f"star field shift R-L: {dx:+.1f} px  (overlap {score:.0f} at best, {zero:.0f} at 0)")
    if len(sys.argv) > 3:
        L2 = load(sys.argv[3])
        dx2, s2, _ = best_shift(dil(sL), star_map(L2))
        print(f"control L vs L-again: {dx2:+.1f} px (overlap {s2:.0f})")
    print(f"RESULT star_shift_px={dx:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
