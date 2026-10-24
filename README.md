# nextbsd-displayserver-support

The libraries and data that both of NextBSD's display servers share, built from
pinned upstream release tarballs into **`/usr`**: libdrm, pixman, expat,
freetype, fontconfig, xkeyboard-config, libxkbcommon, and the input stack
(epoll-shim, NextBSD's IOKit libudev, the `<linux/input.h>` shim, libevdev,
mtdev, libinput). The GNUstep WindowServer (built by Gershwin) and XLibre (kept as the
compatibility server for X apps) both build on them. None of them links an X
library, and nothing here uses Wayland.

E25 ([plan](https://github.com/nextbsd/nextbsd-userland/wiki/E25-Display-Server-Support-Plan),
epic nextbsd/nextbsd#583) moved these components here from nextbsd-xlibs and
nextbsd-xlibre, at the same versions and with the same patches and options;
only the install paths changed (`/usr/X11` → `/usr`, decision D4). The repos
are built by hand in this order:

```
nextbsd-freebsd-compat          the NextBSD base
        │
nextbsd-userland                libIOKit, CoreFoundation, libdispatch (for libudev)
        │
nextbsd-displayserver-support   libdrm, fonts, xkb, input stack     <- this repo
        │
nextbsd-xlibs                   the X client libraries, libxkbcommon-x11
        │
nextbsd-mesa                    Mesa + libglvnd
        │
nextbsd-xlibre                  the XLibre server, drivers, xkbcomp, tools
```

nextbsd-gnustep-support and nextbsd-gershwin-support stage this repo before
nextbsd-xlibs. The repo follows
[Source repo conventions](https://github.com/nextbsd/nextbsd-userland/wiki/Source-Repo-Conventions).

## Rules

1. **Pinned upstream sources only.** Every component is a release tarball (or
   tag archive) listed in `sources.lock` with its version, URL and SHA-256.
   Not FreeBSD packages, not the ports tree or ports tools, not NetBSD's `xsrc`
   or OpenBSD's `xenocara`. Those, and FreeBSD's port patches, may be read as
   references.
2. **Upstream build systems as they are** (meson, autotools, CMake), driven
   with NextBSD's options and cross files. Never rewritten as hand-made
   makefiles.
3. **NextBSD's changes are patch files** in `patches/<component>/`, never
   edits to an unpacked tree, each with its provenance (`Origin:`).
4. **Everything installs under `/usr`** (E25 D4) with **upstream sonames**, the
   same ones nextbsd-xlibs and nextbsd-xlibre shipped. See [Paths](#paths).
   Nothing goes in `/usr/local` or `/usr/X11`, and the artifact ships nothing
   in `/etc`: configuration belongs to nextbsd-overlays. The one file outside
   `/usr` is fontconfig's launchd job, in `/System/Library/LaunchDaemons`.
5. **Only the NextBSD base is linked against**: compat's `continuous` base,
   plus nextbsd-userland's `continuous` artifact for libudev alone (libIOKit,
   CoreFoundation and libdispatch in `/usr/lib/system`; see
   [libudev](#libudev)). Never the X repos. Build tools come from the
   toolchain image (or, for gperf, are built on the runner) and never ship.
6. **pkgconf, never freedesktop's GPL pkg-config.** No Wayland (E25 D2), no
   D-Bus, no Avahi.

## Layout

```
build-displayserver-support.sh  cross-build driver: every component, or some by name
sources.lock                    name, version, SHA-256, URL of every upstream tarball
patches/<name>/series           the patches for <name>, in the order applied
patches/<name>/*.patch          one change each, with an Origin: header
cross/meson/<arch>.ini          meson cross files (host_machine system = 'freebsd')
cross/autotools/<arch>.site     autotools CONFIG_SITE files (cross compiler, pkgconf,
cross/autotools/common.site       cache answers for checks that would run a program)
cross/cmake/<arch>.cmake        CMake toolchain files (epoll-shim)
launchd/org.nextbsd.fc-cache.plist  the font-cache launchd job (see [fontconfig](#fontconfig))
.github/workflows/build.yml     CI: build both arches, publish `continuous`
NOTICE.md                       per-component provenance and licence
```

Nothing upstream is committed. `build-displayserver-support.sh` downloads into
`.build/dl/`, unpacks into `.build/src/` and builds out of tree under `.build/`.

## Build model

`build-displayserver-support.sh` runs inside the `nextbsd-kernel-toolchain`
container (the pinned clang/lld 19.1.7, meson, ninja, cmake, pkgconf,
autotools, python3, perl and bison) with compat's `continuous` base and then
nextbsd-userland's `continuous` artifact extracted as the sysroot. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | compat's base with nextbsd-userland's artifact on top; scratch, since each component is installed into its `/usr` |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

For each component, in `COMPONENTS` order, it:

1. downloads the tarball named in `sources.lock`, refuses it unless the SHA-256
   matches, and unpacks it;
2. applies `patches/<name>/series`;
3. runs the upstream build out of tree and installs it with `DESTDIR`, with
   `--prefix=/usr`, libraries in `/usr/lib`, `--sysconfdir=/etc` and
   `--localstatedir=/var`:
   - **meson** with two cross files: one generated per run with the sysroot and
     LLVM paths, then `cross/meson/<arch>.ini` (`system = 'freebsd'`, so
     upstream's FreeBSD code paths apply). Shared libraries, no wrap downloads;
   - **autotools** in `--host=<triple>` mode with
     `CONFIG_SITE=cross/autotools/<arch>.site`, `--with-sysroot`, shared only;
   - **CMake** with `cross/cmake/<arch>.cmake`;
4. checks and tidies the install, then copies it into the sysroot, so later
   components find it, and into `DESTDIR` (except `/etc`, below):
   - every file is in one of the allowed places (`ALLOWED` in the script:
     `/usr/{bin,lib,include,libdata/pkgconfig}`, `/usr/libexec/libinput`, the
     data directories in [Paths](#paths), and `/etc/fonts`);
   - nothing replaces a file of the NextBSD base (the sysroot is listed before
     the first component is installed);
   - no `.la` files or docs; `.pc` files moved to `/usr/libdata/pkgconfig`;
   - every `.pc` says `prefix=/usr` (or, data-only, sets no path outside
     `/usr`) and names no `/usr/local`, `/usr/X11` or build path; CMake
     package files name no build path;
   - no ELF object has an RPATH/RUNPATH naming the build host, `/usr/local` or
     `/usr/X11`, or the build sysroot compiled in;
5. checks each library's upstream soname and the libraries it links
   (`llvm-readelf -d`), the paths compiled into it, and that its `.pc` resolves
   through pkgconf.

At the end every ELF object in the artifact is checked once more: each
`DT_NEEDED` is a library of the NextBSD base or of this repo (for libudev
alone, also of nextbsd-userland's `/usr/lib/system`), and none is an X
library, libwayland or D-Bus. In particular **libinput and libxkbcommon don't
link libwayland** (E25 D2).

pkgconf only searches the sysroot's `/usr/libdata/pkgconfig` with
`PKG_CONFIG_SYSROOT_DIR` set, so nothing from the Linux host leaks into a
build.

```
./build-displayserver-support.sh               # every component
./build-displayserver-support.sh libinput      # one component; its dependencies
                                               # must already be in $SYSROOT
```

## Paths

| What | Where |
|---|---|
| Libraries | `/usr/lib` |
| Headers | `/usr/include` (`freetype2/`, `fontconfig/`, `libdrm/`, `pixman-1/`, `xkbcommon/`, `libepoll-shim/`, `libevdev-1.0/`, `libinput.h`, `libudev.h`, `expat.h`, `mtdev.h`, ...) |
| `.pc` files | `/usr/libdata/pkgconfig` |
| Tools | `/usr/bin` (`fc-*`, the libevdev tools, `mtdev-test`, `libinput`), `/usr/libexec/libinput` |
| libdrm data | `/usr/share/libdrm/amdgpu.ids` (amd64) |
| fontconfig | config `/etc/fonts` (not in the artifact, see [fontconfig](#fontconfig)), templates `/usr/share/fontconfig/conf.avail`, DTD `/usr/share/xml/fontconfig`, cache `/var/cache/fontconfig` |
| xkb data | `/usr/share/xkeyboard-config-2`, with `/usr/share/X11/xkb` → `../xkeyboard-config-2` |
| libxkbcommon | xkb root (and legacy root) `/usr/share/X11/xkb`, extra path `/etc/xkb`, X locale (Compose) root `/usr/X11/share/X11/locale` (libX11's, from nextbsd-xlibs) |
| libinput | quirks `/usr/share/libinput`, local overrides `/etc/libinput/local-overrides.quirks`; no udev rules |
| launchd job | `/System/Library/LaunchDaemons/org.nextbsd.fc-cache.plist` (see [fontconfig](#fontconfig)) |
| `<linux/input.h>` shim | `/usr/include/linux-input-shim/linux/`, through `linux-input-shim.pc` (see [linux-input-shim](#linux-input-shim)) |

The `/etc` files (`/etc/fonts`; `/etc/xkb` and `/etc/libinput` are optional
and not shipped) belong to nextbsd-overlays (nextbsd-overlays#26), which owns
`/etc`; this repo only compiles the paths in. The `org.nextbsd.fc-cache`
launchd job ships here, next to fc-cache.

## Components

In build order (E25 audit 1, section 4.2, except that libxkbcommon builds
before xkeyboard-config, as it did in nextbsd-xlibs: if meson finds
`xkeyboard-config.pc`, libxkbcommon takes its legacy xkb root from pkgconf with
the build sysroot prefixed, and that root has no option to override it).

| Component | Version | Build | Installs | Was in |
|---|---|---|---|---|
| `libdrm` | 2.4.134 | meson | `libdrm.so.2`, `xf86drm.h`, `libdrm/` uapi headers; amd64 `libdrm_amdgpu.so.1`, `libdrm_radeon.so.1` (E25 D6) and `amdgpu.ids`; arm64 `libdrm_vc4` headers and `.pc`. Intel and nouveau off. Patched: ETIME, platform-bus devices, render-node owner (`patches/libdrm/`) | nextbsd-xlibs |
| `pixman` | 0.46.4 | meson | `libpixman-1.so.0` | nextbsd-xlibs |
| `expat` | 2.9.0 | autotools | public `libexpat.so.1`, `expat.h`. The base's private `libbsdxml` is untouched; the base has no `libexpat` or `expat.h` | nextbsd-xlibs |
| `freetype` | 2.15.0 | meson | `libfreetype.so.6` (base zlib and bzip2; no libpng, harfbuzz or brotli) | nextbsd-xlibs |
| `fontconfig` | 2.18.3 | meson (+ host gperf) | `libfontconfig.so.1`, the ten `fc-*` tools | nextbsd-xlibs |
| `libxkbcommon` | 1.13.2 | meson | `libxkbcommon.so.0`, core only (`-Denable-x11=false`; `libxkbcommon-x11` stays in nextbsd-xlibs, E25 D5) | nextbsd-xlibs |
| `xkeyboard-config` | 2.48 | meson | the XKB keymap data | nextbsd-xlibre |
| `epoll-shim` | 0.0.20240608 | CMake | `libepoll-shim.so.0`, `libepoll-shim-interpose.so.0`, headers in `libepoll-shim/` | nextbsd-xlibre |
| `libudev` | NextBSD (on libudev-devd 0.7.0) | meson | `libudev.so.0`, `libudev.h`, `libudev.pc`: the IOKit libudev (E25 D7, see [libudev](#libudev)). Patched: input devices from the IORegistry, monitor on IOKit notifications (`patches/libudev/`) | nextbsd-xlibre (libudev-devd) |
| `linux-input-shim` | NextBSD | headers | `<linux/input.h>`, `<linux/input-event-codes.h>`, `<linux/uinput.h>`, `linux-input-shim.pc` | nextbsd-xlibre |
| `libevdev` | 1.14.0 | meson | `libevdev.so.2`, three tools. Patched: `.pc` requires `linux-input-shim` | nextbsd-xlibre |
| `mtdev` | 1.1.7 | autotools | `libmtdev.so.1`, `mtdev-test`. Patched: `.pc` requires `linux-input-shim` | nextbsd-xlibre |
| `libinput` | 1.32.0 | meson | `libinput.so.10`, the `libinput` tool and helpers, quirks (no libwacom, Lua plugins, debug GUI or udev rules) | nextbsd-xlibre |

### fontconfig

Built with `-Dbaseconfig-dir=/etc/fonts`, `-Dtemplate-dir=/usr/share/fontconfig/conf.avail`,
`-Dcache-dir=/var/cache/fontconfig` and NextBSD's font domains:

1. `/System/Library/Fonts`
2. `/Local/Library/Fonts`
3. `/Network/Library/Fonts`
4. `~/Library/Fonts`
5. then `/usr/X11/share/fonts` (XLibre's fonts)

**`/etc/fonts` is not in the artifact.** The build generates `fonts.conf` and
the `conf.d` links and stages them into the sysroot, so the build and its
checks see exactly what fontconfig was compiled for, but it leaves `/etc` out
of the published tarball: `/etc` belongs to nextbsd-overlays, which ships
`/etc/fonts` (nextbsd-overlays#26), and a package-owned `/etc` file would break
that ownership (nextbsd-pkg#25). The CI log prints the generated file list and
the whole of `fonts.conf`, so nextbsd-overlays can copy it from there. The
templates the `conf.d` links point to (`/usr/share/fontconfig/conf.avail`) are
in the artifact.

fc-cache cannot run on the build host (`cache-build` is off). The
`org.nextbsd.fc-cache` launchd job (`launchd/org.nextbsd.fc-cache.plist`,
installed in `/System/Library/LaunchDaemons`) builds the cache on the system
instead of a post-install script. It ships here rather than in
nextbsd-overlays, as cupsd's job ships with nextbsd-printing-support: it
belongs with the program it runs, so it is there exactly when fc-cache is and
`pkg upgrade` updates it.

- **When:** at boot (`RunAtLoad`). `fc-cache -s` scans the system font
  directories only, skips the missing ones and rewrites only out-of-date
  caches, so a boot without font changes costs a stat per directory. It runs
  as root, at `Nice` 10, with no `KeepAlive`.
- **On font changes:** `WatchPaths` names `/System/Library/Fonts`,
  `/Local/Library/Fonts` and `/Network/Library/Fonts`. launchctl turns
  WatchPaths into a `com.apple.fsevents.matching` launch event that nothing on
  NextBSD delivers yet (nextbsd/nextbsd-userland#243), so for now the cache is
  refreshed at the next boot or by running `fc-cache -s` by hand.
- **Where:** `/var/cache/fontconfig`, which fc-cache creates (0755, root) on
  its first run. Per-user fonts (`~/Library/Fonts`) are cached in
  `~/.cache/fontconfig` by fontconfig itself.
- **Silent:** output goes to `/var/log/fc-cache.log`, never the console.

The build checks that the job is well-formed, carries the
`org.nextbsd.fc-cache` label, runs the staged `/usr/bin/fc-cache` and logs to
`/var/log`.

### libudev

NextBSD's libudev is libudev-devd 0.7.0 with its input device source and its
monitor replaced (`patches/libudev/`, `Origin: NextBSD`), so libinput, and
through it XLibre and the WindowServer, see input devices that appear after
they start, without devd (nextbsd/nextbsd#482). The rest of libudev-devd (the
device, list, filter and enumerate objects, `/dev/dri/card*` and the other
devfs nodes) is unchanged, and so are the soname `libudev.so.0`,
`/usr/include/libudev.h` and `libudev.pc` (which claims udev 243's API level,
as before).

- **Enumeration.** The kernel publishes every `/dev/input/eventN` as an
  `IOHIDDevice` registry entry (nextbsd-kernel#331).
  `udev_enumerate_scan_devices` lists them with
  `IOServiceGetMatchingServices(IOServiceMatching("IOHIDDevice"))`; if the
  registry cannot be reached, or has no such entries, devfs is scanned as
  before.
- **Properties.** An input device is built from its entry's keys:

  | udev | IORegistry key |
  |---|---|
  | syspath, devnode, `DEVNAME` | `org.nextbsd.DevNode` (`/dev/input/eventN`); sysname `eventN`, subsystem `input` |
  | `MAJOR`, `MINOR`, devnum | `BSD Major`, `BSD Minor` |
  | `ID_INPUT=1` and the type tags | `PrimaryUsagePage`/`PrimaryUsage`: Keyboard → `ID_INPUT_KEY` + `ID_INPUT_KEYBOARD`; Keypad, System Control, Consumer Control → `ID_INPUT_KEY`; Mouse, Pointer → `ID_INPUT_MOUSE`; Joystick, Game Pad → `ID_INPUT_JOYSTICK`; Touch Pad → `ID_INPUT_MOUSE` + `ID_INPUT_TOUCHPAD`; Touch Screen → `ID_INPUT_TOUCHSCREEN`; Digitizer, Pen → `ID_INPUT_TABLET`; Accelerometer → `ID_INPUT_ACCELEROMETER` |
  | `ID_VENDOR_ID`, `ID_MODEL_ID` | `VendorID`, `ProductID` (`%04x`) |
  | `ID_INTEGRATION` | `Transport`: I2C, SPI, PS2 → `internal`; USB, Bluetooth → `external` |
  | parent sysname | `org.nextbsd.evdev.Phys` (the driver, e.g. `hms0`), `uinput` if empty |
  | parent `NAME`, sysattr `name` | `Product`, cut at the first comma |
  | parent `PRODUCT` | `org.nextbsd.evdev.BusType`/`VendorID`/`ProductID`/`VersionNumber` (`%x/%x/%x/%x`) |
  | parent `UNIQ` | `SerialNumber` |

  That is the device-plus-synthetic-parent shape libudev-devd built from the
  `kern.evdev.input` sysctls, which libinput's quirks and XLibre's
  `config/udev.c` read. A node with no entry, or whose usage has no udev type
  (a switch-only node), is still classified from those sysctls.
- **Monitor.** `udev_monitor_enable_receiving` registers
  `IOServiceAddMatchingNotification` for first-match and terminated
  `IOHIDDevice` entries, delivered on a private serial dispatch queue. Each
  event is queued and one byte written to a pipe; `udev_monitor_get_fd` is the
  pipe's read end, so it polls with poll, kqueue or epoll-shim like any fd.
  `udev_monitor_receive_device` builds the device and applies the filters on
  the caller's thread. A removal carries the syspath its add had (a registry
  id → syspath cache; a terminated entry also stays readable while it
  lingers). Entries present when the monitor starts are remembered, not
  reported (the caller enumerates them). The watch only starts for a monitor
  that can take `input` devices. No devd socket is opened.
- **DRM.** `/dev/dri/card*` is enumerated from devfs as before. There are no
  DRM hotplug events until the kernel sends connector changes as IOKit
  interest notifications (nextbsd-kernel#338).

libudev links libIOKit, CoreFoundation and libdispatch, which
nextbsd-userland installs in `/usr/lib/system`; the dynamic linker finds them
through ldconfig's `/usr/lib/system` entry, so there is no RPATH. At build
time `-L<sysroot>/usr/lib/system` goes only in meson's `c_link_args`, so
neither the library nor `libudev.pc` names a build path. The build checks the
soname, that it links those libraries, that the IOKit code is compiled in and
the devd socket path is not, and that a program calling every libudev
function libinput 1.32, XLibre's `config/udev.c` and its modesetting driver use
builds and links with nothing but `pkgconf --cflags --libs libudev`.

### linux-input-shim

libevdev's and mtdev's installed headers include `<linux/input.h>`, and
XLibre's evdev, libinput, synaptics and joystick drivers include it directly.
NextBSD's kernel evdev(4) has the same ABI, in the base's `<dev/evdev/input.h>`,
`<dev/evdev/input-event-codes.h>` and `<dev/evdev/uinput.h>`. The shim is three
one-line headers that include those.

It is **not** in `/usr/include/linux`: many configure and meson checks take
`<linux/*.h>` to mean "this is Linux" (E25 audit 3, 4.4). Instead:

- the headers are in `/usr/include/linux-input-shim/linux/`;
- `linux-input-shim.pc` adds that directory
  (`Cflags: -I${includedir}/linux-input-shim`);
- `libevdev.pc` and `mtdev.pc` say `Requires: linux-input-shim`
  (`patches/libevdev`, `patches/mtdev`), so `pkgconf --cflags libevdev` or
  `pkgconf --cflags mtdev` is all a consumer needs. The build checks this by
  compiling the installed headers with nothing but those flags.

A program that includes `<linux/input.h>` itself asks for `linux-input-shim`.

## Host build tools

**gperf** (fontconfig's object hash) is not in the toolchain image yet. If the
image has a `gperf`, that one is used; otherwise the pinned GNU gperf 3.3 is
built on the runner with the host compiler and used only during the build
(`host_gperf`). It never ships. It belongs in the toolchain image eventually.

## CI, artifact, package

`.github/workflows/build.yml` builds amd64 and arm64 on pull requests, pushes
to `main` and manual runs, each inside its arch's toolchain image with
compat's `continuous` base and nextbsd-userland's `continuous` artifact as the
sysroot. Pushes to `main` and manual runs
from `main` publish `nextbsd-displayserver-support-<arch>.tar.gz` (the whole
`/usr` install, headers and `.pc` files included, rooted at `/`) to the
`continuous` release. Pull requests only build. Nothing is dispatched to or
from other repos (rebuild-chain policy): nextbsd-xlibs, nextbsd-mesa,
nextbsd-xlibre, nextbsd-gnustep-support, nextbsd-gershwin-support and
nextbsd-pkg are run by hand.

nextbsd-pkg packages the artifact as `NextBSD-displayserver-support`
(nextbsd-pkg#25), which the X, Mesa, gnustep-support and gershwin-support
packages depend on.

## Adding a component

Pin it in `sources.lock`, write `build_<name>()` in
`build-displayserver-support.sh` (hyphens become underscores), put its patches
in `patches/<name>/` with a `series` file, add `<name>` to `COMPONENTS` in
build order, and add a row to `NOTICE.md` after checking the licence in the
tarball. Only what both display servers need belongs here: X-only pieces go in
nextbsd-xlibs or nextbsd-xlibre.
