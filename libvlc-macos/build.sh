#!/usr/bin/env bash
# Builds patent-trimmed, LGPL-only, dynamic libVLC 3 for macOS, for Mediagg for desktop
# (a Tauri app that loads it at runtime from Contents/Frameworks/vlc):
#   out/vlc/lib/libvlc.dylib, libvlccore.dylib   the library (universal or arm64)
#   out/vlc/plugins/<category>/lib*_plugin.dylib  the modules (VLC_PLUGIN_PATH)
#   out/vlc/licenses/                             the licence notices
#   out/dSYMs/, out/include/                      not shipped: symbols (verify reads them), headers
# then verifies them. See README.md next to this file.
#
#   libvlc-macos/build.sh                build arm64 and x86_64, lipo, then verify
#   libvlc-macos/build.sh arm64|x86_64   build one architecture into out/, then verify
#   libvlc-macos/build.sh assemble [arch...]  out/ again from the built trees, then verify
#   libvlc-macos/build.sh verify         verify out/ only (needs Xcode's clang for the play test)
#   libvlc-macos/build.sh licenses       licence of every module, from its sources
#
# LIBVLC_MACOS_WORK_DIR (default libvlc-macos/work) holds the VLC checkout and the build
# trees (~10 GB per architecture). Re-running reuses them; only what changed is rebuilt.
set -euo pipefail

# ---- pinned inputs -------------------------------------------------------------------------
VLC_REPO="https://code.videolan.org/videolan/vlc.git"
VLC_BRANCH="3.0.x"
VLC_REF="6de05adcbaf2e8b85fe86aad4169393098628119" # tag 3.0.24; TESTEDHASH of VLCKit 3.7.4
# The same libVLC that vlckit/build.sh builds: VLCKit_REF b2edca9ca041eafad1408ee91a55e6d87f7e23d5
# pins it by TESTEDHASH in buildMobileVLCKit.sh, and VLC pins every contrib tarball by SHA-512.
# Patches, in this order: patches/libvlc/*.patch here (VLCKit's own libvlc patches that the
# desktop build needs, unmodified: 0007, live555 2016.10.21, the last LGPL-2.1 release, since the
# current one is LGPL-3 and --disable-gnuv3 drops it), then vlckit/patches/libvlc/*.patch (the
# FFmpeg and Yadif patches, shared with the VLCKit build). VLCKit's other libvlc patches serve its
# Objective-C API or iOS; the desktop app uses only libVLC's public C API.

MACOS_MIN="13.0" # Mediagg for desktop's LSMinimumSystemVersion

# The contribs: VLCKit's own bootstrap switches (buildMobileVLCKit.sh, with its macOS extras and
# vlckit's zvbi patch), so the same libraries go in. --disable-gpl --disable-gnuv3 keep every
# GPL library out; FFmpeg is configured without --enable-gpl or --enable-nonfree.
CONTRIB_FLAGS="--disable-gpl --enable-ad-clauses --disable-gnuv3 --disable-disc --disable-sdl --disable-SDL_image --disable-iconv --disable-zvbi --disable-kate --disable-caca --disable-gettext --disable-mpcdec --enable-upnp --disable-gme --disable-srt --disable-tremor --enable-vorbis --disable-sidplay2 --disable-samplerate --disable-goom --disable-vncserver --disable-orc --disable-schroedinger --disable-libmpeg2 --disable-chromaprint --disable-mad --enable-fribidi --enable-libxml2 --enable-freetype2 --enable-ass --disable-fontconfig --disable-gpg-error --disable-vncclient --disable-gnutls --disable-lua --disable-luac --disable-aribb24 --disable-aribb25 --enable-vpx --enable-libdsm --enable-smb2 --enable-libplacebo --disable-sparkle --disable-growl --disable-breakpad --disable-ncurses --disable-asdcplib --enable-soxr --enable-taglib --disable-bghudappkit --disable-twolame --disable-microdns --disable-cddb --disable-bluray"

