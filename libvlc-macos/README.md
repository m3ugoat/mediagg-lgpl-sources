# libVLC for macOS, for Mediagg

`build.sh` builds libVLC 3.0 for macOS for Mediagg for Mac, Mediagg's
Tauri desktop app. The app loads libVLC at runtime with `libloading`
(`desktopApp/src-tauri/src/vlc.rs`) and uses only libVLC's public C API. The output follows
the same rules as [`../vlckit`](../vlckit): the patent-live software decoders are removed,
there is no GPL code, and everything is linked **dynamically**.

| Output (in `out/`, gitignored) | What |
|---|---|
| `vlc/lib/libvlc.dylib` → `libvlc.5.dylib`, `libvlccore.dylib` → `libvlccore.9.dylib` | the library, universal (arm64 + x86_64) |
| `vlc/plugins/<category>/lib*_plugin.dylib` | the modules (231), universal |
| `vlc/licenses/` | libVLC's LGPL, and the licence files of every contrib library linked in |
| `dSYMs/` | the symbols of every dylib (not shipped; `verify` reads them) |
| `include/vlc/` | libVLC's headers (not shipped; the play test compiles against them) |
| `archs.txt`, `removed-modules.txt` | what was built and which modules were deleted |

`out/vlc` is the directory the app ships as `Contents/Frameworks/vlc`. `vlc.rs` loads
`Contents/Frameworks/vlc/lib/libvlc.dylib` and sets `VLC_PLUGIN_PATH` to
`Contents/Frameworks/vlc/plugins`. The tree is relocatable: `libvlc` finds `libvlccore` through
`@rpath` = `@loader_path`, and each module through `@loader_path/../../lib`. No absolute path is
left in it. Every dylib is stripped and ad-hoc signed, and the app re-signs them when it signs
the bundle. The minimum is macOS 13.0, the app's minimum. VLC compiles `videotoolbox` and `cvpx`
for an older minimum (10.8; arm64 records 11.0), which also loads on 13.

```sh
libvlc-macos/build.sh                   # arm64 and x86_64, lipo, then verify
libvlc-macos/build.sh arm64             # one architecture (arm64|x86_64), then verify
libvlc-macos/build.sh assemble [arch…]  # out/ again from the built trees, then verify
libvlc-macos/build.sh verify            # re-check out/
libvlc-macos/build.sh licenses          # licence of every module, from its sources
```

The build needs a Mac with Xcode (tested with Xcode 27.0, macOS SDK 27.0, on Apple silicon)
and network access on the first run (VLC and the contrib tarballs). Nothing comes from
Homebrew. VLC's `extras/tools` builds its own autotools, cmake, meson, ninja and pkg-config,
and every step runs under `env -i` with only the system `PATH`. CMake 4 on macOS still
searches `/opt/homebrew` on its own, which put Homebrew's mbedtls into librist. `build.sh`
removes that search from the CMake it builds. After the contribs it also fails the build if
an installed `.pc`, CMake or `.la` file refers to `/opt/homebrew` or `/usr/local`. The play
test uses only Xcode's clang. The test clips in `test/` were made once with FFmpeg's
VideoToolbox encoders. Checkouts and build trees (about 6 GB per architecture) live in
`libvlc-macos/work/`, or in `$LIBVLC_MACOS_WORK_DIR` if set.

**Time** (12-core Apple silicon Mac, Xcode 27): VLC's tools take about 4 minutes, once.
Each architecture then takes about 4 minutes for the contribs and 4 minutes for libVLC.
Assembling, which runs `dsymutil` on 233 dylibs, takes about 7 minutes, and verify takes about
6 minutes. A full first run with both architectures takes about 35 minutes. The output is
107 MB for `out/vlc` (universal; 50 MB for arm64 alone) and 437 MB for the dSYMs. x86_64 is
cross-compiled on Apple silicon (`--host=x86_64-apple-darwin…`), and `verify` plays it under
Rosetta.

## Pinned inputs

`VLC_REF` in `build.sh` is the libVLC commit: `6de05adc`, tag 3.0.24, which is the
`TESTEDHASH` that VLCKit `b2edca9c` (3.7.4) pins and so the same libVLC that `../vlckit`
builds. VLC pins every contrib tarball by SHA-512, FFmpeg 8.1.2 among them.

The build follows VLC's own `extras/package/macosx/build.sh`: the same toolchain
environment, `extras/tools`, contribs **from source** (never the prebuilt contribs, so that the
FFmpeg patch takes effect), and then `configure` and `make install`. It does not run that
script itself, because the script cannot pass flags to the contrib `bootstrap` and it builds
VLC.app with the GPL GUI.

## Patches

Applied to the VLC checkout in this order:

- `patches/libvlc/0007-contrib-use-live555-version-…patch` is **VLCKit's own** libvlc patch,
  copied unmodified. It pins live555 2016.10.21, the last LGPL-2.1 release. The current
  live555 is LGPL-3, and `--disable-gnuv3` leaves it out, which leaves no RTSP input. VLCKit
  applies the same patch. VLCKit's other libvlc patches are for its Objective-C API or for
  iOS, and the desktop app does not use them.
- `../vlckit/patches/libvlc/9001`: FFmpeg without the H.264, HEVC, VVC, TrueHD and MLP
  decoders, and DTS core only.
- `../vlckit/patches/libvlc/9002`: the deinterlace module without the GPL Yadif code.

`vlckit/README.md` describes both patches. They are shared, so a change to them changes
both builds.

## What is removed, and why

The same as `../vlckit`:

