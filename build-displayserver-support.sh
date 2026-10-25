#!/usr/bin/env bash
# =============================================================================
# build-displayserver-support.sh — cross-build driver for
# nextbsd-displayserver-support
# =============================================================================
#
# Builds the libraries and data both of NextBSD's display servers share (E25:
# the GNUstep WindowServer and XLibre) for ONE architecture, from pinned
# upstream release tarballs, into /usr (E25 D4) with upstream sonames: libdrm,
# pixman, expat, freetype, fontconfig, xkeyboard-config, libxkbcommon (core),
# epoll-shim, libudev (NextBSD's IOKit libudev), the <linux/input.h> shim,
# libevdev, mtdev and libinput. None of them links an X library or libwayland (E25 D2).
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   upstream meson (cross/meson/<arch>.ini), autotools
#               (cross/autotools/<arch>.site, --host=<triple>) or CMake
#               (cross/cmake/<arch>.cmake), out of tree, installed with
#               DESTDIR into .build/<name>-root-<arch>/;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Upstream build systems are used as they are, with NextBSD's options; nothing
# is rewritten as a hand-made makefile. Nothing here uses FreeBSD packages, the
# ports tree or ports tools. Besides sources.lock the inputs are the NextBSD
# base (compat) and nextbsd-userland's artifact on top of it, of which only
# libudev uses anything: libIOKit, CoreFoundation and libdispatch in
# /usr/lib/system, and their headers.
#
# Install layout (E25 D4; README "Paths"):
#   /usr/lib, /usr/include, /usr/bin, /usr/libexec/libinput   libraries, headers, tools
#   /usr/libdata/pkgconfig                                    every .pc file
#   /usr/share/{libdrm,fontconfig,libinput,xkeyboard-config-2,X11/xkb,...}  data
#   /etc/fonts                                                fontconfig's config:
#       built and staged into the sysroot, but NOT in the artifact; the image
#       gets it from nextbsd-overlays, which owns /etc (nextbsd-overlays#26)
#   /System/Library/LaunchDaemons/org.nextbsd.fc-cache.plist  the font-cache job
#       (launchd/), next to the userland's daemons, as nextbsd-printing-support
#       ships cupsd's
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools, python3, perl,
#   bison), with compat's `continuous` base and then nextbsd-userland's
#   `continuous` artifact extracted into $SYSROOT. $SYSROOT
#   is scratch: this script installs every component into it as it goes.
#
# USAGE
#   ./build-displayserver-support.sh           every component, in COMPONENTS order
#   ./build-displayserver-support.sh libdrm    named components only (their
#                                              dependencies must already be in
#                                              $SYSROOT)
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
DSS_CROSS="$ROOT/cross"

# Install prefix (E25 D4): /usr, not /usr/X11. .pc files go where the base
# keeps them under /usr, /usr/libdata/pkgconfig, whatever the upstream default
# (Source-Repo-Conventions). Configuration is read from /etc and state kept in
# /var, as for the base.
PREFIX=/usr
PC_DIR=/usr/libdata/pkgconfig
SYSCONFDIR=/etc
LOCALSTATEDIR=/var
# The X prefix, only for the paths compiled in that point at X's own data
# (fontconfig's X fonts, libxkbcommon's Compose tables from libX11). Nothing
# here installs there.
X_PREFIX=/usr/X11
# The only file installed outside $PREFIX: fontconfig's launchd job (launchd/),
# next to the userland's jobs.
LAUNCHD_DIR=/System/Library/LaunchDaemons

# The only places a component may install into (a file must be one of these
# or under one).
ALLOWED="
    usr/bin
    usr/lib
    usr/libexec/libinput
    usr/include
    usr/libdata/pkgconfig
    usr/share/man
    usr/share/aclocal
    usr/share/libdrm
    usr/share/fontconfig
    usr/share/xml/fontconfig
    usr/share/gettext/its
    usr/share/xkeyboard-config-2
    usr/share/X11/xkb
    usr/share/libinput
    etc/fonts
    System/Library/LaunchDaemons/org.nextbsd.fc-cache.plist
"
# Staged into the sysroot, left out of the artifact: /etc belongs to
# nextbsd-overlays (nextbsd-pkg#25), which ships /etc/fonts (nextbsd-overlays#26).
ARTIFACT_EXCLUDE=etc

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR DSS_CROSS

# pkgconf (ISC, never freedesktop's pkg-config) for this script's own checks:
# the sysroot's .pc directory only, -I/-L prefixed with the sysroot. meson,
# autotools and CMake set the same from the cross files.
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$SYSROOT$PC_DIR"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
unset PKG_CONFIG_PATH

READELF="$CROSS_BINDIR/llvm-readelf"

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$READELF" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# Assert a staged shared library carries the upstream soname.
soname_check() {
    local lib="$1" want="$2"
    "$READELF" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$lib does not have SONAME $want"
    note "SONAME ok: $want"
}

# so_check <soname>...: each staged /usr/lib/<soname> exists and carries that
# soname (the upstream one, as nextbsd-xlibs and nextbsd-xlibre shipped it).
so_check() {
    local s
    for s in "$@"; do
        [ -e "$DESTDIR$PREFIX/lib/$s" ] || fail "$PREFIX/lib/$s not staged"
        soname_check "$DESTDIR$PREFIX/lib/$s" "$s"
    done
}

# lib_needs <soname> <needed>...: a staged library links each <needed>.
lib_needs() {
    local lib="$DESTDIR$PREFIX/lib/$1" n
    shift
    for n in "$@"; do needed_check "$lib" "$n"; done
}

# not_needed <file> <pattern>...: a staged object links none of the libraries
# matching <pattern> (an extended regex on the DT_NEEDED name).
not_needed() {
    local obj="$1" p
    shift
    for p in "$@"; do
        if "$READELF" -d "$obj" | grep -E "NEEDED.*\[$p"; then
            fail "$(basename "$obj") links $p"
        fi
    done
    note "DT_NEEDED ok: $(basename "$obj") links none of: $*"
}

# names_path <file> <path>...: a staged binary has each path compiled in.
names_path() {
    local obj="$1" p
    shift
    for p in "$@"; do
        grep -q -a -F "$p" "$obj" || fail "$(basename "$obj") does not name $p"
        note "$(basename "$obj") names $p"
    done
}

# is_elf <file>: a regular file with the ELF magic.
is_elf() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c 4 "$1" | tail -c 3)" = ELF ]
}