# libVLC configure: VLCKit's switches (minus its static-only ones), plus what VLC's own macOS
# configure.sh turns off, plus no GUI and no vlc binary. --disable-macosx drops VLC's macOS GUI
# (GPL); the video outputs libvlc_media_player_set_nsobject uses (vout_macosx, caopengllayer)
# are separate LGPL modules and stay.
CONFIGURE="--enable-shared --disable-static --enable-live555 --enable-merge-ffmpeg --enable-dvbpsi --enable-avcodec --disable-macosx --disable-macosx-avfoundation --disable-osx-notifications --disable-sparkle --enable-opus --disable-faad --disable-lua --disable-a52 --enable-fribidi --disable-qt --disable-skins2 --disable-ncurses --disable-xcb --disable-caca --disable-sdl-image --disable-vnc --disable-vcd --disable-vlc --disable-vlm --disable-nls --disable-notify --enable-swscale --disable-projectm --enable-libass --enable-libxml2 --disable-goom --disable-dvdread --disable-dvdnav --disable-bluray --disable-linsys --disable-libva --disable-gme --disable-tremor --enable-vorbis --disable-fluidsynth --disable-jack --disable-pulse --disable-mtp --enable-ogg --enable-speex --enable-theora --enable-flac --disable-screen --enable-freetype --enable-taglib --enable-smb2 --disable-addonmanagermodules --disable-mad"
# ... and vlckit/build.sh's EXTRA_CONFIGURE, unchanged: GPL, patent-encumbered, or both.
EXTRA_CONFIGURE="--disable-dca --disable-libmpeg2 --disable-postproc --disable-x262 --disable-x264 --disable-x26410b --disable-x265 --disable-css --disable-sid --disable-fdkaac --disable-shine --disable-zvbi --enable-telx --disable-realrtsp"

# Modules removed after the build: VLCKit's blacklist (every plugin whose file name contains
# the string, as buildMobileVLCKit.sh does) and vlckit/build.sh's EXTRA_BLACKLIST (whole names).
BLACKLIST="stats access_bd shm access_imem oldrc real hotkeys gestures dynamicoverlay rss ball marq audiobargraph_ clone mosaic osdmenu puzzle mediadirs t140 ripple motion sharpen grain posterize mirror wall scene blendbench psychedelic alphamask netsync audioscrobbler motiondetect motionblur export smf podcast sap bluescreen erase stream_filter_record speex_resampler remoteosd gradient logger visual fb aout_file invert sepia wave hqdn3d headphone_channel_mixer gaussianblur gradfun extract colorthres antiflicker anaglyph remap oldmovie vhs fingerprinter output_udp output_livehttp"
EXTRA_BLACKLIST="libdolby_surround_decoder_plugin libdummy_plugin libmono_plugin librotate_plugin libstream_out_rtp_plugin libsyslog_plugin libvod_rtsp_plugin"
# ---------------------------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WORK="${LIBVLC_MACOS_WORK_DIR:-$HERE/work}"
OUT="$HERE/out"
VLC="$WORK/vlc"
patches() { ls "$HERE"/patches/libvlc/*.patch "$REPO_ROOT"/vlckit/patches/libvlc/*.patch; }
JOBS="$(( $(sysctl -n hw.ncpu) + 1 ))"
KERNEL="$(uname -r | cut -d. -f1)"
BUILD_TRIPLET="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin$KERNEL"

log() { printf '\033[1;34m[libvlc-macos]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[libvlc-macos]\033[0m %s\n' "$*" >&2; exit 1; }

host_of() { echo "$(sed 's/arm64/aarch64/' <<<"$1")-apple-darwin$KERNEL"; }

stamp_of() { # a hash of everything that decides what libvlc is built from
    {
        echo "$VLC_REF $MACOS_MIN $CONTRIB_FLAGS $CONFIGURE $EXTRA_CONFIGURE"
        patches | xargs cat
    } | shasum -a 256 | cut -d' ' -f1
}

contrib_stamp_of() { # ... and of what decides the contribs
    {
        echo "$VLC_REF $MACOS_MIN $CONTRIB_FLAGS"
        patches | xargs grep -l '^diff --git a/contrib/' | xargs cat
    } | shasum -a 256 | cut -d' ' -f1
}

# Runs a command with only the system PATH and VLC's own tools, like vlckit/build.sh does:
# nothing from Homebrew or the caller's environment gets into the build.
clean_env() {
    env -i HOME="$HOME" USER="$USER" LANG=en_US.UTF-8 TERM=dumb \
        PATH="$VLC/extras/tools/build/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@"
}

prepare() {
    mkdir -p "$WORK" "$OUT"
    if [ ! -d "$VLC/.git" ]; then
        log "cloning VLC $VLC_BRANCH"
        git clone --branch "$VLC_BRANCH" --single-branch "$VLC_REPO" "$VLC"
    fi
    local stamp; stamp="$(stamp_of)"
    if [ "$(cat "$WORK/.stamp-source" 2>/dev/null)" = "$stamp" ]; then
        return # checked out and patched with these inputs; leave the mtimes alone
    fi
    git -C "$VLC" cat-file -e "$VLC_REF^{commit}" 2>/dev/null || git -C "$VLC" fetch origin "$VLC_BRANCH"
    log "VLC at $VLC_REF, applying patches"
    git -C "$VLC" checkout -q --force --detach "$VLC_REF"
    git -C "$VLC" clean -fdq -- contrib/src modules src lib
    for p in $(patches); do git -C "$VLC" apply --whitespace=nowarn "$p"; done
    echo "$stamp" >"$WORK/.stamp-source"
}

tools() {
    log "building VLC's extras/tools (autotools, cmake, meson, ninja ...); log: $WORK/build-tools.log"
    if ! (cd "$VLC/extras/tools" && clean_env sh -c "./bootstrap && make -j$JOBS") </dev/null >"$WORK/build-tools.log" 2>&1; then
        tail -n 60 "$WORK/build-tools.log" >&2; die "extras/tools failed"
    fi
    # ninja 1.13 (Kitware's jobserver build) joins make's jobserver; Apple's make 3.81 offers a
    # pipe jobserver, so ninja aborts or make dies. Hide the jobserver (see vlckit/README.md).
    local bin="$VLC/extras/tools/build/bin"
    if [ -x "$bin/ninja" ] && [ ! -e "$bin/ninja.real" ]; then mv "$bin/ninja" "$bin/ninja.real"; fi
    if [ -e "$bin/ninja.real" ]; then
        printf '%s\n' '#!/bin/sh' 'unset MAKEFLAGS MFLAGS' \
            'case " $* " in *" -j"*) ;; *) set -- -j "${NINJA_JOBS:-4}" "$@" ;; esac' \
            'exec "$(dirname "$0")/ninja.real" "$@"' >"$bin/ninja"
        chmod +x "$bin/ninja"
    fi
    # CMake 4 on macOS puts Homebrew (/opt/homebrew, or `brew --prefix`) first in its system
    # prefix path, so a contrib's find_package (librist's MbedTLS, via meson) picks up the
    # Mac's Homebrew libraries. Nothing from Homebrew may go in: take that search out of the
    # CMake VLC's tools built.
    local darwin
    for darwin in "$VLC"/extras/tools/build/share/cmake-*/Modules/Platform/Darwin.cmake; do
        [ -f "$darwin" ] || continue
        grep -q 'mediagg: no Homebrew' "$darwin" && continue
        perl -0pi -e 's/if\(CMAKE_SYSTEM_NAME STREQUAL "Darwin"\)\n  execute_process\(\n    COMMAND brew --prefix/if(FALSE) # mediagg: no Homebrew\n  execute_process(\n    COMMAND brew --prefix/' "$darwin"
        grep -q 'mediagg: no Homebrew' "$darwin" || die "could not take Homebrew out of $darwin"
    done
}

