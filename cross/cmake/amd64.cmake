# cross/cmake/amd64.cmake — CMake cross toolchain for nextbsd-displayserver-support, T=amd64.
#
# Same shape as nextbsd-userland's cmake/cross-amd64.cmake, beside the meson and
# autotools files in cross/ (Source-Repo-Conventions): cmake and ninja run
# on the x86_64 Linux runner and drive the pinned clang/lld 19.1.7 from
# $CROSS_BINDIR, emitting NextBSD/amd64 objects against $SYSROOT.
#
# Required environment (exported by build-displayserver-support.sh):
#   CROSS_BINDIR  the toolchain image's clang, clang++, ld.lld, llvm-ar ...
#   SYSROOT       the staged NextBSD base, with every earlier component of
#                 this repo installed into its /usr
#
# CMAKE_SYSTEM_NAME is FreeBSD: NextBSD's base is FreeBSD's libc and ABI, so
# the upstream FreeBSD code paths are the right ones.

set(CMAKE_SYSTEM_NAME      FreeBSD)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(_triple  "x86_64-unknown-freebsd")
set(_sysroot "$ENV{SYSROOT}")
set(_bindir  "$ENV{CROSS_BINDIR}")

set(CMAKE_C_COMPILER   "${_bindir}/clang")
set(CMAKE_CXX_COMPILER "${_bindir}/clang++")
set(CMAKE_C_COMPILER_TARGET   "${_triple}")
set(CMAKE_CXX_COMPILER_TARGET "${_triple}")
set(CMAKE_AR      "${_bindir}/llvm-ar"     CACHE FILEPATH "")
set(CMAKE_RANLIB  "${_bindir}/llvm-ranlib" CACHE FILEPATH "")
set(CMAKE_NM      "${_bindir}/llvm-nm"     CACHE FILEPATH "")
set(CMAKE_STRIP   "${_bindir}/llvm-strip"  CACHE FILEPATH "")
set(CMAKE_OBJCOPY "${_bindir}/llvm-objcopy" CACHE FILEPATH "")

# lld for every link (clang finds ld.lld beside itself): the runner's
# /usr/bin/ld is x86-only.
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")

set(CMAKE_SYSROOT        "${_sysroot}")
set(CMAKE_FIND_ROOT_PATH "${_sysroot}")

# Programs from the host; libraries, headers and packages only from the sysroot.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