- **Contribs:** VLCKit's contrib `bootstrap` switches, including its macOS ones and
  `--disable-zvbi`. They start with `--disable-gpl --disable-gnuv3`, so FFmpeg is
  configured without `--enable-gpl` or `--enable-nonfree`.
- **libVLC configure:** VLCKit's switches, and `vlckit/build.sh`'s `EXTRA_CONFIGURE`
  unchanged (`--disable-dca --disable-libmpeg2 --disable-postproc --disable-x26*
  --disable-css --disable-sid --disable-fdkaac --disable-shine --disable-zvbi --enable-telx
  --disable-realrtsp`).
- **Modules deleted after the build:** VLCKit's blacklist, where every module whose file
  name contains the string is deleted, and `vlckit/build.sh`'s `EXTRA_BLACKLIST`. 72 modules
  are deleted; `out/removed-modules.txt` lists them.

Beyond VLCKit, because this is a desktop build of shared modules rather than a static iOS
framework:

| Also off | Why |
|---|---|
| `--disable-macosx`, no `vlc` binary, no VLC.app | VLC's macOS GUI is GPL. The NSView video outputs that `libvlc_media_player_set_nsobject` uses (`vout_macosx`, `caopengllayer`) are separate LGPL modules and are kept. |
| `--disable-macosx-avfoundation` | camera and screen capture, which the app does not need. VLCKit turns it off too. |
| `--disable-osx-notifications`, `--disable-sparkle`, `--disable-ncurses`, `--disable-xcb`, `--disable-caca`, `--disable-sdl-image`, `--disable-vnc`, `--disable-skins2`, `--disable-qt` | GUIs and app features of VLC.app that VLC's own macOS `configure.sh` also turns off or that need GPL contribs |
| `--enable-merge-ffmpeg` (as VLC.app) | avformat is linked into the `avcodec` module, so FFmpeg is in one dylib instead of two |

Kept: the same decoders as VLCKit. H.264 and HEVC play only in hardware, through VLC's
`videotoolbox` module.

The contribs linked in are LGPL or permissive: FFmpeg (LGPL build), live555 2016.10.21,
libdvbpsi, libebml/libmatroska, taglib, fribidi, libplacebo, soxr, spatialaudio, mpg123, lame,
libshout, libgcrypt/libgpg-error/libtasn1, libsmb2, libdsm, libnfs (LGPL); dav1d, aom, libvpx,
ogg/vorbis/opus/speex/theora/FLAC, libass, harfbuzz, libxml2, libarchive, libupnp, librist,
libssh2, protobuf, libmysofa, openjpeg, gsm, libpng, zlib, utfcpp (BSD/MIT/ISC-style);
libmodplug (public domain); freetype (FreeType License, which needs a credit in the app's
acknowledgements). `out/vlc/licenses/contribs/<name>/` holds each one's licence files. The app
must show the LGPL notices and offer the source of this build (this repository and its
patches); this is the bible's open issue 30.

## Verify

`build.sh verify` fails on any miss. It checks:

1. **Dynamic and relocatable.** Every file in `out/vlc` is a Mach-O `DYLIB` (`otool -hv`), for
   exactly the architectures in `archs.txt` (`lipo -archs`), and loads on macOS 13. It refers
   only to `/System/Library`, `/usr/lib`, `@rpath/libvlc*.dylib` or `@loader_path`
   (`otool -L`, `LC_RPATH`), and has a dSYM.
2. **Decoders.** FFmpeg is linked statically into the modules, mostly `codec/libavcodec_plugin`.
   `nm` of every dSYM, for each architecture, must have none of `ff_h264_decoder`,
   `ff_hevc_decoder`, `ff_vvc_decoder`, `ff_truehd_decoder` and `ff_mlp_decoder`. The same dSYMs
   must have AAC, AC-3, E-AC-3, DTS, PGS, DVD and DVB subtitles, MPEG-2, MPEG-4, VC-1, VP9,
   FLAC, ALAC and MP3 (the same lists as `vlckit/build.sh`).
3. **Modules.** `videotoolbox`, `avcodec`, `vout_macosx`, `caopengllayer` and `auhal` must be
   present, and no blacklisted module may be shipped.
4. **DTS core only.** The FFmpeg source that was built contains `s->core_only = 1;`.
5. **No GPL module.** `build.sh licenses` reads the DWARF in each dSYM. Its compile units name
   the `.c`/`.m` files, and its line tables name every header that contributed code. A module
   fails if any of those files in the VLC tree is GPL-only. The latest build had 233 dylibs,
   none flagged.
6. **It plays.** `test/play.c` is built with clang against `out/include`. `out/vlc` is copied
   to a temporary directory, as the app will copy it. The test `dlopen`s `lib/libvlc.dylib`
   there with `VLC_PLUGIN_PATH` set and `--vout=dummy --aout=dummy`, and plays
   `test/h264-aac.mp4` and `test/hevc-eac3.mkv` for a second each. It must reach Playing and
   decode both audio and video. Each architecture is tested (x86_64 under Rosetta on Apple silicon). It prints the decoder modules it used: `videotoolbox` for
   H.264 and HEVC, `avcodec` for AAC and E-AC-3.

## Publishing

`release.sh <n>` publishes `out/` as release `libvlc-macos-3.0.24-mediagg.<n>`. It runs
`verify` first and uploads `libvlc-macos.zip` (the `vlc/` tree, made with `ditto`, which keeps
the symlinks), the dSYMs, the headers, `BUILD-INFO.txt` and `SHA256SUMS`. A release is never
replaced.