# The environment VLC's extras/package/macosx/build.sh sets up, with macOS 13 as the minimum.
toolchain_env() { # arch
    local arch="$1" sdk; sdk="$(xcrun --sdk macosx --show-sdk-path)"
    echo SDKROOT="$sdk"
    echo AR="$(xcrun --find ar)" NM="$(xcrun --find nm)" RANLIB="$(xcrun --find ranlib)"
    echo STRINGS="$(xcrun --find strings)" STRIP="$(xcrun --find strip)"
    echo USE_FFMPEG=1
    # Undeclared in Apple SDK headers but falsely link-detectable (as in VLCKit's script)
    echo ac_cv_func_dup3=no ac_cv_func_pipe2=no
    # autoconf 2.73 adds -std=gnu23 to CC but not OBJC, breaking libtool's ObjC tag inference
    echo ac_cv_prog_cc_c23=no
}

build_contribs() { # arch
    local arch="$1" host; host="$(host_of "$1")"
    local sdk; sdk="$(xcrun --sdk macosx --show-sdk-path)"
    local cdir="$VLC/contrib/contrib-$host" cstamp; cstamp="$(contrib_stamp_of)"
    local cstampfile="$WORK/.stamp-$arch-contrib"
    if [ -d "$cdir" ] && [ "$(cat "$cstampfile" 2>/dev/null)" != "$cstamp" ]; then
        log "contrib inputs changed: rebuilding FFmpeg and re-bootstrapping the $arch contribs"
        rm -rf "$cdir/ffmpeg" "$cdir/.ffmpeg" "$cdir/config.mak" \
               "$VLC/contrib/$host"/lib/libav* "$VLC/contrib/$host"/lib/libsw*
    fi
    mkdir -p "$cdir"
    local logfile="$WORK/build-$arch-contrib.log" started=$SECONDS
    log "building the $arch contribs from source; log: $logfile"
    local cc; cc="$(xcrun --find clang)"; local cxx; cxx="$(xcrun --find clang++)"
    local flags="-isysroot $sdk -mmacosx-version-min=$MACOS_MIN -DMACOSX_DEPLOYMENT_TARGET=$MACOS_MIN -arch $arch"
    if ! (cd "$cdir" && clean_env $(toolchain_env "$arch") \
            CC="$cc" CXX="$cxx" OBJC="$cc" OBJCXX="$cxx" \
            CFLAGS="-Werror=partial-availability" CXXFLAGS="-Werror=partial-availability" \
            OBJCFLAGS="-Werror=partial-availability" \
            EXTRA_CFLAGS="$flags" \
            EXTRA_LDFLAGS="-Wl,-syslibroot,$sdk $flags" \
            XCODE_FLAGS="MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN -sdk macosx WARNING_CFLAGS=-Werror=partial-availability" \
            sh -c "../bootstrap --build=$BUILD_TRIPLET --host=$host $CONTRIB_FLAGS && make list && make fetch && (make -j$JOBS -k || make -j1)") \
            </dev/null >"$logfile" 2>&1; then
        tail -n 60 "$logfile" >&2
        die "$arch contribs failed; full log: $logfile"
    fi
    # nothing the contribs installed may point outside the work tree and the SDK
    local leak; leak="$(grep -rlE '/opt/homebrew|/usr/local' "$VLC/contrib/$host"/lib/pkgconfig "$VLC/contrib/$host"/lib/cmake "$VLC/contrib/$host"/lib/*.la 2>/dev/null || true)"
    [ -z "$leak" ] || die "contribs refer to Homebrew or /usr/local: $leak"
    echo "$cstamp" >"$cstampfile"
    log "$arch contribs built in $(( (SECONDS - started) / 60 )) min"
}