# elf_checks <dir>: every ELF object under <dir> has no RPATH/RUNPATH naming
# the build host (this repo, the sysroot), /usr/local or /usr/X11 (the run-time
# linker finds /usr/lib by default; an /usr/X11 run path would load the old
# copies of these libraries beside the new ones), and no build-host path
# compiled into it at all.
elf_checks() {
    local dir="$1" f n=0
    while IFS= read -r f; do
        is_elf "$f" || continue
        if "$READELF" -d "$f" | grep -E '\((RPATH|RUNPATH)\)' | grep -F -e "$ROOT" -e "$SYSROOT" -e /usr/local -e "$X_PREFIX"; then
            fail "${f#"$dir"} has an RPATH/RUNPATH naming a build-host path, /usr/local or $X_PREFIX"
        fi
        if grep -q -a -F "$SYSROOT" "$f"; then
            grep -a -o "$SYSROOT[[:graph:]]*" "$f" | sort -u | sed 's/^/    | /' >&2
            fail "${f#"$dir"} has the build sysroot ($SYSROOT) compiled in"
        fi
        n=$((n + 1))
    done < <(find "$dir" -type f)
    note "$n ELF objects: no build-host, /usr/local or $X_PREFIX run paths"
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION.
fetch() {
    local name="$1" url sha file got
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, nextbsd-ports, a FreeBSD port file used
# as a reference, or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet < "$dir/$p" || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# meson_build [meson -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's cross file. The first cross file is generated here
# and carries the paths of this run; the second is the checked-in one.
meson_build() {
    local paths="$BUILD/cross/paths-$T.ini"
    mkdir -p "$BUILD/cross"
    cat > "$paths" <<EOF
[constants]
sysroot = '$SYSROOT'
llvm_bindir = '$CROSS_BINDIR'
EOF
    meson setup "$COMP_BUILD" "$SRC_DIR" \
        --cross-file "$paths" --cross-file "$DSS_CROSS/meson/$T.ini" \
        --prefix="$PREFIX" --libdir=lib --mandir=share/man \
        --sysconfdir="$SYSCONFDIR" --localstatedir="$LOCALSTATEDIR" \
        --buildtype=release -Ddefault_library=shared --wrap-mode=nodownload \
        "$@"
    meson compile -C "$COMP_BUILD"
    DESTDIR="$COMP_ROOT" meson install -C "$COMP_BUILD" --no-rebuild
}

# autotools_build [configure options...]: upstream configure in --host mode with
# the arch's CONFIG_SITE, out of tree; make; make install into $COMP_ROOT.
autotools_build() {
    (
        cd "$COMP_BUILD"
        CONFIG_SITE="$DSS_CROSS/autotools/$T.site" \
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --with-sysroot="$SYSROOT" \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" \
            --mandir="$PREFIX/share/man" \
            --sysconfdir="$SYSCONFDIR" --localstatedir="$LOCALSTATEDIR" \
            --enable-shared --disable-static \
            --disable-dependency-tracking --disable-silent-rules \
            "$@"
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
}

# cmake_build [cmake -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's toolchain file (cross/cmake/<arch>.cmake).
cmake_build() {
    cmake -S "$SRC_DIR" -B "$COMP_BUILD" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$DSS_CROSS/cmake/$T.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_MANDIR=share/man \
        -DBUILD_SHARED_LIBS=ON \
        "$@"
    cmake --build "$COMP_BUILD" $JOBS
    DESTDIR="$COMP_ROOT" cmake --install "$COMP_BUILD"
}

# The base's own files, listed while the sysroot is still the pristine compat
# base plus nextbsd-userland (libdrm's xf86drm.h, the first component's
# header, is the marker), so stage can refuse a component that would
# overwrite one. A later partial run reuses the list. Nothing here may build
# against nextbsd-xlibs or anything else in /usr/X11.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    mkdir -p "$BUILD"
    [ ! -e "$SYSROOT$X_PREFIX" ] \
        || fail "$SYSROOT$X_PREFIX exists: stage compat's base alone (nothing here builds against X)"
    if [ ! -e "$SYSROOT$PREFIX/include/xf86drm.h" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh compat base"
    fi
}

# stage <name>: tidy and check $COMP_ROOT, then copy it into $SYSROOT (for the
# components after this one) and $DESTDIR (the artifact).
#   - every file must be in one of the ALLOWED places, and nothing may replace
#     a base file;
#   - libtool .la files, docs and info manuals are dropped (man pages are kept);
#   - .pc files move to /usr/libdata/pkgconfig and must say prefix=/usr (or,
#     data-only, set no path outside /usr); none may name /usr/local, /usr/X11
#     or a build-host path, and no CMake package file a build-host path;
#   - ELF objects pass elf_checks;
#   - /etc (ARTIFACT_EXCLUDE) goes into the sysroot only.
stage() {
    local name="$1" r="$COMP_ROOT" x="$COMP_ROOT$PREFIX" f d rel ok stray clash
    find "$r" -name '*.la' -delete
    rm -rf "$x/share/doc" "$x/share/info"
    # meson puts a library's .pc in libdata/pkgconfig when host_machine is
    # freebsd (the base layout), arch-independent ones in share/pkgconfig;
    # autotools uses lib/pkgconfig.
    for d in lib/pkgconfig share/pkgconfig; do
        [ -d "$x/$d" ] || continue
        mkdir -p "$r$PC_DIR"
        mv "$x/$d"/*.pc "$r$PC_DIR/"
        rmdir "$x/$d"
    done
    find "$r" -mindepth 1 -type d -empty -delete
    [ -n "$(cd "$r" && find . ! -type d)" ] || fail "$name installed nothing"
    stray=""
    while IFS= read -r rel; do
        ok=no
        for d in $ALLOWED; do
            case "$rel" in "$d"|"$d"/*) ok=yes; break ;; esac
        done
        [ "$ok" = yes ] || stray="$stray /$rel"
    done < <(cd "$r" && find . ! -type d | sed 's#^\./##')
    [ -z "$stray" ] || fail "$name installed outside the allowed paths:$stray"
    for f in "$r$PC_DIR"/*.pc; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && continue
        # A data-only .pc (xkeyboard-config's) has no prefix= line; then
        # every absolute path it sets must be under the prefix.
        if grep -q '^prefix=' "$f"; then
            grep -q "^prefix=$PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $PREFIX"
        elif grep -E '^[A-Za-z_]+=/' "$f" | grep -v -E "^[A-Za-z_]+=$PREFIX(/|\$)"; then
            fail "$(basename "$f"): sets a path outside $PREFIX"
        fi
        if grep -n -F -e /usr/local -e "$X_PREFIX" -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local, $X_PREFIX or a build-host path"
        fi
    done
    for f in "$x"/lib/cmake/*/*.cmake; do
        [ -e "$f" ] || continue
        if grep -n -F -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names a build-host path"
        fi
    done
    elf_checks "$r"
    clash=$(cd "$r" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base: $clash"
    (cd "$r" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$r" && tar -cf - --exclude="./$ARTIFACT_EXCLUDE" .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$r" && find . ! -type d | wc -l) files ($(cd "$r" && find "./$ARTIFACT_EXCLUDE" ! -type d 2>/dev/null | wc -l) under /$ARTIFACT_EXCLUDE: sysroot only, not in the artifact)"
}

# launchd_check <plist> <label> <program>: a well-formed launchd job (xmllint
# if the image has it, else a structural grep) with NextBSD's label, running a
# program this repo ships, and silent: stdout and stderr go to a file, never
# the console.
launchd_check() {
    local p="$1" label="$2" prog="$3"
    [ -f "$p" ] || fail "${p#"$DESTDIR"} was not staged"
    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$p" || fail "${p#"$DESTDIR"} is not well-formed XML"
    else
        grep -q '^<plist version="1.0">$' "$p" && grep -q '^</plist>$' "$p" \
            || fail "${p#"$DESTDIR"} is not a plist"
    fi
    grep -q "<string>$label</string>" "$p" || fail "${p#"$DESTDIR"} does not carry the $label label"
    grep -q "<string>$prog</string>" "$p" || fail "${p#"$DESTDIR"} does not run $prog"
    [ -x "$DESTDIR$prog" ] || fail "${p#"$DESTDIR"} runs $prog, which is not staged"
    if grep -n '<string>com\.apple\.' "$p"; then
        fail "${p#"$DESTDIR"} carries an Apple identifier"
    fi
    for k in StandardOutPath StandardErrorPath; do
        grep -A1 "<key>$k</key>" "$p" | grep -q '<string>/var/log/' \
            || fail "${p#"$DESTDIR"}: $k does not go to /var/log"
    done
    note "launchd job ok: $label (${p#"$DESTDIR"})"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components will see it (and, if given, at that version).
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}

# pc_var <module> <variable>: a .pc variable as written (no sysroot prefix).
pc_var() {
    PKG_CONFIG_SYSROOT_DIR= pkgconf --variable="$2" "$1"
}

# =============================================================================
# Host build tools (built on the runner, never shipped)
# =============================================================================
# gperf for fontconfig's object hash. The toolchain image's gperf is used when
# the image has one; otherwise the pin in sources.lock is built with the
# runner's cc (as nextbsd-xlibs did).
host_gperf() {
    GPERF="$BUILD/host/bin/gperf"
    if [ ! -x "$GPERF" ] && command -v gperf >/dev/null 2>&1; then
        note "gperf from the toolchain image: $(gperf --version | head -1)"
        return 0
    fi
    if [ -x "$GPERF" ] && "$GPERF" --version | head -1 | grep -q " $(lock_field gperf version)\$"; then
        return 0
    fi
    comp "gperf $(lock_field gperf version) [host tool]"
    fetch gperf
    (
        cd "$SRC_DIR"
        ./configure --prefix="$BUILD/host" >/dev/null
        make $JOBS
    )
    mkdir -p "$BUILD/host/bin"
    install -m 0755 "$SRC_DIR/src/gperf" "$GPERF"
    note "$("$GPERF" --version | head -1)"
}

# =============================================================================
# Components, in build order (E25 audit 1, section 4.2, with libxkbcommon
# before xkeyboard-config; see build_libxkbcommon): graphics and fonts,
# keyboard, then the input stack.
# =============================================================================

# libdrm — the DRM userspace library (libdrm.so.2) and the kernel uapi headers
# under include/libdrm, for Mesa (GBM, EGL, the gallium drivers), the server's
# modesetting driver and the WindowServer. meson.
#
# patches/libdrm: the nextbsd-ports patches (platform-bus devices, so vc4 and
# v3d are enumerated; ETIME in libsync.h) and the render-node fix (a render
# node belongs to the device that owns it, not to hw.dri.<minor - 128>).
#
# Components follow Mesa's drivers (E23 D6, E25 D6), per arch:
#   amd64  amdgpu (radeonsi) and radeon (r600, the ati DDX).
#   arm64  vc4 (headers and .pc only). v3d has no libdrm component; its uapi
#          header comes from Mesa's include/drm-uapi.
# Off everywhere: intel (libdrm_intel needs libpciaccess, and only gallium
# i915 and the intel DDX use it; iris and crocus need just i915_drm.h, which
# core libdrm installs), vmwgfx (no kernel driver), omap, exynos, freedreno,
# tegra, etnaviv and nouveau (no kernel drivers), the test programs, cairo,
# valgrind, udev and the man pages (rst2man is not in the toolchain image).
# amdgpu.ids (marketing names for AMD GPUs) is read from /usr/share/libdrm.
build_libdrm() {
    comp "libdrm [meson cross]"
    fresh_dirs libdrm
    fetch libdrm
    local amd=disabled vc4=disabled
    case "$T" in
        amd64) amd=enabled ;;
        arm64) vc4=enabled ;;
    esac
    meson_build \
        -Damdgpu="$amd" -Dradeon="$amd" -Dnouveau=disabled -Dvc4="$vc4" \
        -Dintel=disabled -Dvmwgfx=disabled \
        -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
        -Dfreedreno-kgsl=false -Dtegra=disabled -Detnaviv=disabled \
        -Dtests=false -Dinstall-test-programs=false -Dcairo-tests=disabled \
        -Dvalgrind=disabled -Dudev=false -Dman-pages=disabled
    stage libdrm
    local x="$DESTDIR$PREFIX" lib
    test -f "$x/include/xf86drm.h" || fail "xf86drm.h not staged"
    test -f "$x/include/libdrm/drm.h" || fail "libdrm/drm.h not staged"
    test -f "$x/include/libdrm/i915_drm.h" || fail "libdrm/i915_drm.h not staged"
    so_check libdrm.so.2
    # The FreeBSD branch of xf86drm.c, with the platform-bus and render-node
    # patches, is what was compiled.
    grep -q -a -F 'hw.dri.%d.name' "$x/lib/libdrm.so.2" \
        || fail "libdrm.so.2 lacks the render-node lookup (patches/libdrm not built in?)"
    note "render-node lookup compiled in"
    pc_check libdrm "$VERSION"
    case "$T" in
        amd64)
            for lib in amdgpu radeon; do
                so_check "libdrm_$lib.so.1"
                needed_check "$x/lib/libdrm_$lib.so.1" libdrm.so.2
                pc_check "libdrm_$lib" "$VERSION"
            done
            test -f "$x/share/libdrm/amdgpu.ids" || fail "libdrm/amdgpu.ids not staged"
            names_path "$x/lib/libdrm_amdgpu.so.1" "$PREFIX/share/libdrm/amdgpu.ids"
            ;;
        arm64)
            test -f "$x/include/libdrm/vc4_packet.h" || fail "libdrm/vc4_packet.h not staged"
            pc_check libdrm_vc4 "$VERSION"
            ;;
    esac
    for lib in intel freedreno etnaviv nouveau; do
        if ls "$x"/lib/libdrm_"$lib"* >/dev/null 2>&1; then
            fail "disabled libdrm component $lib was built"
        fi
    done
}

# pixman — pixel manipulation (the server, cairo, the WindowServer). meson.
# SIMD paths are the upstream defaults for each arch; no tests, demos, GTK,
# libpng or OpenMP.
build_pixman() {
    comp "pixman [meson cross]"
    fresh_dirs pixman
    fetch pixman
    meson_build -Dtests=disabled -Ddemos=disabled -Dgtk=disabled \
        -Dlibpng=disabled -Dopenmp=disabled -Dtimers=false -Dgnuplot=false
    stage pixman
    so_check libpixman-1.so.0
    pc_check pixman-1 "$VERSION"
}

# expat — upstream XML parser, public libexpat.so.1 (E25 audit 3, 4.1 option
# A; fontconfig and Mesa's driconf link it). Base's libbsdxml is expat renamed
# for base use only; it is not used, and nothing here touches it (the base has
# no libexpat or expat.h, which stage checks). autotools; no xmlwf, examples,
# tests or DocBook man page.
build_expat() {
    comp "expat [autotools cross]"
    fresh_dirs expat
    fetch expat
    autotools_build --without-xmlwf --without-examples --without-tests --without-docbook
    stage expat
    test -f "$DESTDIR$PREFIX/include/expat.h" || fail "expat.h not staged"
    so_check libexpat.so.1
    pc_check expat "$VERSION"
}

# freetype — font rasteriser (libXft, libXfont2, fontconfig, cairo). meson.
# zlib and bzip2 from the NextBSD base; no libpng (it lives in
# nextbsd-gnustep-support, which builds later; colour bitmap glyphs don't
# render), no harfbuzz (harfbuzz needs freetype: a loop), no brotli (not in
# base, so no WOFF2).
build_freetype() {
    comp "freetype [meson cross]"
    fresh_dirs freetype
    fetch freetype
    meson_build -Dzlib=system -Dbzip2=enabled -Dpng=disabled -Dharfbuzz=disabled \
        -Dbrotli=disabled -Dtests=disabled
    stage freetype
    so_check libfreetype.so.6
    lib_needs libfreetype.so.6 libz.so.6 libbz2.so.4
    not_needed "$DESTDIR$PREFIX/lib/libfreetype.so.6" 'libpng' 'libharfbuzz' 'libbrotli'
    pc_check freetype2
}

# fontconfig — font configuration and matching. meson, with upstream expat and
# gperf on the build host. Paths (README "fontconfig"):
#   config     /etc/fonts (fonts.conf, conf.d -> /usr/share/fontconfig/conf.avail)
#   templates  /usr/share/fontconfig/conf.avail
#   cache      /var/cache/fontconfig; per-user caches stay in ~/.cache/fontconfig
#   fonts      /System/Library/Fonts, /Local/Library/Fonts, /Network/Library/Fonts,
#              ~/Library/Fonts (NextBSD's domains, as in nextbsd-xlibs), then
#              /usr/X11/share/fonts (XLibre's fonts)
# /etc/fonts is built and staged into the sysroot (and printed below) but is
# not in the artifact: nextbsd-overlays ships it (nextbsd-overlays#26), and an
# org.nextbsd.fc-cache launchd job (launchd/, installed here next to fc-cache)
# builds the cache at boot. fc-cache cannot run at install time on the build
# host (cache-build off); the tools (fc-cache, fc-list, fc-match, ...) are
# built and shipped. No NLS, iconv, docs or tests.
build_fontconfig() {
    host_gperf
    comp "fontconfig [meson cross]"
    fresh_dirs fontconfig
    fetch fontconfig
    PATH="$BUILD/host/bin:$PATH" meson_build \
        -Dxml-backend=expat -Ddoc=disabled -Dnls=disabled -Dtests=disabled \
        -Dtools=enabled -Dcache-build=disabled -Diconv=disabled -Dfontations=disabled \
        -Dbaseconfig-dir="$SYSCONFDIR/fonts" \
        -Dtemplate-dir="$PREFIX/share/fontconfig/conf.avail" \
        -Dcache-dir="$LOCALSTATEDIR/cache/fontconfig" \
        -Ddefault-fonts-dirs=/System/Library/Fonts,/Local/Library/Fonts,/Network/Library/Fonts,~/Library/Fonts \
        -Dadditional-fonts-dirs="$X_PREFIX/share/fonts"
    install -d -m 0755 "$COMP_ROOT$LAUNCHD_DIR"
    install -m 0644 "$ROOT/launchd/org.nextbsd.fc-cache.plist" "$COMP_ROOT$LAUNCHD_DIR/"
    stage fontconfig
    local x="$DESTDIR$PREFIX" conf="$SYSROOT$SYSCONFDIR/fonts/fonts.conf" d
    test -f "$conf" || fail "$SYSCONFDIR/fonts/fonts.conf not built"
    [ ! -e "$DESTDIR$SYSCONFDIR" ] || fail "$SYSCONFDIR is in the artifact"
    grep -q "<cachedir>$LOCALSTATEDIR/cache/fontconfig</cachedir>" "$conf" \
        || fail "fonts.conf does not name $LOCALSTATEDIR/cache/fontconfig"
    for d in /System/Library/Fonts /Local/Library/Fonts /Network/Library/Fonts '~/Library/Fonts' "$X_PREFIX/share/fonts"; do
        grep -q "<dir>$d</dir>" "$conf" || fail "fonts.conf does not name $d"
    done
    if grep -n /usr/local "$conf"; then
        fail "fonts.conf names /usr/local"
    fi
    test -d "$x/share/fontconfig/conf.avail" || fail "$PREFIX/share/fontconfig/conf.avail not staged"
    test -x "$x/bin/fc-cache" || fail "fc-cache not staged"
    so_check libfontconfig.so.1
    lib_needs libfontconfig.so.1 libfreetype.so.6 libexpat.so.1
    names_path "$x/lib/libfontconfig.so.1" "$SYSCONFDIR/fonts" "$LOCALSTATEDIR/cache/fontconfig" \
        "$PREFIX/share/fontconfig/conf.avail"
    pc_check fontconfig "$VERSION"
    launchd_check "$DESTDIR$LAUNCHD_DIR/org.nextbsd.fc-cache.plist" org.nextbsd.fc-cache /usr/bin/fc-cache
    # What nextbsd-overlays should ship as /etc/fonts (nextbsd-overlays#26).
    echo "    - $SYSCONFDIR/fonts as built (sysroot only; nextbsd-overlays ships it):"
    (cd "$SYSROOT$SYSCONFDIR/fonts" && find . ! -type d | LC_ALL=C sort | while IFS= read -r f; do
        if [ -L "$f" ]; then echo "        $SYSCONFDIR/fonts/${f#./} -> $(readlink "$f")"
        else echo "        $SYSCONFDIR/fonts/${f#./}"; fi
    done)
    echo "    ---- $SYSCONFDIR/fonts/fonts.conf ----"
    sed 's/^/    | /' "$conf"
    echo "    ---- end of fonts.conf ----"
}

# xkeyboard-config — the XKB keymap database. meson (python3 generates the
# rules files, perl the .lst files on the build host). The data goes in
# /usr/share/xkeyboard-config-2, with upstream's /usr/share/X11/xkb link to it:
# that is where libxkbcommon below, and XLibre's xkbcomp and server, look.
# Upstream installs the link with an absolute target; it is made relative
# (../xkeyboard-config-2) so it also resolves inside a sysroot. Compatibility
# rules on (upstream default), no "xorg" rules links (the server's default
# rules are evdev), no NLS (translated descriptions in the registry XML only;
# msgfmt is not in the toolchain image). The man page needs xsltproc, which the
# image does not have, so it is not built.
build_xkeyboard_config() {
    comp "xkeyboard-config [meson cross]"
    fresh_dirs xkeyboard-config
    fetch xkeyboard-config
    meson_build -Dnls=false -Dcompat-rules=true -Dxorg-rules-symlinks=false \
        -Dnon-latin-layouts-list=false
    local l="$COMP_ROOT$PREFIX/share/X11/xkb" link
    link=$(readlink "$l") || fail "xkeyboard-config installed no $PREFIX/share/X11/xkb link"
    [ "$link" = "$PREFIX/share/xkeyboard-config-2" ] \
        || fail "$PREFIX/share/X11/xkb points to $link, not $PREFIX/share/xkeyboard-config-2"
    rm "$l"
    ln -s ../xkeyboard-config-2 "$l"
    stage xkeyboard-config
    local x="$DESTDIR$PREFIX" d="$DESTDIR$PREFIX/share/xkeyboard-config-2" f
    for f in rules/evdev rules/base rules/evdev.xml rules/evdev.lst rules/base.lst \
             keycodes/evdev symbols/us symbols/pc types/basic compat/basic; do
        test -f "$d/$f" || fail "xkeyboard-config-2/$f not staged"
        test -f "$SYSROOT$PREFIX/share/X11/xkb/$f" || fail "$PREFIX/share/X11/xkb/$f does not resolve in the sysroot"
    done
    note "$PREFIX/share/X11/xkb -> $(readlink "$x/share/X11/xkb") (resolves in the sysroot)"
    pc_check xkeyboard-config "$VERSION"
    [ "$(pc_var xkeyboard-config xkb_base)" = "$PREFIX/share/X11/xkb" ] \
        || fail "xkeyboard-config.pc: xkb_base is not $PREFIX/share/X11/xkb"
    note "xkeyboard-config.pc: xkb_base=$PREFIX/share/X11/xkb"
}

# libxkbcommon (core) — keymap handling for the WindowServer, libinput users
# and xdotool. meson. libxkbcommon-x11 needs libxcb and stays in nextbsd-xlibs,
# built from this same tarball (E25 D5), so -Denable-x11=false here. Paths:
#   xkb root         /usr/share/X11/xkb (xkeyboard-config above)
#   extra path       /etc/xkb (local additions; nextbsd-overlays#26)
#   X locale root    /usr/X11/share/X11/locale, the Compose tables libX11
#                    installs (nextbsd-xlibs)
# It builds BEFORE xkeyboard-config, as it did in nextbsd-xlibs, where no
# xkeyboard-config.pc was in the sysroot: when meson finds that .pc it takes
# the legacy root (DFLT_XKB_LEGACY_ROOT, which has no option) from pkgconf,
# and pkgconf prefixes it with the build sysroot. Without it the legacy root
# is upstream's $datadir/X11/xkb, /usr/share/X11/xkb, and the xkeyboard-config
# extension paths stay unset, as before the move. elf_checks refuses the
# library if the sysroot is ever compiled in.
# No tools, Wayland (E25 D2), xkbregistry (it needs libxml2), docs or bash
# completion.
build_libxkbcommon() {
    comp "libxkbcommon [meson cross]"
    fresh_dirs libxkbcommon
    fetch libxkbcommon
    meson_build -Denable-tools=false -Denable-wayland=false -Denable-xkbregistry=false \
        -Denable-docs=false -Denable-bash-completion=false -Denable-x11=false \
        -Dxkb-config-root="$PREFIX/share/X11/xkb" \
        -Dxkb-config-extra-path="$SYSCONFDIR/xkb" \
        -Dx-locale-root="$X_PREFIX/share/X11/locale"
    stage libxkbcommon
    local x="$DESTDIR$PREFIX"
    test -f "$x/include/xkbcommon/xkbcommon.h" || fail "xkbcommon/xkbcommon.h not staged"
    so_check libxkbcommon.so.0
    if ls "$x"/lib/libxkbcommon-x11* "$x"/include/xkbcommon/xkbcommon-x11.h >/dev/null 2>&1; then
        fail "libxkbcommon-x11 was built (it stays in nextbsd-xlibs)"
    fi
    not_needed "$x/lib/libxkbcommon.so.0" 'libwayland' 'libxcb' 'libX11' 'libxml2'
    names_path "$x/lib/libxkbcommon.so.0" "$PREFIX/share/X11/xkb" "$SYSCONFDIR/xkb" \
        "$X_PREFIX/share/X11/locale"
    pc_check xkbcommon "$VERSION"
}

# epoll-shim — epoll(7), signalfd(2) on kqueue: libinput links it, and the
# XLibre server's meson requires its .pc on FreeBSD. CMake.
#
# NextBSD's libc has eventfd(2) and timerfd_create(2), so epoll-shim builds and
# installs neither (as the FreeBSD port does on 15): its sys/eventfd.h and
# sys/timerfd.h would shadow the base headers. Its headers live in
# /usr/include/libepoll-shim, added by epoll-shim.pc, never in
# /usr/include/sys. Two configure checks run a target program and are
# answered here for cross builds:
#   ALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO  FreeBSD's EVFILT_TIMER accepts a
#       zero timeout with EV_ONESHOT (filt_timerattach only bumps 0 to 1 for
#       periodic timers), so the quirk stays off;
#   the POLLRDHUP probe  its value is read from the sysroot's sys/poll.h. The
#       probe program calls printf without <stdio.h>, which clang 19 refuses,
#       so the build falls back to upstream's 0x2000 as it does natively; the
#       answer only matters if that ever compiles.
# The tests (and microatf, the test framework they need) are off.
build_epoll_shim() {
    comp "epoll-shim [cmake cross]"
    fresh_dirs epoll-shim
    fetch epoll-shim
    local rdhup h
    rdhup=$(awk '$1 == "#define" && $2 == "POLLRDHUP" { print $3 }' "$SYSROOT/usr/include/sys/poll.h")
    [ -n "$rdhup" ] || fail "POLLRDHUP not found in the sysroot's sys/poll.h"
    cmake_build -DBUILD_TESTING=OFF \
        -DALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO=1 \
        -DHAVE_POLLRDHUP_RUN_RESULT=0 \
        -DHAVE_POLLRDHUP_RUN_RESULT__TRYRUN_OUTPUT="$rdhup"
    stage epoll-shim
    local x="$DESTDIR$PREFIX/include/libepoll-shim"
    test -f "$x/sys/epoll.h" || fail "libepoll-shim/sys/epoll.h not staged"
    test -f "$x/sys/signalfd.h" || fail "libepoll-shim/sys/signalfd.h not staged"
    for h in eventfd timerfd; do
        [ ! -e "$x/sys/$h.h" ] || fail "libepoll-shim/sys/$h.h staged; the base's sys/$h.h must be used"
    done
    note "EPOLLRDHUP is $(awk '$2 == "EPOLLRDHUP" { print $3 }' "$x/sys/epoll.h")"
    so_check libepoll-shim.so.0 libepoll-shim-interpose.so.0
    lib_needs libepoll-shim-interpose.so.0 libepoll-shim.so.0
    pc_check epoll-shim
    pc_check epoll-shim-interpose
}

# libudev — NextBSD's IOKit libudev (E25 D7, nextbsd-displayserver-support#2):
# libudev-devd 0.7.0 (BSD-2-Clause) with its input device source and monitor
# replaced (patches/libudev, Origin: NextBSD). meson. libinput and the X
# server enumerate input devices and follow hotplug through it.
#
#   enumerate  IOServiceGetMatchingServices(IOServiceMatching("IOHIDDevice")):
#              one registry entry per /dev/input/eventN (nextbsd-kernel#331);
#              everything else (/dev/dri/card*, ...) is still found in devfs,
#              as libudev-devd did
#   properties DEVNAME, MAJOR/MINOR/devnum, ID_INPUT + ID_INPUT_* (from
#              PrimaryUsagePage/PrimaryUsage), ID_VENDOR_ID, ID_MODEL_ID,
#              ID_INTEGRATION, and a parent with NAME, PRODUCT and UNIQ, from
#              the entry's keys; the kern.evdev.input sysctls only as fallback
#   monitor    IOServiceAddMatchingNotification (first-match + terminated) on
#              a private dispatch queue, which writes to a pipe whose read end
#              is the pollable monitor fd; no devd socket
#
# Same soname (libudev.so.0), header and libudev.pc (the udev 243 API level
# libudev-devd claims) as before, so nothing that links it changes. It links
# libIOKit, CoreFoundation and libdispatch from nextbsd-userland, in
# /usr/lib/system (found at run time through ldconfig's /usr/lib/system
# entry; no RPATH); -L for them goes in c_link_args, so neither the .pc file
# nor the library names the build sysroot. The GPL code (enable-gpl) stays
# off; -Werror is off as before (clang 19 warns where 0.7.0 predates it).
build_libudev() {
    comp "libudev (IOKit) [meson cross]"
    fresh_dirs libudev
    fetch libudev
    meson_build -Dwerror=false -Denable-gpl=false \
        -Dc_link_args="-L$SYSROOT/usr/lib/system"
    stage libudev
    local x="$DESTDIR$PREFIX" lib
    lib="$x/lib/libudev.so.0"
    test -f "$x/include/libudev.h" || fail "libudev.h not staged"
    so_check libudev.so.0
    # (userland's libdispatch has an unversioned soname, libsystem_dispatch.so.)
    lib_needs libudev.so.0 libIOKit.so.1 libCoreFoundation.so.6 libsystem_dispatch.so \
        libdevinfo.so libprocstat.so
    # The IOKit device source and monitor are what was compiled, and the
    # devd monitor is gone.
    names_path "$lib" IOHIDDevice org.nextbsd.DevNode
    if grep -q -a -F devd.seqpacket.pipe "$lib"; then
        fail "libudev.so.0 still opens devd's socket (patches/libudev not built in?)"
    fi
    note "no devd socket in libudev.so.0"
    # The .pc keeps libudev-devd's udev 243 API level; libinput asks for none.
    pc_check libudev 243
    libudev_consumer_check
}

# libudev_consumer_check: a program that calls the libudev functions
# libinput 1.32 (udev and path backends), XLibre's config/udev.c and its
# modesetting driver use builds with nothing but
# `pkgconf --cflags --libs libudev`, and links libudev.so.0 with no RPATH.
# lld resolves each call against the staged library, so a missing export
# fails here. Nothing is run (cross build).
libudev_consumer_check() {
    local t="$BUILD/libudev-consumer-$T" flags
    mkdir -p "$t"
    cat > "$t/consumer.c" <<'CEOF'
#include <sys/types.h>
#include <stdint.h>
#include <stdio.h>
#include <libudev.h>

int
main(void)
{
	struct udev *u = udev_new();
	struct udev_monitor *m = udev_monitor_new_from_netlink(u, "udev");
	struct udev_enumerate *e = udev_enumerate_new(u);
	struct udev_list_entry *l;
	struct udev_device *d, *p;

	udev_monitor_filter_add_match_subsystem_devtype(m, "input", NULL);
	udev_monitor_filter_add_match_tag(m, "seat0");
	udev_monitor_enable_receiving(m);
	udev_enumerate_add_match_subsystem(e, "input");
	udev_enumerate_add_match_sysname(e, "event[0-9]*");
	udev_enumerate_add_match_tag(e, "seat0");
	udev_enumerate_scan_devices(e);
	udev_list_entry_foreach(l, udev_enumerate_get_list_entry(e)) {
		d = udev_device_new_from_syspath(udev_enumerate_get_udev(e),
		    udev_list_entry_get_name(l));
		if (d == NULL)
			continue;
		p = udev_device_get_parent(d);
		(void)udev_device_get_parent_with_subsystem_devtype(d, "input",
		    NULL);
		printf("%s %s %s %s %s %d %ju %s %s %s\n",
		    udev_device_get_syspath(d), udev_device_get_sysname(d),
		    udev_device_get_devnode(d), udev_device_get_subsystem(d),
		    udev_device_get_action(d),
		    udev_device_get_is_initialized(d),
		    (uintmax_t)udev_device_get_devnum(d),
		    udev_device_get_property_value(d, "ID_INPUT"),
		    p != NULL ? udev_device_get_sysattr_value(p, "name") : "",
		    udev_list_entry_get_value(
		    udev_device_get_properties_list_entry(d)));
		(void)udev_device_get_udev(d);
		udev_device_unref(udev_device_ref(d));
	}
	d = udev_device_new_from_devnum(u, 'c', 0);
	udev_device_unref(d);
	d = udev_monitor_receive_device(m);
	udev_device_unref(d);
	(void)udev_monitor_get_fd(m);
	(void)udev_monitor_get_udev(m);
	udev_enumerate_unref(e);
	udev_monitor_unref(m);
	udev_unref(udev_ref(u));
	return (0);
}
CEOF
    flags=$(pkgconf --cflags --libs libudev) || fail "pkgconf --cflags --libs libudev"
    "$CROSS_BINDIR/clang" --target="$CROSS_TRIPLE" --sysroot="$SYSROOT" -fuse-ld=lld \
        -o "$t/consumer" "$t/consumer.c" $flags \
        || fail "a libudev consumer does not build with pkgconf --cflags --libs libudev ($flags)"
    needed_check "$t/consumer" libudev.so.0
    if "$READELF" -d "$t/consumer" | grep -E '\((RPATH|RUNPATH)\)'; then
        fail "the libudev consumer got an RPATH/RUNPATH"
    fi
    note "consumer builds with pkgconf --cflags --libs libudev: '$(echo $flags | sed "s#$SYSROOT##g")'"
}

# linux-input-shim — <linux/input.h>, <linux/input-event-codes.h> and
# <linux/uinput.h>, each one #include of the base's <dev/evdev/...> header
# (NextBSD's kernel evdev(4) ABI, the same structures and ioctls as Linux's).
# NextBSD's own, no upstream source.
#
# They go in /usr/include/linux-input-shim/linux, never /usr/include/linux:
# many configure and meson checks read <linux/*.h> as "this is Linux" (E25
# audit 3, 4.4). linux-input-shim.pc adds the directory
# (-I/usr/include/linux-input-shim), and libevdev.pc and mtdev.pc require it
# (patches/libevdev, patches/mtdev), so `pkgconf --cflags libevdev mtdev` is
# all a consumer of the installed libevdev.h and mtdev.h needs; XLibre's
# evdev, libinput, synaptics and joystick drivers, which include
# <linux/input.h> themselves, ask for linux-input-shim. FreeBSD gets the
# header from the devel/evdev-proto port, Linux's GPL uapi headers with sed
# fixes; NextBSD's base already has the BSD-licensed headers they map to.
build_linux_input_shim() {
    comp "linux-input-shim [headers, NextBSD]"
    fresh_dirs linux-input-shim
    local inc="$COMP_ROOT$PREFIX/include/linux-input-shim/linux" h got
    install -d "$inc" "$COMP_ROOT$PC_DIR"
    for h in input input-event-codes uinput; do
        [ -f "$SYSROOT/usr/include/dev/evdev/$h.h" ] || fail "the sysroot has no dev/evdev/$h.h"
        printf '%s\n' \
            "/* NextBSD: <linux/$h.h> is the base kernel's evdev(4) ABI. */" \
            "#include <dev/evdev/$h.h>" > "$inc/$h.h"
        chmod 0644 "$inc/$h.h"
    done
    cat > "$COMP_ROOT$PC_DIR/linux-input-shim.pc" <<EOF
prefix=$PREFIX
includedir=\${prefix}/include

Name: linux-input-shim
Description: NextBSD <linux/input.h>, <linux/input-event-codes.h> and <linux/uinput.h> on the base's <dev/evdev/...> headers
Version: 1.0
Cflags: -I\${includedir}/linux-input-shim
EOF
    chmod 0644 "$COMP_ROOT$PC_DIR/linux-input-shim.pc"
    stage linux-input-shim
    [ ! -e "$SYSROOT$PREFIX/include/linux" ] || fail "$PREFIX/include/linux exists"
    pc_check linux-input-shim
    got=$(pkgconf --cflags linux-input-shim)
    [ "$(echo $got)" = "-I$SYSROOT$PREFIX/include/linux-input-shim" ] \
        || fail "pkgconf --cflags linux-input-shim is '$got'"
    note "pkgconf --cflags linux-input-shim: -I$PREFIX/include/linux-input-shim"
}

# libevdev — the evdev device wrapper libinput (and XLibre's xf86-input-evdev)
# uses. meson; python3 generates the event-name tables on the build host. The
# kernel interface comes from the copy of NextBSD's dev/evdev/input.h the
# tarball carries (include/linux/freebsd/, picked by host_machine.system()).
# patches/libevdev: libevdev.pc requires linux-input-shim. The tools
# (libevdev-tweak-device, mouse-dpi-tool, touchpad-edge-detector) are built;
# the tests (they need check) and the doxygen docs are not.
build_libevdev() {
    comp "libevdev [meson cross]"
    fresh_dirs libevdev
    fetch libevdev
    meson_build -Dtests=disabled -Ddocumentation=disabled -Dtools=enabled
    stage libevdev
    local x="$DESTDIR$PREFIX" t h
    for h in libevdev libevdev-uinput; do
        test -f "$x/include/libevdev-1.0/libevdev/$h.h" || fail "libevdev/$h.h not staged"
    done
    for t in libevdev-tweak-device mouse-dpi-tool touchpad-edge-detector; do
        test -x "$x/bin/$t" || fail "$t not staged"
    done
    so_check libevdev.so.2
    pc_check libevdev "$VERSION"
    grep -q '^Requires:.*linux-input-shim' "$SYSROOT$PC_DIR/libevdev.pc" \
        || fail "libevdev.pc does not require linux-input-shim (patches/libevdev)"
}

# mtdev — turns multitouch protocol A devices into protocol B slots for
# libinput. autotools.
#
# mtdev.h includes <linux/input.h>: the library's own build gets it from
# linux-input-shim (above), through its .pc's cflags. patches/mtdev:
# mtdev.pc requires linux-input-shim. Then the installed libevdev and mtdev
# headers are compiled with nothing but pkgconf's flags (input_headers_check).
build_mtdev() {
    comp "mtdev [autotools cross]"
    fresh_dirs mtdev
    fetch mtdev
    autotools_build CPPFLAGS="$(pkgconf --cflags linux-input-shim)"
    stage mtdev
    test -f "$DESTDIR$PREFIX/include/mtdev.h" || fail "mtdev.h not staged"
    test -x "$DESTDIR$PREFIX/bin/mtdev-test" || fail "mtdev-test not staged"
    so_check libmtdev.so.1
    pc_check mtdev "$VERSION"
    grep -q '^Requires:.*linux-input-shim' "$SYSROOT$PC_DIR/mtdev.pc" \
        || fail "mtdev.pc does not require linux-input-shim (patches/mtdev)"
    input_headers_check
}

# input_headers_check: the installed libevdev.h, libevdev-uinput.h and mtdev.h
# compile, alone and together, with only `pkgconf --cflags` of their own
# modules (no -I added by hand), and what the drivers use from the shim
# (<linux/uinput.h>'s struct uinput_setup among it; libevdev-uinput.h only
# forward-declares the uinput structures) is there.
input_headers_check() {
    local t="$BUILD/input-headers-$T" mods cflags src
    mkdir -p "$t"
    printf '%s\n' '#include <sys/ioctl.h>' '#include <libevdev/libevdev.h>' \
        '#include <libevdev/libevdev-uinput.h>' \
        'int f(int fd) { struct input_event ev; struct input_absinfo ai;' \
        '  (void)ev; (void)ai; return ioctl(fd, EVIOCGRAB, 1) + KEY_MAX + BUS_USB; }' > "$t/libevdev.c"
    printf '%s\n' '#include <mtdev.h>' \
        'int f(void) { struct input_event ev; (void)ev; return ABS_MT_SLOT + MT_ABS_SIZE; }' > "$t/mtdev.c"
    printf '%s\n' '#include <sys/ioctl.h>' '#include <libevdev/libevdev.h>' \
        '#include <libevdev/libevdev-uinput.h>' '#include <mtdev.h>' \
        '#include <linux/input.h>' '#include <linux/input-event-codes.h>' '#include <linux/uinput.h>' \
        'int f(int fd) { struct input_event ev; struct uinput_setup us; (void)ev; (void)us;' \
        '  return ioctl(fd, EVIOCGRAB, 1) + KEY_MAX + ABS_MT_SLOT + MT_ABS_SIZE + BUS_USB; }' > "$t/both.c"
    for mods in libevdev mtdev "libevdev mtdev"; do
        cflags=$(pkgconf --cflags $mods) || fail "pkgconf --cflags $mods"
        case "$mods" in
            "libevdev mtdev") src="$t/both.c" ;;
            *)                src="$t/$mods.c" ;;
        esac
        "$CROSS_BINDIR/clang" --target="$CROSS_TRIPLE" --sysroot="$SYSROOT" -fsyntax-only \
            $cflags "$src" \
            || fail "the installed headers of '$mods' do not compile with pkgconf --cflags $mods ($cflags)"
        note "compiles with pkgconf --cflags $mods: $(echo $cflags | sed "s#$SYSROOT##g")"
    done
}

