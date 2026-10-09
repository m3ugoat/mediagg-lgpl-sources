# VLCKit for Mediagg

`build.sh` builds VLCKit 3 (libVLC 3.0) for Mediagg as **dynamic** xcframeworks, with the
patent-live software decoders removed and no GPL code:

| Output (in `out/`, gitignored) | Slices |
|---|---|
| `MobileVLCKit.xcframework` | iOS arm64, iOS simulator arm64 |
| `TVVLCKit.xcframework` | tvOS arm64, tvOS simulator arm64 |
| `vlc-plugins-iPhone.h`, `vlc-plugins-AppleTV.h` | the generated `vlc_static_modules` lists |

Each slice carries its dSYM, which is what the decoder check reads.

```sh
vlckit/build.sh                     # iOS + tvOS, then verify
vlckit/build.sh ios                 # one platform (ios|tvos), then verify
vlckit/build.sh verify              # re-check out/
vlckit/build.sh licenses [AppleTV]  # licence of every static module, from its sources
```

It needs a Mac with Xcode (tested with Xcode 27.0) and network access on the first run
(VLCKit, libVLC and contrib tarballs). Nothing comes from Homebrew: VLC's `extras/tools`
builds its own autotools, cmake, meson, ninja and gas-preprocessor. Checkouts and build trees
(about 20 GB) live in `vlckit/work/`, or in `$VLCKIT_WORK_DIR` if set. A re-run reuses
them and rebuilds only what changed.

**Time** (12-core Apple Silicon Mac, Xcode 27): 8–18 minutes per platform from scratch. Each
platform builds the contribs and libVLC twice, for device and for simulator. The first run
also clones VLC and builds VLC's tools (cmake among them), which takes roughly another
15 minutes. A re-run after a patch change takes about 7 minutes per platform.

## Pinned inputs

`VLCKIT_REF` in `build.sh` is the only version setting. VLCKit pins libVLC (`TESTEDHASH` in
its `buildMobileVLCKit.sh`), and libVLC pins every contrib tarball by SHA-512, including
FFmpeg 8.1.2. To move VLCKit, change the ref and re-run; if a patch no longer applies, the
build stops.

VLCKit is driven with `buildMobileVLCKit.sh -v -a aarch64`, plus `-t` for tvOS. `-a aarch64`
builds arm64 only (no x86_64 simulator, no 32-bit) and implies `-f`, so the output is
dynamic xcframeworks. `-w` is not used: it drops avcodec entirely, and with it AAC,
AC-3 and the PGS/DVB subtitle decoders.

## Patches

`patches/vlckit/0001-…patch` changes VLCKit's `buildMobileVLCKit.sh`:

- with `-a aarch64` the script built both libVLC slices but packaged only the device
  one. It now packages the arm64 simulator slice too;
