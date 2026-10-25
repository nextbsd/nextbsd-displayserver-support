# Upstream sources & licences

`nextbsd-displayserver-support` builds third-party libraries and data NextBSD
ships in base under `/usr`, each **under its own upstream licence**. Their
sources are not kept in this repo: `build-displayserver-support.sh` downloads
the release tarballs pinned in `sources.lock` and checks their SHA-256. The
licence files and headers in those tarballs are authoritative; this table
records provenance and does not relicense anything. The rows moved here from
nextbsd-xlibs' and nextbsd-xlibre's `NOTICE.md` with the components (E25).

NextBSD's changes to upstream code live in `patches/<component>/`. Each patch is
under the licence of the file it changes, and says where it came from in its
`Origin:` line.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-displayserver-support.sh`, `sources.lock`, `cross/`,
`.github/workflows/`, the `linux-input-shim` headers and `.pc` file the script
writes, this `NOTICE.md` and `README.md`.

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `libdrm` | freedesktop.org, `mesa/libdrm` | 2.4.134 | MIT/X11-style, in each source file's header (the tarball has no `COPYING`) |
| `pixman` | freedesktop.org, `pixman/pixman` | 0.46.4 | MIT (`COPYING`) |
| `expat` | libexpat, `libexpat/libexpat` | 2.9.0 | MIT (`COPYING`) |
| `freetype` | FreeType, `freetype/freetype` | 2.15.0 | FreeType License (FTL), taken from the FTL/GPLv2 dual licence (`LICENSE.TXT`, `docs/FTL.TXT`) |
| `fontconfig` | freedesktop.org, `fontconfig/fontconfig` | 2.18.3 | HPND/MIT-style (`COPYING`) |
| `xkeyboard-config` | freedesktop.org, `xkeyboard-config/xkeyboard-config` | 2.48 | MIT/X11-style, per file (`COPYING`) |
| `libxkbcommon` | xkbcommon, `xkbcommon/libxkbcommon` | 1.13.2 | MIT/X11-style, per file (`LICENSE`). Core only; `libxkbcommon-x11` is built by nextbsd-xlibs |
| `epoll-shim` | Jan Kokemüller, `jiixyj/epoll-shim` | 0.0.20240608 | MIT (`LICENSE`) |
| `libudev` | NextBSD, on libudev-devd by Vladimir Kondratyev (`wulf7/libudev-devd`) | 0.7.0 + `patches/libudev` | BSD-2-Clause (in each file; no `COPYING`). NextBSD's new files (`udev-iokit.c`, `udev-iokit.h`) and changes in the patches are BSD-2-Clause too. The optional GPL code (`utils-gpl.c`) is not built. Links nextbsd-userland's libIOKit, CoreFoundation and libdispatch dynamically (their licences are recorded in nextbsd-userland) |
| `linux-input-shim` | NextBSD (written by `build-displayserver-support.sh`) | n/a | BSD-2-Clause (this repo's `LICENSE`); each header only includes the base's BSD-2-Clause `<dev/evdev/…>` header |
| `libevdev` | freedesktop.org, `libevdev/libevdev` | 1.14.0 | MIT (`COPYING`). The Linux UAPI headers it carries in `include/linux/linux` (GPL-2.0 WITH Linux-syscall-note) are build input only and not installed |
| `mtdev` | Henrik Rydberg, bitmath.org | 1.1.7 | MIT (`COPYING`) |
| `libinput` | freedesktop.org, `libinput/libinput` | 1.32.0 | MIT (`COPYING`); the quirks data is under the same licence. The Linux UAPI headers it carries in `include/linux/linux` are build input only and not installed |
| `gperf` | GNU, `gperf` | 3.3 | GPL-3.0-or-later (build host only; nothing links it, and its output, fontconfig's hash table, is not covered by the GPL) |