build_libvlc() { # arch
    local arch="$1" host; host="$(host_of "$1")"
    local sdk; sdk="$(xcrun --sdk macosx --show-sdk-path)"
    local bdir="$WORK/build-$arch" prefix="$WORK/install-$arch"
    local stamp; stamp="$(stamp_of)"; local stampfile="$WORK/.stamp-$arch"
    if [ ! -e "$VLC/configure" ]; then
        log "bootstrapping VLC's configure"
        (cd "$VLC" && clean_env ./bootstrap) </dev/null >"$WORK/build-bootstrap.log" 2>&1 \
            || { tail -n 40 "$WORK/build-bootstrap.log" >&2; die "VLC bootstrap failed"; }
    fi
    if [ "$(cat "$stampfile" 2>/dev/null)" != "$stamp" ]; then
        rm -f "$bdir/config.status" "$bdir/Makefile"
    fi
    mkdir -p "$bdir"
    local logfile="$WORK/build-$arch.log" started=$SECONDS
    log "building libVLC ($arch); log: $logfile"
    local tc="-isysroot $sdk -mmacosx-version-min=$MACOS_MIN"
    local cc; cc="$(xcrun --find clang)"; local cxx; cxx="$(xcrun --find clang++)"
    local conf="$VLC/configure --build=$BUILD_TRIPLET --host=$host --prefix=$prefix --with-contrib=$VLC/contrib/$host --with-macosx-version-min=$MACOS_MIN --with-macosx-sdk=$sdk $CONFIGURE $EXTRA_CONFIGURE"
    if ! (cd "$bdir" && clean_env $(toolchain_env "$arch") \
            CC="$cc $tc" CXX="$cxx $tc -stdlib=libc++ -std=c++11" \
            OBJC="$cc $tc" OBJCXX="$cxx $tc -stdlib=libc++ -std=c++11" \
            CFLAGS="-g -arch $arch" CXXFLAGS="-g -arch $arch" OBJCFLAGS="-g -arch $arch" \
            LDFLAGS="-arch $arch" \
            sh -c "{ [ -f Makefile ] || $conf; } && make -j$JOBS && rm -rf '$prefix' && make install") \
            </dev/null >"$logfile" 2>&1; then
        tail -n 60 "$logfile" >&2
        die "libVLC $arch failed; full log: $logfile"
    fi
    echo "$stamp" >"$stampfile"
    log "libVLC $arch built in $(( (SECONDS - started) / 60 )) min"
}

