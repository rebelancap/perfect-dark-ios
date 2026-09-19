# work/ dependency provenance

Everything here is a **symlink** into a sibling port's tree — nothing is copied
and nothing is committed (disk hygiene: "don't duplicate what can be linked").
Recreate the whole set with the `ln -sfn` lines below; each entry says where the
bits actually came from and how to rebuild them from source if the sibling ever
goes away.

```sh
cd ~/dev/perfect-dark-ios
ln -sfn ~/dev/realrtcw-ios/work/angle/out/ios-arm64-device    work/angle-ios-device
ln -sfn ~/dev/realrtcw-ios/work/angle/out/ios-arm64-simulator work/angle-ios-simulator
ln -sfn ~/dev/realrtcw-ios/work/angle/out/mac-arm64           work/angle-mac
ln -sfn ~/dev/realrtcw-ios/work/angle/include                 work/angle-include
ln -sfn ~/dev/dhewm3-ios/work/deps-iphoneos                   work/deps-iphoneos
ln -sfn ~/dev/dhewm3-ios/work/deps-iphonesimulator            work/deps-iphonesimulator
scripts/make-angle-xcframeworks.sh          # work/angle-xcframeworks, from the two slices
```

## ANGLE — `work/angle-ios-{device,simulator}`, `work/angle-mac`, `work/angle-include`

ANGLE 2.1.1, git `e25e8d8565f7`, built Metal-only/release (`args.gn` sits beside
each slice). The one checkout in `~/dev` is `~/dev/realrtcw-ios/work/angle`
(14 GB with `work/depot_tools`); see that repo's `work/angle-PROVENANCE.md`.
The macOS slice was added to it by this project's Phase 0.5 spike
(`docs/angle-spike.md` §1).

- iOS slices are **frameworks** (`libEGL.framework`, `libGLESv2.framework`),
  not dylibs — the macOS slice is dylibs. `scripts/build-ios.sh` and overlay
  patch 0008 handle both shapes.
- `work/angle-xcframeworks/` is built locally from the two iOS slices by
  `scripts/make-angle-xcframeworks.sh`; Xcode cannot pick device vs simulator
  out of a plain `.framework` path (dhewm3-ios earned that one).
- Rebuild from source: `~/dev/q2repro-ios/scripts/build-angle-ios.sh`
  (hours of gn/ninja on a 14 GB Chromium tree).

## SDL2 — `work/deps-{iphoneos,iphonesimulator}`

**SDL2 2.32.8** (`release-2.32.8`), static, arm64, `minos 15.0`, SDK 26.5, built
by `~/dev/dhewm3-ios/scripts/build-sdl2-ios.sh`. Verified before reuse:

```
deps-iphoneos/lib/libSDL2.a         arm64, LC_BUILD_VERSION platform 2 (iOS),        minos 15.0
deps-iphonesimulator/lib/libSDL2.a  arm64, LC_BUILD_VERSION platform 7 (iOS sim),    minos 15.0
include/SDL2/SDL_version.h          2.32.8
```

Reused rather than rebuilt because it is the identical recipe — same tag, same
deployment target, same arch — and a second copy would be a second 200 MB build
tree for nothing. The prefixes also carry `libSDL3.a` and `libopenal.a`, which
this port does not link.

Rebuild from source (into these same prefix names) with
`~/dev/dhewm3-ios/scripts/build-sdl2-ios.sh {device,simulator}`.

Note: the **macOS oracle** uses Homebrew's `sdl2`, which is `sdl2-compat`
(SDL2's API over SDL3) — D-007. The iOS builds use real SDL2 from source, as
that decision said they would.

## visionOS (Phase 5)

### ANGLE — `work/angle-visionos-{device,simulator}`

Symlinks into the SAME ANGLE checkout as the iOS slices:

```
work/angle-visionos-device     -> ~/dev/realrtcw-ios/work/angle/out/visionos-arm64-device
work/angle-visionos-simulator  -> ~/dev/realrtcw-ios/work/angle/out/visionos-arm64-simulator
```

Already built there; nothing was rebuilt for this port. Recreate with:

```sh
ln -sfn ~/dev/realrtcw-ios/work/angle/out/visionos-arm64-device    work/angle-visionos-device
ln -sfn ~/dev/realrtcw-ios/work/angle/out/visionos-arm64-simulator work/angle-visionos-simulator
```

`vtool -show-build` on both `libEGL`/`libGLESv2`: platform VISIONOS /
VISIONOSSIMULATOR, **minos 26.0**, sdk 26.5. That 26.0 is the floor for the
whole visionOS side of this port — Chromium links `libclang_rt.xros.a`, which
is 26.0-only (dhewm3-ios found the same). `XROS_DEPLOYMENT_TARGET` and
`CMAKE_OSX_DEPLOYMENT_TARGET` are 26.0 everywhere because of it.
Rebuild recipe: `~/dev/q2repro-ios/scripts/build-angle-visionos.sh`.

### SDL2 — `work/deps-{xros,xrsimulator}`, built HERE

Not symlinked: nothing on the machine had one.
`~/dev/dhewm3-ios/work/deps-xros` is **SDL3** (that port moved), and
`~/dev/sm64coopdx-ios`'s xrOS `libSDL2.a` is 2.32.10 built inside its own CMake
tree with a supersampling patch we do not want.

`scripts/build-sdl2-visionos.sh {xros,xrsimulator}` clones SDL at
`release-2.32.8` (the same tag as the iOS slices) into `work/sdl2-visionos/src`,
applies `overlay/sdl2/visionos-compat.patch`, and installs
`lib/libSDL2.a` + `include/SDL2/` into `work/deps-$KIND`. Both are asserted to
report the right Mach-O platform (11 XROS / 12 XROSSIMULATOR, minos 26.0).

SDL 2.32 predates visionOS and its UIKit backend does not compile for xros at
all; the patch is the minimal compat set (UIScreen-free virtual display,
scene-driven window frame, `displayScale` for `nativeScale`, status-bar and
launch-image gates). Its header carries the full provenance and the two
sm64coopdx hunks deliberately dropped. `SDL_OPENGLES`/`SDL_OPENGL` are OFF:
GLES does not exist on xrOS and the context comes from ANGLE-Metal (D-008).

## zlib

From the iOS SDK (`libz.tbd`), found by CMake's `FindZLIB`. Nothing staged.

## libcurl — deliberately absent

`scripts/build-ios.sh` passes `-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON`. Without
it a cross build happily finds `/opt/homebrew`'s x86/arm64 macOS libcurl and
links a macOS dylib into an iOS binary. `PD_HAVE_CURL` off means
`ghostnet.c`'s stub transport, which is upstream's own supported configuration
(charter 0.7 default; `docs/curl-options.md`).

## Game data — `work/gamedata/`

See `work/gamedata-PROVENANCE.md`. Never committed, never bundled.