# libinput — the input library behind xf86-input-libinput and the
# WindowServer. meson.
#
# Options: mtdev on; libwacom off (no libwacom in base, E23 D10); Lua plugins
# off, and so no plugin autoloading; no debug-gui (GTK and Wayland, E25 D2),
# tests or docs; no zsh completion.
#
# epoll comes from epoll-shim (built above). libinput's meson looks for it
# under -Depoll-dir (default: its own prefix, i.e. the build host's /usr), so
# that points into the sysroot.
#
# Installed: libinput.so.10 and libinput.h; the libinput tool in /usr/bin and
# its helpers in /usr/libexec/libinput (the Python ones need a python3 at run
# time, as upstream); the quirks database in /usr/share/libinput. The local
# override file is /etc/libinput/local-overrides.quirks (nextbsd-overlays#26),
# not shipped here. The udev rules and callouts in /usr/lib/udev are removed,
# as FreeBSD's port does: NextBSD has no udevd to run them.
build_libinput() {
    comp "libinput [meson cross]"
    fresh_dirs libinput
    fetch libinput
    meson_build -Dlibwacom=false -Dmtdev=true -Dlua-plugins=disabled \
        -Dautoload-plugins=false -Ddebug-gui=false -Dtests=false \
        -Dinstall-tests=false -Ddocumentation=false -Dzshcompletiondir=no \
        -Depoll-dir="$SYSROOT$PREFIX"
    rm -rf "$COMP_ROOT$PREFIX/lib/udev"
    stage libinput
    local x="$DESTDIR$PREFIX" q n t
    test -f "$x/include/libinput.h" || fail "libinput.h not staged"
    so_check libinput.so.10
    lib_needs libinput.so.10 libudev.so.0 libevdev.so.2 libmtdev.so.1 libepoll-shim.so.0
    not_needed "$x/lib/libinput.so.10" 'libwayland' 'libwacom' 'liblua' 'libgtk' 'libglib' 'libX11' 'libxcb'
    test -x "$x/bin/libinput" || fail "the libinput tool is not staged"
    for t in libinput-list-devices libinput-debug-events libinput-quirks libinput-record; do
        test -x "$x/libexec/libinput/$t" || fail "libexec/libinput/$t not staged"
    done
    # Every quirks file in the tarball is installed, and libinput was built
    # to read them from there.
    n=0
    for q in "$SRC_DIR"/quirks/*.quirks; do
        test -f "$x/share/libinput/$(basename "$q")" || fail "quirks $(basename "$q") not staged"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || fail "no quirks files in the libinput tarball"
    note "$n quirks files in $PREFIX/share/libinput"
    names_path "$x/lib/libinput.so.10" "$PREFIX/share/libinput" "$SYSCONFDIR/libinput/local-overrides.quirks"
    [ ! -e "$x/lib/udev" ] || fail "$PREFIX/lib/udev staged"
    pc_check libinput "$VERSION"
}

# =============================================================================
# Whole-artifact checks
# =============================================================================
# Every ELF object in the artifact links only the NextBSD base and this repo
# (each DT_NEEDED is in the sysroot's /lib or /usr/lib), except libudev, which
# also links nextbsd-userland's /usr/lib/system (libIOKit, CoreFoundation,
# libdispatch); and none links an X library, libwayland (E25 D2) or D-Bus.
artifact_checks() {
    comp "artifact checks"
    local f n lib count=0
    while IFS= read -r f; do
        is_elf "$f" || continue
        while IFS= read -r lib; do
            case "$lib" in
                libX*|libxcb*|libwayland*|libdbus*) fail "${f#"$DESTDIR"} links $lib" ;;
            esac
            if [ -e "$SYSROOT/lib/$lib" ] || [ -e "$SYSROOT/usr/lib/$lib" ]; then
                continue
            fi
            [ -e "$SYSROOT/usr/lib/system/$lib" ] \
                || fail "${f#"$DESTDIR"} links $lib, which neither the NextBSD base, nextbsd-userland nor this repo has"
            case "${f#"$DESTDIR"}" in
                "$PREFIX"/lib/libudev.so.*) ;;
                *) fail "${f#"$DESTDIR"} links nextbsd-userland's $lib (only libudev may)" ;;
            esac
        done < <("$READELF" -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
        count=$((count + 1))
    done < <(find "$DESTDIR" -type f)
    note "$count ELF objects link only the base and this repo (libudev also /usr/lib/system); no X, Wayland or D-Bus"
    [ ! -e "$DESTDIR$SYSCONFDIR" ] || fail "$SYSCONFDIR is in the artifact"
    [ ! -e "$DESTDIR$X_PREFIX" ] || fail "$X_PREFIX is in the artifact"
    [ ! -e "$DESTDIR$PREFIX/include/linux" ] || fail "$PREFIX/include/linux is in the artifact"
    note "nothing in $SYSCONFDIR, $X_PREFIX or $PREFIX/include/linux"
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and add <name> here, one per line, in
# build order.
COMPONENTS="
    libdrm
    pixman
    expat
    freetype
    fontconfig
    libxkbcommon
    xkeyboard-config
    epoll-shim
    libudev
    linux-input-shim
    libevdev
    mtdev
    libinput
"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $(echo $COMPONENTS) " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $(echo $COMPONENTS))" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-displayserver-support: building [$(echo $COMPONENTS)] for $T/$TA into $DESTDIR$PREFIX"
mkdir -p "$DESTDIR"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done
artifact_checks

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