blacklisted() { # file name -> 0 when the module is removed
    local f="$1" i
    for i in $BLACKLIST; do case "$f" in *"$i"*) return 0 ;; esac; done
    for i in $EXTRA_BLACKLIST; do [ "${f%.dylib}" = "$i" ] && return 0; done
    return 1
}

# out/vlc from the install trees: removes the blacklisted modules, lipos the architectures,
# makes the tree relocatable (@rpath + @loader_path), splits the symbols into dSYMs, strips
# and ad-hoc signs (the app re-signs everything it bundles).
assemble() { # archs...
    local archs=("$@") first="$WORK/install-$1"
    rm -rf "$OUT" && mkdir -p "$OUT/vlc/lib" "$OUT/vlc/plugins" "$OUT/dSYMs" "$OUT/include"
    local stage="$WORK/stage"; rm -rf "$stage"; mkdir -p "$stage/lib" "$stage/plugins"
    log "assembling out/ (${archs[*]})"
    local rel f a srcs removed=""
    # the Mach-O files: libvlc and libvlccore (real files) and every module
    local files=()
    for f in "$first"/lib/libvlc.*.dylib "$first"/lib/libvlccore.*.dylib; do
        [ -L "$f" ] || files+=("lib/$(basename "$f")")
    done
    while IFS= read -r f; do
        rel="${f#$first/lib/vlc/}"
        if blacklisted "$(basename "$f")"; then removed="$removed $(basename "$f" .dylib)"; continue; fi
        files+=("$rel")
    done < <(find "$first/lib/vlc/plugins" -name '*.dylib' -type f | sort)
    for rel in "${files[@]}"; do
        mkdir -p "$stage/$(dirname "$rel")"
        srcs=()
        for a in "${archs[@]}"; do
            if [ "${rel%%/*}" = lib ]; then f="$WORK/install-$a/$rel"; else f="$WORK/install-$a/lib/vlc/$rel"; fi
            [ -f "$f" ] || die "$rel missing from the $a build"
            srcs+=("$f")
        done
        if [ ${#srcs[@]} -eq 1 ]; then cp "${srcs[0]}" "$stage/$rel"; else lipo -create "${srcs[@]}" -output "$stage/$rel"; fi
    done
    (cd "$first/lib" && for f in libvlc.dylib libvlccore.dylib; do cp -a "$f" "$stage/lib/"; done)
    echo "$removed" | tr ' ' '\n' | sed '/^$/d' >"$OUT/removed-modules.txt"

    for rel in "${files[@]}"; do
        f="$stage/$rel"
        # drop rpaths that point into the build machine, then add the relocatable one
        local rp
        for rp in $(otool -l "$f" | awk '/cmd LC_RPATH/ {getline; getline; print $2}'); do
            install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
        done
        case "$rel" in
            lib/*) install_name_tool -add_rpath @loader_path "$f" ;;
            *) local depth; depth="$(tr -cd / <<<"$rel" | wc -c | tr -d ' ')"
               local up=""; for ((i = 0; i < depth; i++)); do up="$up../"; done
               install_name_tool -id "@loader_path/$(basename "$rel")" -add_rpath "@loader_path/${up}lib" "$f" ;;
        esac 2>&1 | grep -v 'invalidate the code signature' || true
        mkdir -p "$OUT/dSYMs/$(dirname "$rel")"
        dsymutil "$f" -o "$OUT/dSYMs/$rel.dSYM" 2>&1 | grep -v 'no debug symbols\|unable to open object file\|warning:' || true
        mkdir -p "$OUT/vlc/$(dirname "$rel")"
        strip -x -o "$OUT/vlc/$rel" "$f" 2>/dev/null
        codesign -f -s - "$OUT/vlc/$rel" 2>/dev/null
    done
    cp -a "$stage/lib/libvlc.dylib" "$stage/lib/libvlccore.dylib" "$OUT/vlc/lib/"
    cp -R "$first/include/vlc" "$OUT/include/"
    notices "${archs[0]}"
    echo "$(IFS=' '; echo "${archs[*]}")" >"$OUT/archs.txt"
    rm -rf "$stage"
}

# The licence notices the app must carry: libVLC's own, and each contrib library's that is
# linked into the modules (its COPYING/LICENSE files, from the source that was built).
# Only the contribs built for the first architecture are read: both build the same set.
notices() { # arch whose contribs to read
    local host cdir lic="$OUT/vlc/licenses"
    host="$(host_of "$1")"; cdir="$VLC/contrib/contrib-$host"
    mkdir -p "$lic/vlc" "$lic/contribs"
    cp "$VLC/COPYING.LIB" "$lic/vlc/COPYING.LIB"
    cp "$VLC/COPYING" "$lic/vlc/COPYING" # the GPL text; VLC's sources refer to it. No GPL code is shipped.
    cp "$VLC/AUTHORS" "$lic/vlc/AUTHORS" 2>/dev/null || true
    local d pkg n=0
    for d in "$cdir"/*/; do
        pkg="$(basename "$d")" # every source tree here was built and installed
        local found; found="$(find "$d" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) | sort)"
        [ -n "$found" ] || found="$(find "$d" -maxdepth 2 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' \) | sort)"
        [ -n "$found" ] || { echo "  no licence file found for contrib $pkg" >&2; continue; }
        mkdir -p "$lic/contribs/$pkg"
        while IFS= read -r f; do cp "$f" "$lic/contribs/$pkg/"; done <<<"$found"
        n=$((n + 1))
    done
    cat >"$lic/README.txt" <<EOF
libVLC $(git -C "$VLC" describe --tags --always 2>/dev/null) ($VLC_REF), built by mediagg-native-builds
libvlc-macos/build.sh with the patches in libvlc-macos/patches/libvlc and
vlckit/patches/libvlc. libVLC and libVLCcore are
LGPL-2.1-or-later (vlc/COPYING.LIB); every module shipped here is LGPL or permissive. The
contribs/ directories hold the licence of each library linked into the modules ($n).
The source of this build, and the offer to send it: https://github.com/m3ugoat/mediagg-lgpl-sources (libvlc-macos/).
EOF
}

build_arch() { # arch
    tools
    build_contribs "$1"
    build_libvlc "$1"
}

# ---- verification --------------------------------------------------------------------------
ABSENT="ff_h264_decoder ff_hevc_decoder ff_vvc_decoder ff_truehd_decoder ff_mlp_decoder"
PRESENT="ff_aac_decoder ff_ac3_decoder ff_eac3_decoder ff_dca_decoder ff_pgssub_decoder ff_dvdsub_decoder ff_dvbsub_decoder ff_mpeg2video_decoder ff_mpeg4_decoder ff_vc1_decoder ff_vp9_decoder ff_flac_decoder ff_alac_decoder ff_mp3float_decoder"
# modules the desktop app needs: hardware decoding, the NSView outputs, the audio output
NEEDED="codec/libvideotoolbox_plugin codec/libavcodec_plugin video_output/libvout_macosx_plugin video_output/libcaopengllayer_plugin audio_output/libauhal_plugin"

verify() {
    [ -f "$OUT/vlc/lib/libvlc.dylib" ] || die "nothing to verify in $OUT"
    local fail=0 want; want="$(cat "$OUT/archs.txt")"
    log "out/vlc: $(du -sh "$OUT/vlc" | cut -f1) ($(find "$OUT/vlc/plugins" -name '*.dylib' | wc -l | tr -d ' ') modules), dSYMs $(du -sh "$OUT/dSYMs" | cut -f1); architectures: $want"
    # 1. every Mach-O: dynamic, the wanted architectures, macOS 13, no path outside the tree
    local f rel ftype archs minos bad a nfiles=0
    while IFS= read -r f; do
        rel="${f#$OUT/vlc/}"; nfiles=$((nfiles + 1))
        ftype="$(otool -hv "$f" | awk 'NR>=4 && $5 != "" {print $5; exit}')"
        archs="$(lipo -archs "$f" | tr ' ' '\n' | sort | xargs)"
        case "$ftype" in DYLIB|BUNDLE) ;; *) echo "  FAIL: $rel is $ftype, not a dylib"; fail=1 ;; esac
        [ "$archs" = "$(tr ' ' '\n' <<<"$want" | sort | xargs)" ] || { echo "  FAIL: $rel is '$archs', want '$want'"; fail=1; }
        for a in $want; do
            minos="$(otool -arch "$a" -l "$f" | awk '/LC_BUILD_VERSION/ {b=1} /LC_VERSION_MIN_MACOSX/ {v=1} b && /minos/ {print $2; exit} v && / version / {print $2; exit}')"
            # VLC builds videotoolbox and cvpx for 10.8 whatever the target (arm64 records 11.0; x86_64
            # 10.8, in an LC_VERSION_MIN_MACOSX)
            awk -v a="$minos" -v b="$MACOS_MIN" 'BEGIN { split(a, x, "."); split(b, y, "."); exit !(a != "" && (x[1] < y[1] || (x[1] == y[1] && x[2] <= y[2]))) }' \
                || { echo "  FAIL: $rel ($a) needs macOS $minos"; fail=1; }
            bad="$( { otool -arch "$a" -L "$f" | tail -n +2 | awk '{print $1}'; otool -arch "$a" -l "$f" | awk '/cmd LC_RPATH/ {getline; getline; print $2}'; } \
                    | grep -vE '^(/System/Library/|/usr/lib/|@rpath/libvlc(core)?\.dylib$|@loader_path|@rpath/libvlc(core)?\.[0-9]+\.dylib$)' || true)"
            [ -z "$bad" ] || { echo "  FAIL: $rel ($a) refers to $(echo $bad)"; fail=1; }
        done
        [ -d "$OUT/dSYMs/$rel.dSYM" ] || { echo "  FAIL: no dSYM for $rel"; fail=1; }
    done < <(find "$OUT/vlc/lib" "$OUT/vlc/plugins" -name '*.dylib' -type f)
    echo "  $nfiles Mach-O files: $(otool -hv "$OUT/vlc/lib/libvlc.dylib" | awk 'NR==4 {print $5}') (libvlc), $(otool -hv "$OUT/vlc/plugins/codec/libavcodec_plugin.dylib" | awk 'NR==4 {print $5}') (modules), $want, loadable on macOS $MACOS_MIN, only system and in-tree references"
    echo "  libvlc.dylib: $(file -b "$OUT/vlc/lib/libvlc.dylib" | head -1)"
    # 2. decoders: FFmpeg is linked statically into the modules; their dSYMs keep the symbols
    local a dsyms syms
    for a in $want; do
        syms="$(find "$OUT/dSYMs" -path '*/Contents/Resources/DWARF/*' -type f -print0 \
                | xargs -0 -n 20 nm -arch "$a" 2>/dev/null | awk '{print $NF}' | sed 's/^_//' | grep '^ff_.*_decoder$' | sort -u)"
        echo "  $a: decoder symbols in the dSYMs of all modules"
        for s in $ABSENT; do
            if grep -qx "$s" <<<"$syms"; then echo "    FAIL: $s present"; fail=1; else echo "    absent   $s"; fi
        done
        for s in $PRESENT; do
            if grep -qx "$s" <<<"$syms"; then echo "    present  $s"; else echo "    FAIL: $s missing"; fail=1; fi
        done
    done
    # 3. the modules the app needs, and none of the removed ones
    local m
    for m in $NEEDED; do
        if [ -f "$OUT/vlc/plugins/$m.dylib" ]; then echo "  module present: $m"; else echo "  FAIL: module missing: $m"; fail=1; fi
    done
    while IFS= read -r f; do
        blacklisted "$(basename "$f")" && { echo "  FAIL: removed module shipped: $f"; fail=1; }
    done < <(find "$OUT/vlc/plugins" -name '*.dylib')
    # 4. the FFmpeg that went into the build carries the DTS core-only patch
    local dca
    for dca in "$VLC"/contrib/contrib-*/ffmpeg/libavcodec/dcadec.c; do
        [ -f "$dca" ] || continue
        if grep -q "s->core_only = 1;" "$dca"; then
            echo "  dca core-only: $(basename "$(dirname "$(dirname "$(dirname "$dca")")")")"
        else
            echo "  FAIL: dca core-only patch missing in $dca"; fail=1
        fi
    done
    # 5. no GPL module
    if licenses >"$WORK/licenses.txt" 2>&1; then
        echo "  $(tail -n 1 "$WORK/licenses.txt" | sed 's/\x1b\[[0-9;]*m//g') (full list: $WORK/licenses.txt)"
    else
        grep 'GPL files' "$WORK/licenses.txt" | sed 's/^/  FAIL: /'; fail=1
    fi
    # 6. it loads and plays from a copy of the tree, as the app will load it
    play_test || fail=1
    [ "$fail" = 0 ] || die "verification failed"
    log "verification passed"
}