- deployment targets come from `VLCKIT_IOS_MIN` / `VLCKIT_TVOS_MIN` (build.sh sets iOS 16.0
  and tvOS 17.0, the apps' targets), and `TVOS_DEPLOYMENT_TARGET` now reaches xcodebuild;
- two hooks, `VLCKIT_EXTRA_CONFIGURE` (extra libVLC `configure` switches) and
  `VLCKIT_EXTRA_BLACKLIST` (static modules to delete after the build);
- the contribs are built with `--disable-zvbi` instead of `--enable-zvbi` (see below);
- **build fix:** the ninja that `extras/tools` builds (1.13, Kitware's jobserver variant)
  joins make's jobserver. Apple's make 3.81 offers a pipe jobserver, so ninja aborts
  ("Could not initialize jobserver") or leaves the pipe non-blocking and make dies ("read jobs
  pipe: Resource temporarily unavailable"). The patch wraps ninja to ignore make's jobserver
  (default `-j4`, or `$NINJA_JOBS`).

`patches/libvlc/*.patch` are copied into VLCKit's `libvlc/patches/`, so VLCKit's own `git am`
applies them after its own patches:

- `9001` changes `contrib/src/ffmpeg/rules.mak`. It adds
  `--disable-decoder='h264*,hevc*,vvc*,ac4*,libopenh264' --disable-decoder=truehd
  --disable-decoder=mlp` and applies `mediagg-dca-core-only.patch` to FFmpeg. That patch
  makes the `dca` decoder's `core_only` option default to 1, and `dcadec_init` forces it to
  1 whatever a caller sets. As a result, the DTS-HD extensions (EXSS: XLL, XBR, X96, LBR;
  XCH/XXCH/X96 inside the core) are never parsed. Plain DTS still decodes, a DTS-HD MA
  track plays as its lossy core, and DTS Express (LBR only) does not play.
- `9002` removes the GPL Yadif code (`yadif.h`, `yadif_template.h`, copied from FFmpeg)
  from the otherwise LGPL deinterlace module. The `yadif` and `yadif2x` mode names still
  work and use the X and Linear algorithms.

## What is removed, and why

| Removed | Why |
|---|---|
| FFmpeg `h264`, `hevc`, `vvc` and their hardware-wrapper variants | patents still live. H.264 and HEVC still play in hardware through VLC's own `videotoolbox` module, which does not use FFmpeg's decoders. Nothing decodes them in software. |
| FFmpeg `truehd`, `mlp` | Dolby patents still live |
| DTS-HD extensions in FFmpeg `dca` | DTS-HD patents still live; the DTS core is kept |
| libVLC `dca` (libdca), `a52` (liba52), `faad`, `libmpeg2`, `mad`, `postproc`, x262/x264/x265, `css`, `sid`, `realrtsp` | GPL libraries or modules. FFmpeg decodes AC-3, MPEG-1/2 video, AAC and MP3 under the LGPL. |
| contrib `zvbi` and libVLC's `zvbi` module | libzvbi 0.2.45 compiles GPL-2 files (`packet-830.c`, `pdc.c`) into the library. VLC's own LGPL `telx` module decodes teletext instead. |
| modules `dolby_surround_decoder`, `dummy`, `mono`, `rotate`, `stream_out_rtp`, `syslog`, `vod_rtsp` | their sources are GPL (`build.sh licenses` flags them). VLCKit's own blacklist already drops the other GPL modules (stats, logger, export, sap, podcast, mediadirs, audioscrobbler, hotkeys, gestures, oldrc, netsync, motion, t140, real, visual, remoteosd, hqdn3d, headphone). |
| contribs are built with `--disable-gpl --disable-gnuv3` (VLCKit default) | FFmpeg is configured without `--enable-gpl` or `--enable-nonfree` (`CONFIG_GPL 0`, `CONFIG_NONFREE 0`) |

Kept: AAC, AC-3, **E-AC-3** (its last US patent, US7516064, expired 2026-01-30), MP1/2/3,
MPEG-1/2 video, MPEG-4 part 2, VC-1/WMV, VP8/VP9 (libvpx and FFmpeg), AV1 (dav1d), Opus,
Vorbis, FLAC, ALAC, PCM, and every subtitle decoder (PGS, DVD, DVB, SSA/ASS via libass,
SRT, WebVTT, TTML, teletext via `telx`). FFmpeg also builds its AudioToolbox wrappers
(`aac_at`, `ac3_at`, `eac3_at`, …), which hand decoding to Apple's own decoders.

The contribs linked in are all LGPL or permissive: FFmpeg (LGPL build), live555, libdvbpsi,
libebml/libmatroska, taglib, fribidi, libplacebo, soxr, spatialaudio, mpg123, lame, twolame,
libshout, libgcrypt/libgpg-error/libtasn1, libsmb2, libdsm, libnfs (all LGPL); dav1d, aom,
libvpx, ogg/vorbis/opus/speex/theora/FLAC, libass, harfbuzz, libxml2, libarchive, libupnp,
librist, libssh2, protobuf, libmysofa, openjpeg, libebur128, gsm, libpng, zlib, utfcpp
(BSD/MIT/ISC-style); libmodplug (public domain); freetype (used under the FreeType License,
which requires a credit in the app's acknowledgements). The LGPL libraries need the usual
LGPL notices, and because the framework is dynamic, users can replace it.

## Verify

`build.sh verify` runs these checks on every slice and fails on any miss:

```sh
X=vlckit/out/MobileVLCKit.xcframework/ios-arm64
otool -hv $X/MobileVLCKit.framework/MobileVLCKit        # filetype DYLIB, not an ar archive
file $X/MobileVLCKit.framework/MobileVLCKit             # Mach-O 64-bit dynamically linked shared library arm64
# The shipped binary has no local symbols left; the dSYM keeps the full symbol table.
nm $X/dSYMs/MobileVLCKit.framework.dSYM/Contents/Resources/DWARF/MobileVLCKit \
  | grep -E '_ff_(h264|hevc|vvc|truehd|mlp|aac|ac3|eac3|dca|pgssub)_decoder$'
#   must list aac, ac3, eac3, dca and pgssub, and none of h264, hevc, vvc, truehd, mlp
grep videotoolbox vlckit/out/vlc-plugins-iPhone.h  # the hardware decoder is linked in
grep 's->core_only = 1;' vlckit/work/VLCKit/libvlc/vlc/contrib/*/ffmpeg/libavcodec/dcadec.c
```

`build.sh licenses` reads the DWARF of every static module and of libvlccore. Each
compile unit names a source file, whose header gives its licence, and the line tables name
every header that contributed code. Any GPL-only file is flagged. On the current build it
reports 236 archives for iOS and 233 for tvOS, none with a GPL-only file.
