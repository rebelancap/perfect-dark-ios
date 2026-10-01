#!/usr/bin/env python3
"""Generate app/ios/Assets-visionos.xcassets/AppIcon.solidimagestack from the
port's source art (app/ios/icon/perfect-dark.ico, 256x256 RGBA).

WHY: a visionOS app icon is LAYERED (.solidimagestack) — the system composites
two or three square layers and parallaxes them apart as the user's gaze moves.
A flat PNG in an .appiconset, which is all the iOS side ships, renders as a
BLANK tile on visionOS. (The iOS target keeps its legacy CFBundleIconFiles PNGs
untouched: Xcode 26's actool rejects a single-size iOS app-icon catalog, which
is why they are not in a catalog in the first place — docs/build.md §Traps M2.)

WHY A SCRIPT: so the layers come from ONE source of truth (the .ico the user
dropped) and can be regenerated when it changes.

The art makes the split exact rather than analytic: it is the PD mark on a
fully TRANSPARENT ground, so the alpha channel IS the subject mask. No luma
guess, no feathering heuristic.

  Back   opaque black, edge to edge. Apple requires an opaque back layer, and
         black is the icon's ground (the user, 2026-09-14).
  Front  the mark itself, alpha straight from the source, so it really does
         float above the ground and parallaxes as a separate plane instead of
         being flattened into the background.

Two layers, not three: the mark is one solid piece of geometry with no ring or
tick marks to separate by radius, and splitting a single glyph would tear it.

Run: python3 scripts/gen-vision-icon.py   (needs numpy + Pillow)
"""
import json
import pathlib

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "app/ios/icon/perfect-dark.ico"
OUT = ROOT / "app/ios/Assets-visionos.xcassets"
STACK = OUT / "AppIcon.solidimagestack"

SIZE = 1024
# The mark's longest side as a fraction of the tile. The source .ico runs edge
# to edge vertically, which on visionOS's circular, parallaxing tile reads as
# cramped: the mark is scaled to this fraction and centred so it pops against
# the black ground (the user, 2026-09-18: "more padding, say 75%").
FILL = 0.75


def layers(img):
    # The source is 256x256; the stack wants 1024 at 2x, so it is upscaled with
    # the same resampler the iOS PNGs get.
    src = np.asarray(img.convert("RGBA"))
    ys, xs = np.where(src[:, :, 3] > 0)
    crop = Image.fromarray(src[ys.min():ys.max() + 1, xs.min():xs.max() + 1], "RGBA")
    # Scale the mark's bounding box so its longer side is FILL of the tile,
    # then centre it on a transparent tile.
    scale = FILL * SIZE / max(crop.size)
    tw, th = (max(1, round(crop.size[0] * scale)), max(1, round(crop.size[1] * scale)))
    mark = crop.resize((tw, th), Image.LANCZOS)
    tile = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile.paste(mark, ((SIZE - tw) // 2, (SIZE - th) // 2))
    front = np.asarray(tile).copy()
    assert front[:, :, 3].max() == 255, "the mark has no opaque pixels — wrong source?"
    assert front[:, :, 3].min() == 0, "the source has no transparent ground — the split would be flat"
    # The mark alone. Its own RGB is kept (it is a dark metallic blue), and the
    # black behind it comes from the Back layer, not from flattening.
    back = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    back[:, :, 3] = 255
    return {"Back": back, "Front": front}


def write(name, arr):
    d = STACK / f"{name}.solidimagestacklayer"
    (d / "Content.imageset").mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (d / "Content.imageset" / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "img.png", "idiom": "vision", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    Image.fromarray(arr, "RGBA").save(d / "Content.imageset" / "img.png")


def main():
    img = Image.open(SRC)
    L = layers(img)
    assert L["Front"][:, :, 3].max() == 255, "the front layer came out empty"
    assert (L["Back"][:, :, 3] == 255).all(), "the back layer must be fully opaque"
    import shutil
    if STACK.exists():
        shutil.rmtree(STACK)
    STACK.mkdir(parents=True, exist_ok=True)
    (OUT / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (STACK / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": "Front.solidimagestacklayer"},
                   {"filename": "Back.solidimagestacklayer"}],
    }, indent=2) + "\n")
    for name, arr in L.items():
        write(name, arr)
    print(f"wrote {STACK}")


if __name__ == "__main__":
    main()
