# work/curl-* provenance — static libcurl 8.11.0 for the four Apple slices

D-010 (the decision) and `docs/curl-options.md` (its brief) chose option 1:
vendor the static curl the family already builds, rather than write an
NSURLSession backend or ship without Community Packs. Nothing here is copied
and nothing is committed — each `work/curl-<sdk>/` is a two-symlink tree
(`lib/libcurl.a`, `include/curl`) pointing into `~/dev/q2repro-ios/work`, the
same posture as ANGLE and SDL2 in `deps-PROVENANCE.md`.

Recreate the whole set:

```sh
cd ~/dev/perfect-dark-ios
Q=~/dev/q2repro-ios/work
for pair in curl-iphoneos:ios-deps curl-iphonesimulator:ios-sim-deps \
            curl-xros:xros-deps     curl-xrsimulator:xros-sim-deps; do
  n=${pair%%:*}; s=${pair##*:}
  mkdir -p work/$n/lib work/$n/include
  ln -sfn $Q/$s/prefix/lib/libcurl.a  work/$n/lib/libcurl.a
  ln -sfn $Q/$s/prefix/include/curl   work/$n/include/curl
done
```

## What the bits are

**curl 8.11.0**, source `https://curl.se/download/curl-8.11.0.tar.gz`, built by
`~/dev/q2repro-ios/scripts/build-curl-ios.sh [device|simulator]` and
`build-curl-visionos.sh [device|simulator]`. Configuration (both scripts):

    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF
    -DHTTP_ONLY=ON
    -DCURL_USE_SECTRANSP=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=OFF
    -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_LIBIDN2=OFF
    -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DENABLE_UNIX_SOCKETS=OFF

HTTP(S) only, TLS by Apple **SecureTransport** — so there is no second library
to vendor and **no CA bundle to ship**: SecureTransport validates against the
system trust store (proved end to end, M-024).

## The four slices, verified before reuse

`lipo -info` says `arm64` for all four and cannot tell them apart; the Mach-O
`LC_BUILD_VERSION` platform is what was actually asserted
(`otool -l … | grep -A2 LC_BUILD_VERSION`), exactly as `build-ios.sh` does for
`libpd.a`:

| link | source | platform | minos | bytes |
|---|---|---|---|---|
| `work/curl-iphoneos` | `q2repro-ios/work/ios-deps/prefix` | **2** (iOS) | 15.0 | 1,124,264 |
| `work/curl-iphonesimulator` | `…/ios-sim-deps/prefix` | **7** (iOS sim) | 15.0 | 1,123,744 |
| `work/curl-xros` | `…/xros-deps/prefix` | **11** (xrOS) | 26.0 | 1,136,320 |
| `work/curl-xrsimulator` | `…/xros-sim-deps/prefix` | **12** (xrOS sim) | 26.0 | 1,135,880 |

`include/curl/curlver.h` says `LIBCURL_VERSION "8.11.0"` in all four.

The sibling's prefixes also hold ffmpeg; only `libcurl.a` and `include/curl`
are linked here, so nothing else can leak onto the include path.

## If the sibling goes away

Re-run the sibling's two scripts in `~/dev/q2repro-ios` (they fetch the tarball
themselves and take a couple of minutes per slice), then re-make the symlinks:

```sh
cd ~/dev/q2repro-ios
scripts/build-curl-ios.sh device;      scripts/build-curl-ios.sh simulator
scripts/build-curl-visionos.sh device; scripts/build-curl-visionos.sh simulator
```

They are not copied into this repo on purpose: one recipe, one place to fix,
and the deployment targets (iOS 15.0 / xrOS 26.0) already match this port's.

## Licence

curl is under the curl licence (MIT/X derivative) — attribution only, same
shelf as RARLAB's unrar note. `work/curl-*/include/curl/` is the sibling's
install; the licence text ships with the upstream tarball
(`curl-8.11.0/COPYING`).
