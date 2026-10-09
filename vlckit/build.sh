#!/usr/bin/env bash
# Builds patent-trimmed, LGPL-only, dynamic VLCKit 3 xcframeworks for Mediagg:
#   out/MobileVLCKit.xcframework  iOS device arm64 + iOS simulator arm64
#   out/TVVLCKit.xcframework      tvOS device arm64 + tvOS simulator arm64
# then verifies them. See README.md next to this file.
#
#   vlckit/build.sh            build iOS and tvOS, then verify
#   vlckit/build.sh ios|tvos   build one platform, then verify what is in out/
#   vlckit/build.sh verify     verify out/ only
#   vlckit/build.sh licenses [iPhone|AppleTV]   licence of every static module, from its sources
#
# VLCKIT_WORK_DIR (default vlckit/work) holds the VLCKit/VLC checkouts and the
# build trees (~20 GB). Re-running reuses them; only what changed is rebuilt.
set -euo pipefail

# ---- pinned inputs -------------------------------------------------------------------------
VLCKIT_REPO="https://code.videolan.org/videolan/VLCKit.git"
VLCKIT_BRANCH="3.0"
VLCKIT_REF="b2edca9ca041eafad1408ee91a55e6d87f7e23d5" # "Pods: document the 3.7.4 release"
# VLCKit pins libvlc itself (TESTEDHASH in buildMobileVLCKit.sh) and VLC pins every contrib
# tarball by SHA-512, so this one ref fixes every source that goes into the build.

IOS_MIN="16.0"   # iosApp deployment target
TVOS_MIN="17.0"  # tvosApp deployment target

# VLC configure switches on top of VLCKit's own (which already pass --disable-a52,
# --disable-faad, --disable-mad, --disable-lua, --disable-dvdread ... and build the contribs
# with --disable-gpl --disable-gnuv3). Everything here is GPL, patent-encumbered, or both.
EXTRA_CONFIGURE="--disable-dca --disable-libmpeg2 --disable-postproc --disable-x262 --disable-x264 --disable-x26410b --disable-x265 --disable-css --disable-sid --disable-fdkaac --disable-shine --disable-zvbi --enable-telx --disable-realrtsp"
# Static modules removed after the build because their sources are GPL (see README; VLCKit's
# own blacklist already removes the other GPL modules: stats, logger, export, sap, podcast,
# mediadirs, audioscrobbler, hotkeys, gestures, oldrc, netsync, motion, t140, real, visual,
# remoteosd, hqdn3d, headphone_channel_mixer). Whole archive names: VLCKit deletes every
# plugin whose file name contains the string.
EXTRA_BLACKLIST="libdolby_surround_decoder_plugin.a libdummy_plugin.a libmono_plugin.a librotate_plugin.a libstream_out_rtp_plugin.a libsyslog_plugin.a libvod_rtsp_plugin.a"
# ---------------------------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${VLCKIT_WORK_DIR:-$HERE/work}"
OUT="$HERE/out"
SRC="$WORK/VLCKit"
VLC="$SRC/libvlc/vlc"

log() { printf '\033[1;34m[vlckit]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[vlckit]\033[0m %s\n' "$*" >&2; exit 1; }

