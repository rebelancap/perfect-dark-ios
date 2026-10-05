# Installing Perfect Dark on Apple Vision Pro

This is the [Perfect Dark decompilation](https://github.com/n64decomp/perfect_dark) compiled for Apple silicon, through the [Perfect Dark PC port](https://github.com/perfect-dark-pc-port/perfect_dark) and [Dab's Mod](https://github.com/DabDavis/perfect-dark-dabs-mod), rendering on Metal. It is not an emulator. On Apple Vision Pro it runs in a resizable 2D window, and a stereoscopic 3D mode puts the game on a world-locked panel in your room, in mixed immersion.

## What you need

- Apple Vision Pro on visionOS 26 or later
- Your own Perfect Dark ROM: **Perfect Dark (USA) (Rev 1)**, `pd.ntsc-final.z64`, md5 `e03b088b6ac9e0080440efed07c1e40f`. PAL, JPN and US 1.0 ROMs are not supported.
- Optional: your own copy of the 2010 Xbox Live Arcade release, for its high-resolution art; and for GE Plus, your own GoldenEye 007 (US) N64 ROM
- A game controller is strongly recommended in the headset. Without one, the touch layer is driven by pinch.
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: macOS with Xcode, plus `cmake`, `ninja` and `xcodegen` (`brew install cmake ninja xcodegen`)

## Your game files

The app ships with no game data: no ROM, no textures, no audio and no Xbox 360 content. It reads everything from your copy at startup.

1. Open the **Files** app and go to **On My Apple Vision Pro → Perfect Dark**.
2. Drop `pd.ntsc-final.z64` straight into that folder (a `data/` subfolder works too), then relaunch the app.
3. The first-run screen checks the file and tells you which ROM you have, and why it was rejected if it isn't the supported one.

Optional extras go in the **`added-content`** folder in the same place (the game creates it on first launch):

- **Xbox 360 (XBLA) release:** the archive as it came (`.rar` or `.7z`) or the bare STFS package. The next launch unpacks it once (around 250 MB). Then **Settings → Xbox 360 (XBLA) → Xbox 360 textures and models** turns it on or off.
- **GoldenEye 007 (GE Plus):** your GoldenEye 007 (US) ROM (`.z64`, `.n64` or `.v64`), converted once on the next launch. The GoldenEye XBLA release and Goldfinger 64 are also supported.

The README's [You bring the game](README.md#you-bring-the-game) section covers each of these in full, and lists every file and folder the app uses.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way; iloader is what gets SideStore there. No Xcode or Dev Strap required.
2. In SideStore, go to *Sources → +* and paste this source, then install Perfect Dark:

   ```
   https://raw.githubusercontent.com/rebelancap/all-ports/main/apps-visionos.json
   ```

   This is a shared source that carries the other ports too, and the app updates from it when new versions ship.

To install by hand instead, download `perfectdark-<VERSION>-visionOS.ipa` from the [latest release](https://github.com/rebelancap/perfect-dark-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

No game data is needed to build. From a checkout of this repo:

```sh
scripts/bootstrap.sh                # clone/checkout vendor/dabs-mod at UPSTREAM_PIN
# recreate the work/ dependency links: see work/deps-PROVENANCE.md and work/curl-PROVENANCE.md
scripts/apply-overlay.sh            # vendor + overlay/patches/*.patch -> build/src
scripts/build-sdl2-visionos.sh xros # once: SDL2 for visionOS
scripts/build-ios.sh visionos       # the engine for Apple Vision Pro
scripts/gen-app-project.sh          # -> app/perfectdark.xcodeproj
```

Then build the `perfectdark-visionos` scheme in Xcode, with your own team set as `DEVELOPMENT_TEAM` (in the environment, or passed to `xcodebuild`).

The build links ANGLE, SDL2 and libcurl from `work/`, which is not committed. [`work/deps-PROVENANCE.md`](work/deps-PROVENANCE.md) and [`work/curl-PROVENANCE.md`](work/curl-PROVENANCE.md) list each piece (including the iOS slices that `gen-app-project.sh` also checks for) and the scripts that build it. [`docs/build.md`](docs/build.md) is the long version.

Upstream Dab's Mod is vendored unmodified and pinned by commit (`UPSTREAM_PIN`). Every local change is a patch in `overlay/patches/`, applied by `scripts/apply-overlay.sh`.

## Notes

- **3D mode:** the 2D window parks as a small card while you're in 3D. The live settings sheet sets screen distance, size and height, stereo depth, convergence, surroundings dimming and render resolution, and has a recenter button.
- Multiplayer is not supported; the campaign and the Combat Simulator against simulants are. Ghost Trials' online leaderboards work.
- Sideloaded apps expire: a free Apple account signs for 7 days, a paid developer account for a year. SideStore refreshes them in the background; open it and let it re-sign if the app stops launching.
- Crashes are written to `crash.txt` in the app's folder; attach it to a [GitHub issue](https://github.com/rebelancap/perfect-dark-ios/issues).
- Perfect Dark is © Rare / Microsoft; the 2010 Xbox Live Arcade release's art is 4J Studios' and Rare's, and is supplied by you, never by this project. This project is not affiliated with, endorsed by, or connected to any of them.
