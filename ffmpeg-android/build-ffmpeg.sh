#!/bin/bash
#
# Builds the FFmpeg half of :core:decoder-ffmpeg — the static libraries and headers the JNI wrapper
# links against — and puts them in src/main/jni/ffmpeg, where CMakeLists.txt looks for them.
#
# Run it again only to change what is in there: the FFmpeg version, the decoders, the NDK. Its
# output is committed, so an ordinary build needs neither this script nor FFmpeg's source.
#
#     core/decoder-ffmpeg/build-ffmpeg.sh              # uses the NDK named below
#     NDK_PATH=/path/to/ndk core/decoder-ffmpeg/build-ffmpeg.sh
#
# **The build itself is upstream's `src/main/jni/build_ffmpeg.sh`, unmodified.** This script only
# pins what that one takes as arguments, and copies the result into place. Keep it that way: the
# day Media3 changes how FFmpeg is configured, updating is copying their file over ours.
#
# **Decoders: only what Android does not guarantee.** The platform must decode AAC, FLAC, MP3,
# Opus and Vorbis, and the player asks FFmpeg only once MediaCodec has said no — see
# `EXTENSION_RENDERER_MODE_ON` in PlayerFactory — so a decoder for any of those would be carried by
# every install and used by almost none. The ones here are the ones a real library turns up that a
# phone may not have:
#
#   ac3 eac3   Dolby Digital and Digital Plus. Most Jellyfin films. Their patents have run out —
#              AC-3's in 2017, E-AC-3's last (US7516064) on 2026-01-30.
#   dca        DTS — **its core only** (see below). Rare on phones.
#   alac       Apple Lossless, in .m4a — any library ripped with Apple's tools.
#   flac       Guaranteed by the platform only from API 27, and minSdk is 23.
#
# **Left out on purpose, because it is still under patent licence: truehd (Dolby TrueHD, built on
# Meridian Lossless Packing).** A decoder this app ships is a decoder this app would need a licence
# for. Where the phone or television has its own, or passes TrueHD to a receiver, MediaCodec plays
# it exactly as before; where it has neither, `MediaUrlFactory` asks Jellyfin to convert just the
# sound and copy the picture. The bible's video-codecs page has the reasoning and how to put it back.
#
# **DTS decodes its core and nothing more.** Every DTS-HD track carries a plain DTS core, whose
# patents have run out; the lossless and high-resolution extensions (XLL, XBR, X96) are newer. So
# FFmpeg's `core_only` option, off by default, is switched on in the source before it is built —
# the JNI wrapper is upstream's, unmodified, and has no way to pass a decoder option.
#
# Names are FFmpeg's, and must match what `FfmpegLibrary.getCodecName` asks for.
#
# **LGPL, not GPL.** FFmpeg's configure leaves out every GPL component unless told
# `--enable-gpl`, and upstream's script never says it, so what this builds is LGPL-2.1-or-later.
# Nothing here should ever add that flag.
set -euo pipefail

FFMPEG_TAG="n6.0.1" # Media3 1.11.0's README recommends the 6.0 branch.
DECODERS=(flac alac ac3 eac3 dca)
# Must not exceed minSdk (gradle/libs.versions.toml). The 64-bit ABIs are raised to 21 by the
# upstream script if this is lower; it is not.
ANDROID_API=23
# r28 or newer: it links with 16 KB page alignment by default, which Android 15 devices with 16 KB
# pages require of every native library, and Google Play requires of every update.
NDK_PATH="${NDK_PATH:-$HOME/Library/Android/sdk/ndk/28.1.13356709}"

MODULE="$(cd "$(dirname "$0")" && pwd)"
OUT="$MODULE/src/main/jni/ffmpeg"
WORK="$MODULE/build/ffmpeg-build"

case "$(uname -s)" in
    Darwin) HOST_PLATFORM="darwin-x86_64" ;; # The NDK's only macOS toolchain; universal binaries.
    Linux) HOST_PLATFORM="linux-x86_64" ;;
    *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

# Upstream's script expects `<module>/jni/ffmpeg` to be the FFmpeg source tree, so the source and
# the script are laid out that way in a scratch directory, well away from anything committed.
rm -rf "$WORK"
mkdir -p "$WORK/main/jni"
cp "$MODULE/src/main/jni/build_ffmpeg.sh" "$WORK/main/jni/"
git clone --quiet --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git \
    "$WORK/main/jni/ffmpeg"

# DTS core only — see above. Fails the build rather than shipping the extensions if the line moved.
DCADEC="$WORK/main/jni/ffmpeg/libavcodec/dcadec.c"
grep -q '"core_only", "Decode core only without extensions", OFFSET(core_only), AV_OPT_TYPE_BOOL, { .i64 = 0 }' "$DCADEC" \
    || { echo "dcadec.c: the core_only option is not where this script expects it" >&2; exit 1; }
sed -i.orig 's/\("core_only", "Decode core only without extensions", OFFSET(core_only), AV_OPT_TYPE_BOOL, { \.i64 = \)0/\11/' "$DCADEC"
grep -q '{ .i64 = 1 }, 0, 1, PARAM' "$DCADEC" || { echo "dcadec.c: core_only was not switched on" >&2; exit 1; }

"$WORK/main/jni/build_ffmpeg.sh" "$WORK/main" "$NDK_PATH" "$HOST_PLATFORM" "$ANDROID_API" "${DECODERS[@]}"

# The headers, which the upstream flow reads straight out of the source tree. Installed rather than
# copied so that only the public ones come across — plus `avconfig.h`, which configure generates.
# It is the last ABI's (x86_64), exactly as it is upstream; the wrapper uses nothing in it that
# differs between architectures.
make -C "$WORK/main/jni/ffmpeg" install-headers DESTDIR="$WORK/headers" > /dev/null

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$WORK/main/jni/ffmpeg/android-libs" "$OUT/"
cp -R "$WORK/headers/usr/local/include/." "$OUT/"
cp "$WORK/main/jni/ffmpeg/COPYING.LGPLv2.1" "$OUT/"

# Debug info only, and only because these are committed: FFmpeg compiles with -g by default, which
# is most of the bytes — 36 MB before this, for code AGP strips out of the linked library anyway.
"$NDK_PATH/toolchains/llvm/prebuilt/$HOST_PLATFORM/bin/llvm-strip" --strip-debug "$OUT"/android-libs/*/*.a
cat > "$OUT/BUILD-INFO" <<EOF
FFmpeg $FFMPEG_TAG ($(git -C "$WORK/main/jni/ffmpeg" rev-parse HEAD))
Decoders: ${DECODERS[*]} (dca: core only)
Android API: $ANDROID_API
NDK: $(basename "$NDK_PATH")
Built by core/decoder-ffmpeg/build-ffmpeg.sh. Do not edit; run the script again.
EOF

rm -rf "$WORK"
echo "Done. Output in $OUT"