stamp_of() { # a hash of everything that decides what libvlc is built from
    {
        echo "$VLCKIT_REF $IOS_MIN $TVOS_MIN $EXTRA_CONFIGURE $EXTRA_BLACKLIST"
        cat "$HERE"/patches/vlckit/*.patch "$HERE"/patches/libvlc/*.patch
    } | shasum -a 256 | cut -d' ' -f1
}

contrib_stamp_of() { # ... and of what decides the FFmpeg contrib
    {
        echo "$VLCKIT_REF"
        grep -l '^diff --git a/contrib/' "$HERE"/patches/libvlc/*.patch | xargs cat
    } | shasum -a 256 | cut -d' ' -f1
}

prepare() {
    mkdir -p "$WORK" "$OUT"
    if [ ! -d "$SRC/.git" ]; then
        log "cloning VLCKit $VLCKIT_BRANCH"
        git clone --branch "$VLCKIT_BRANCH" --single-branch "$VLCKIT_REPO" "$SRC"
    fi
    git -C "$SRC" cat-file -e "$VLCKIT_REF^{commit}" 2>/dev/null || git -C "$SRC" fetch origin "$VLCKIT_BRANCH"
    log "VLCKit at $VLCKIT_REF, applying patches"
    git -C "$SRC" checkout -q --force --detach "$VLCKIT_REF"
    git -C "$SRC" clean -fdq -- libvlc/patches
    for p in "$HERE"/patches/vlckit/*.patch; do git -C "$SRC" apply "$p"; done
    cp "$HERE"/patches/libvlc/*.patch "$SRC/libvlc/patches/"
}

build_platform() { # ios | tvos
    local platform="$1" flags="-v -a aarch64" name="MobileVLCKit" osstyle="iPhone"
    if [ "$platform" = "tvos" ]; then flags="-t $flags"; name="TVVLCKit"; osstyle="AppleTV"; fi

    local stamp cstamp; stamp="$(stamp_of)"; cstamp="$(contrib_stamp_of)"
    local stampfile="$WORK/.stamp-$platform" cstampfile="$WORK/.stamp-$platform-contrib"
    if [ -d "$VLC/.git" ]; then
        if [ "$(cat "$stampfile" 2>/dev/null)" = "$stamp" ]; then
            flags="$flags -n" # libvlc already at TESTEDHASH with these patches: no git reset
        else
            # VLCKit resets libvlc and re-applies the patches; make the change take effect.
            log "inputs changed since the last $platform build: reconfiguring libvlc"
            rm -f "$VLC"/build-"$osstyle"*/*/config.log
            if [ "$(cat "$cstampfile" 2>/dev/null)" != "$cstamp" ]; then
                log "contrib patches changed: rebuilding FFmpeg"
                rm -rf "$VLC"/contrib/"$osstyle"*/ffmpeg "$VLC"/contrib/"$osstyle"*/.ffmpeg
                rm -rf "$VLC"/contrib/"$osstyle"*-apple-darwin-*/lib/libav* \
                       "$VLC"/contrib/"$osstyle"*-apple-darwin-*/lib/libsw*
            fi
        fi
    fi

    local logfile="$WORK/build-$platform.log" started=$SECONDS
    log "building $name ($platform, arm64 device + arm64 simulator); log: $logfile"
    if ! (cd "$SRC" && env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
            LANG=en_US.UTF-8 TERM=dumb \
            VLCKIT_IOS_MIN="$IOS_MIN" VLCKIT_TVOS_MIN="$TVOS_MIN" \
            VLCKIT_EXTRA_CONFIGURE="$EXTRA_CONFIGURE" VLCKIT_EXTRA_BLACKLIST="$EXTRA_BLACKLIST" \
            ./buildMobileVLCKit.sh $flags) </dev/null >"$logfile" 2>&1; then
        tail -n 60 "$logfile" >&2
        die "$platform build failed; full log: $logfile"
    fi
    echo "$stamp" >"$stampfile"
    echo "$cstamp" >"$cstampfile"
    log "$platform built in $(( (SECONDS - started) / 60 )) min"

    rm -rf "$OUT/$name.xcframework"
    cp -R "$SRC/build/$name.xcframework" "$OUT/"
    cp "$SRC/Resources/MobileVLCKit/vlc-plugins-$osstyle.h" "$OUT/vlc-plugins-$osstyle.h"
}

# ---- verification --------------------------------------------------------------------------
ABSENT="ff_h264_decoder ff_hevc_decoder ff_vvc_decoder ff_truehd_decoder ff_mlp_decoder"
PRESENT="ff_aac_decoder ff_ac3_decoder ff_eac3_decoder ff_dca_decoder ff_pgssub_decoder ff_dvdsub_decoder ff_dvbsub_decoder ff_mpeg2video_decoder ff_mpeg4_decoder ff_vc1_decoder ff_vp9_decoder ff_flac_decoder ff_alac_decoder ff_mp3float_decoder"

verify() {
    local fail=0 any=0
    for xcf in "$OUT"/MobileVLCKit.xcframework "$OUT"/TVVLCKit.xcframework; do
        [ -d "$xcf" ] || continue
        any=1
        local name; name="$(basename "$xcf" .xcframework)"
        log "$name.xcframework: $(du -sh "$xcf" | cut -f1) uncompressed"
        for slice in "$xcf"/*/; do
            [ -d "$slice/$name.framework" ] || continue
            local bin="$slice/$name.framework/$name"
            local dsym="$slice/dSYMs/$name.framework.dSYM/Contents/Resources/DWARF/$name"
            echo "  $(basename "$slice"): $(lipo -archs "$bin")"
            # 1. dynamic: Mach-O filetype must be DYLIB, not an ar archive
            local ftype; ftype="$(otool -hv "$bin" | awk 'NR==4 {print $5}')"
            echo "    filetype $ftype; $(file -b "$bin")"
            [ "$ftype" = "DYLIB" ] || { echo "    FAIL: not a dylib"; fail=1; }
            # 2. decoders: the dSYM keeps the full symbol table, the shipped binary is stripped
            [ -f "$dsym" ] || { echo "    FAIL: no dSYM at $dsym"; fail=1; continue; }
            local syms; syms="$(nm "$dsym" 2>/dev/null | awk '{print $NF}' | sed 's/^_//')"
            for s in $ABSENT; do
                if grep -qx "$s" <<<"$syms"; then echo "    FAIL: $s present"; fail=1; else echo "    absent   $s"; fi
            done
            for s in $PRESENT; do
                if grep -qx "$s" <<<"$syms"; then echo "    present  $s"; else echo "    FAIL: $s missing"; fail=1; fi
            done
        done
    done
    for h in "$OUT"/vlc-plugins-*.h; do
        [ -f "$h" ] || continue
        if grep -q "vlc_entry__.*videotoolbox" "$h"; then
            log "$(basename "$h"): videotoolbox module present ($(grep -c '^ vlc_entry' "$h") static modules)"
        else
            echo "FAIL: videotoolbox module missing from $(basename "$h")"; fail=1
        fi
    done
    # the FFmpeg that went into the build carries the DTS core-only patch
    local dca
    for dca in "$VLC"/contrib/*/ffmpeg/libavcodec/dcadec.c; do
        [ -f "$dca" ] || continue
        if grep -q "s->core_only = 1;" "$dca"; then
            echo "  dca core-only: $(basename "$(dirname "$(dirname "$(dirname "$dca")")")")"
        else
            echo "FAIL: dca core-only patch missing in $dca"; fail=1
        fi
    done
    [ "$any" = 1 ] || die "nothing to verify in $OUT"
    [ "$fail" = 0 ] || die "verification failed"
    log "verification passed"
}

# Licence of every static module and of libVLC's core, from the sources it was compiled from:
# the DWARF compile units name each .c/.m file, the line tables name every header that
# contributed code. A module is flagged when any of those files is GPL-only.
licenses() {
    local osstyle="${1:-iPhone}"
    local inst="$VLC/install-${osstyle}OS/arm64/lib"
    [ -d "$inst/vlc/plugins" ] || die "no $osstyle build in $WORK"
    local gplfiles; gplfiles="$(mktemp)"
    (cd "$VLC" && grep -rlE "General Public License" --include='*.[chmS]' --include='*.cpp' --include='*.hpp' modules src lib compat include \
        | xargs grep -LiE "Lesser General|Library General" | sort -u) >"$gplfiles"
    local a name srcs lic f bad n=0 nbad=0
    for a in "$inst"/libvlccore.a "$inst"/libvlc.a "$inst"/vlc/libcompat.a "$inst"/vlc/plugins/*.a; do
        name="$(basename "$a" .a)"; n=$((n + 1))
        srcs="$(xcrun dwarfdump --debug-info "$a" 2>/dev/null | grep -A8 DW_TAG_compile_unit \
                | sed -n 's/.*DW_AT_name.*("\(\/.*\)")/\1/p' | sort -u)"
        lic=""
        for f in $srcs; do
            if grep -qiE "Lesser General|Library General" "$f"; then lic="$lic LGPL"
            elif grep -q "General Public License" "$f"; then lic="$lic GPL"
            elif grep -qiE "ISC License|BSD|MIT License|Permission is hereby granted|permission notice|Redistribution and use|public domain" "$f"; then lic="$lic permissive"
            else lic="$lic none:${f#$VLC/}"; fi
        done
        bad="$(xcrun dwarfdump --debug-line "$a" 2>/dev/null | sed -n 's/^ *name: "\(.*\)"/\1/p' \
               | sed "s|^$VLC/||" | sort -u | comm -12 - "$gplfiles" | tr '\n' ' ')"
        [ -n "$bad" ] && { nbad=$((nbad + 1)); bad="  GPL files: $bad"; }
        printf '%-42s %s%s\n' "$name" "$(tr ' ' '\n' <<<"$lic" | sort -u | tr '\n' ' ')" "$bad"
    done
    rm -f "$gplfiles"
    log "$n archives, $nbad with GPL-only files"
    echo "contribs linked in:"; ls "$VLC"/contrib/"$osstyle"OS-*/lib/*.a | xargs -n1 basename | tr '\n' ' '; echo
}

case "${1:-all}" in
    all)      prepare; build_platform ios; build_platform tvos; verify ;;
    ios|tvos) prepare; build_platform "$1"; verify ;;
    verify)   verify ;;
    licenses) licenses "${2:-iPhone}" ;;
    *)        sed -n '2,13p' "$0"; exit 1 ;;
esac