play_test() {
    local t; t="$(mktemp -d)"
    cp -R "$OUT/vlc" "$t/vlc"
    local clip ok=0 a
    for a in $(cat "$OUT/archs.txt"); do
        # x86_64 runs under Rosetta on Apple silicon; skip an architecture this Mac cannot run
        arch -"$a" /usr/bin/true 2>/dev/null || { echo "  play test: $a cannot run on this Mac, skipped"; continue; }
        clang -arch "$a" -Wall -O1 -I"$OUT/include" -o "$t/play-$a" "$HERE/test/play.c" || { rm -rf "$t"; return 1; }
        for clip in "$HERE"/test/*.mp4 "$HERE"/test/*.mkv; do
            [ -f "$clip" ] || continue
            echo "  [$a] $(basename "$clip")"
            set -o pipefail
            if env -i HOME="$HOME" PATH=/usr/bin:/bin VLC_PLUGIN_PATH="$t/vlc/plugins" \
                   arch -"$a" "$t/play-$a" "$t/vlc/lib/libvlc.dylib" "$clip" 2>&1 | sed 's/^/    /'; then :; else ok=1; fi
        done
    done
    rm -rf "$t"
    return $ok
}

# Licence of every module and of libVLC's core, from the sources it was compiled from: the
# DWARF compile units (in the dSYMs) name each .c/.m file, the line tables name every header
# that contributed code. A module is flagged when any of those files is GPL-only.
licenses() {
    [ -d "$OUT/dSYMs" ] || die "no build in $OUT"
    local arch; arch="$(awk '{print $1}' "$OUT/archs.txt")"
    local gplfiles; gplfiles="$(mktemp)"
    (cd "$VLC" && grep -rlE "General Public License" --include='*.[chmS]' --include='*.cpp' --include='*.hpp' modules src lib compat include \
        | xargs grep -LiE "Lesser General|Library General" | sort -u) >"$gplfiles"
    local d name srcs lic f bad n=0 nbad=0
    while IFS= read -r d; do
        name="$(basename "$d" .dylib.dSYM)"; n=$((n + 1))
        d="$(find "$d/Contents/Resources/DWARF" -type f | head -1)"
        srcs="$(xcrun dwarfdump --arch "$arch" --debug-info "$d" 2>/dev/null | grep -A8 DW_TAG_compile_unit \
                | sed -n 's/.*DW_AT_name.*("\(.*\)")/\1/p' | sort -u)"
        lic=""
        for f in $srcs; do
            case "$f" in /*) ;; *) f="$VLC/$f" ;; esac
            case "$f" in "$VLC"/contrib/*) lic="$lic contrib"; continue ;; esac # --disable-gpl decides those
            [ -f "$f" ] || f="$(find "$VLC/modules" "$VLC/src" "$VLC/lib" "$VLC/compat" -path "*/${f##*/../}" 2>/dev/null | head -1)"
            # relative names: contrib objects, or files generated in the build tree
            if [ -z "$f" ] || [ ! -f "$f" ]; then lic="$lic unresolved"
            elif grep -qiE "Lesser General|Library General" "$f"; then lic="$lic LGPL"
            elif grep -q "General Public License" "$f"; then lic="$lic GPL"
            elif grep -qiE "ISC License|BSD|MIT License|Permission is hereby granted|permission notice|Redistribution and use|public domain" "$f"; then lic="$lic permissive"
            else lic="$lic none:${f#$VLC/}"; fi
        done
        bad="$(xcrun dwarfdump --arch "$arch" --debug-line "$d" 2>/dev/null | sed -n 's/^ *name: "\(.*\)"/\1/p' \
               | sed "s|^$VLC/||; s|^\(\.\./\)*||" | sort -u | comm -12 - "$gplfiles" | tr '\n' ' ')"
        [ -n "$bad" ] && { nbad=$((nbad + 1)); bad="  GPL files: $bad"; }
        printf '%-42s %s%s\n' "$name" "$(tr ' ' '\n' <<<"$lic" | sort -u | tr '\n' ' ')" "$bad"
    done < <(find "$OUT/dSYMs" -name '*.dSYM' -type d | sort)
    rm -f "$gplfiles"
    local host; host="$(host_of "$arch")"
    echo "contribs linked in:"; ls "$VLC/contrib/$host"/lib/*.a | xargs -n1 basename | tr '\n' ' '; echo
    log "$n modules and libraries, $nbad with GPL-only files"
    [ "$nbad" = 0 ]
}

case "${1:-all}" in
    all)          prepare; build_arch arm64; build_arch x86_64; assemble arm64 x86_64; verify ;;
    arm64|x86_64) prepare; build_arch "$1"; assemble "$1"; verify ;;
    assemble)     shift; [ $# -gt 0 ] || set -- arm64 x86_64; assemble "$@"; verify ;; # out/ from built trees
    verify)       verify ;;
    licenses)     licenses ;;
    *)            sed -n '2,16p' "$0"; exit 1 ;;
esac
