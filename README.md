# Mediagg — LGPL sources

The Mediagg app (iPhone, Apple TV, Android, Mac) ships libraries licensed under the **GNU Lesser
General Public License, version 2.1 or later**: libVLC and VLCKit on iPhone and Apple TV, libVLC on
the Mac, and FFmpeg on all of them. This repository is how we meet that licence: the exact upstream versions we build, every
change we make to them, and the scripts that build what ships — so anyone can rebuild those
libraries, change them, and use their own build in place of ours.

The app itself is not open source. The LGPL libraries are linked dynamically (iPhone, Apple TV), loaded
as libraries of their own (Mac), or kept to their own native library (Android), as the licence
requires.

## iPhone and Apple TV — VLCKit and libVLC

| | |
|---|---|
| VLCKit | 3.7.4 — `https://code.videolan.org/videolan/VLCKit.git` at `b2edca9ca041eafad1408ee91a55e6d87f7e23d5` |
| libVLC | 3.0.x — `https://code.videolan.org/videolan/vlc.git`, branch `3.0.x`, at `6de05adc` (VLCKit's own pin, `TESTEDHASH`) |
| FFmpeg, and libVLC's other contribs | the versions libVLC's `contrib/src/*/` pins at that commit, each by SHA-512 — FFmpeg 8.1.2 among them |
| Our changes | [`vlckit/patches/`](vlckit/patches) — what each does, and why, is in [`vlckit/README.md`](vlckit/README.md) |
| How it is built | [`vlckit/build.sh`](vlckit/build.sh): dynamic xcframeworks for iPhone and Apple TV, arm64 device and simulator |

Our changes remove decoders still under patent licence (software H.264, HEVC, VVC, Dolby TrueHD/MLP;
DTS decodes its core only) and every GPL component, and add build switches. They add nothing.

To rebuild: a Mac with Xcode, then `vlckit/build.sh` — see `vlckit/README.md` for what it needs and
how long it takes. To use your own build with the app, replace `MobileVLCKit.framework` (iPhone) or
`TVVLCKit.framework` (Apple TV) inside the app bundle with yours, and re-sign it.

## Mac — libVLC

| | |
|---|---|
| libVLC | 3.0.24 — `https://code.videolan.org/videolan/vlc.git` at `6de05adcbaf2e8b85fe86aad4169393098628119`, the same libVLC as the iPhone's |
| FFmpeg, and libVLC's other contribs | the versions libVLC's `contrib/src/*/` pins at that commit, each by SHA-512 — FFmpeg 8.1.2 among them |
| Our changes | the iPhone's two libVLC patches ([`vlckit/patches/libvlc`](vlckit/patches/libvlc)) and VLCKit's own live555 pin ([`libvlc-macos/patches/libvlc`](libvlc-macos/patches/libvlc)) — what each does is in [`libvlc-macos/README.md`](libvlc-macos/README.md) |
| How it is built | [`libvlc-macos/build.sh`](libvlc-macos/build.sh): dynamic libraries and modules, arm64 and x86_64, for macOS 13 or later |

To rebuild: a Mac with Xcode, then `libvlc-macos/build.sh all` — see `libvlc-macos/README.md`. The app
loads libVLC from `Mediagg.app/Contents/MacOS/vlc` (`lib/`, `plugins/`); to use your own build, put
yours there and re-sign the app. The licence notices are in `Mediagg.app/Contents/Resources/vlc-licenses`.

## Android — FFmpeg

| | |
|---|---|
| FFmpeg | `https://github.com/FFmpeg/FFmpeg.git`, tag `n6.0.1` (`c41ff724ede7da657762d61097e26fac296c53bf`) |
| Decoders | `flac alac ac3 eac3 dca` — DTS (`dca`) decodes its core only |
| Our change | one line: FFmpeg's own `core_only` option for DTS switched on, in [`ffmpeg-android/build-ffmpeg.sh`](ffmpeg-android/build-ffmpeg.sh) |
| How it is built | [`ffmpeg-android/build-ffmpeg.sh`](ffmpeg-android/build-ffmpeg.sh), which runs Media3's [`build_ffmpeg.sh`](ffmpeg-android/build_ffmpeg.sh) unmodified (Apache-2.0, The Android Open Source Project) |

To rebuild: the Android NDK the script names, then `ffmpeg-android/build-ffmpeg.sh`.

## Source on request

Everything above is the complete corresponding source: the upstream projects at the commits named,
plus this repository. If any of it is ever unavailable upstream, or you would rather have it from us,
open an issue here and we will provide the complete source — for at least three years after the last
release of the app that uses it.

## Licences

libVLC, VLCKit and FFmpeg are LGPL-2.1-or-later; their full texts are in each upstream project, and
the LGPL 2.1 is in [`COPYING.LGPL-2.1`](COPYING.LGPL-2.1). The patches here are under the licence of
what they patch. The build scripts in this repository are released under the same terms
(LGPL-2.1-or-later), except Media3's `build_ffmpeg.sh`, which is Apache-2.0 as its header says.
