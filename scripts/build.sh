#!/usr/bin/env bash
# Build, install, and package the musl LLVM toolchain for one architecture.
#
# Runs inside the build container started by `make build`, which is also what CI
# runs. The container mounts fix the paths below. Phases:
#
#   configure    patch the pinned source; configure only if the inputs changed
#   compiler     build clang + lld with Alpine's toolchain, once
#   regressions  run the optimizer regressions with the new opt
#   stage 1      install the stage-1 tools and runtimes (built by the new clang)
#                and build musl with them
#   stage 2      rebuild the shipped tools and the LLVM development libraries
#                with stage 1's clang against libc++, libunwind, compiler-rt,
#                and the clang-built musl, so nothing shipped carries GNU runtime
#   musl         rebuild the bundled static musl libc with the shipped clang
#   package      add driver config files and crt aliases, check purity, and
#                write the compiler and development tarballs
set -euo pipefail

: "${LLVM_VERSION:?}" "${MUSL_VERSION:?}" "${ZLIB_VERSION:?}" "${LLVM_ARCH:?x86_64 or aarch64}"
LLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS:-2}"
LLVM_USE_CCACHE="${LLVM_USE_CCACHE:-0}"

REPO=/work/repo
SRC=/work/src
MUSL_SRC=/work/musl-src
ZLIB_SRC=/work/zlib-src
STATE=/work/state
BUILD="${STATE}/build"
NAME="clang+llvm-${LLVM_VERSION}-${LLVM_ARCH}-linux-musl"
PREFIX="${STATE}/install/${NAME}"
STAGE1="${STATE}/stage1/${NAME}"
DIST="${STATE}/dist"
TARGET_TRIPLE="${LLVM_ARCH}-linux-musl"

die() { echo "ERROR: $*" >&2; exit 1; }

phase_start=$SECONDS
phase() { echo; echo "=== $* (previous phase: $((SECONDS - phase_start))s) ==="; phase_start=$SECONDS; }

case "$LLVM_ARCH" in
    x86_64|aarch64) ;;
    *) die "LLVM_ARCH must be x86_64 or aarch64, got '${LLVM_ARCH}'" ;;
esac
[ "$(uname -m)" = "$LLVM_ARCH" ] ||
    die "container architecture $(uname -m) does not match LLVM_ARCH=${LLVM_ARCH}; run on a matching --platform"

mkdir -p "$STATE/logs" "$DIST"
exec > >(tee -a "${STATE}/logs/build.log") 2>&1
on_exit() {
    local status=$?
    if [ "$LLVM_USE_CCACHE" = 1 ]; then ccache --show-stats; fi
    exit "$status"
}
trap on_exit EXIT

echo "LLVM ${LLVM_VERSION} for ${TARGET_TRIPLE}: $(date -u +%FT%TZ), $(nproc) cores"

# The source must be the pinned release, whether fetched by `make source` or
# supplied through LLVM_DIR.
version_file="${SRC}/cmake/Modules/LLVMVersion.cmake"
[ -f "$version_file" ] || die "${SRC} is not an llvm-project checkout"
src_version=$(sed -n 's/^ *set(LLVM_VERSION_\(MAJOR\|MINOR\|PATCH\) \([0-9]*\))/\2/p' "$version_file" | paste -sd. -)
[ "$src_version" = "${LLVM_VERSION}" ] ||
    die "source tree is LLVM ${src_version}, expected ${LLVM_VERSION}"
musl_version_file="${MUSL_SRC}/VERSION"
[ -f "$musl_version_file" ] || die "${MUSL_SRC} is not a musl checkout"
[ "$(cat "$musl_version_file")" = "${MUSL_VERSION}" ] ||
    die "musl source tree is $(cat "$musl_version_file"), expected ${MUSL_VERSION}"
grep -q "^#define ZLIB_VERSION \"${ZLIB_VERSION}\"" "${ZLIB_SRC}/zlib.h" 2>/dev/null ||
    die "${ZLIB_SRC} is not the zlib ${ZLIB_VERSION} source"

runtime_dir="lib/clang/${LLVM_VERSION%%.*}/lib/linux"

CMAKE_ARGS=(
    -C "${REPO}/cmake/llvm-musl-distribution.cmake"
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DCMAKE_INSTALL_PREFIX="${STAGE1}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    -DLLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS}"
)
if [ "$LLVM_USE_CCACHE" = 1 ]; then
    CMAKE_ARGS+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    ccache --zero-stats
fi

# -- configure -------------------------------------------------------------------
phase "configure"
"${REPO}/scripts/apply-patches.sh" "$SRC"

# Reconfigure from scratch whenever a configuration input changed; -C only
# seeds the cache of an empty build tree.
config_id=$({
    cat "${REPO}/cmake/llvm-musl-distribution.cmake"
    printf '%s\n' "${CMAKE_ARGS[@]}"
    clang --version
} | sha256sum | cut -d' ' -f1)
if [ "$(cat "${BUILD}/.config-id" 2>/dev/null)" != "$config_id" ]; then
    echo "Configuring a fresh build tree"
    mkdir -p "$BUILD"
    find "$BUILD" -mindepth 1 -delete
    cmake -G Ninja -S "${SRC}/llvm" -B "$BUILD" "${CMAKE_ARGS[@]}" -Wno-dev
    echo "$config_id" > "${BUILD}/.config-id"
else
    echo "Build tree is up to date with its configuration"
fi

# -- compiler ---------------------------------------------------------------------
# The runtimes are configured with the just-built clang and its ld.lld (a
# post-build symlink of the lld target). Building both first guarantees the
# runtimes see LLVM ${LLVM_VERSION}'s linker, not Alpine's.
phase "compiler: clang and lld"
cmake --build "$BUILD" --target clang lld
for tool in clang clang++ ld.lld; do
    [ -e "${BUILD}/bin/${tool}" ] || die "${BUILD}/bin/${tool} was not built"
done

# -- regressions ------------------------------------------------------------------
phase "optimizer regressions"
"${REPO}/scripts/run-optimizer-regressions.sh" "$BUILD"

# -- stage 1 --------------------------------------------------------------------
# Stage 1 installs beside the final package. Its tools still carry the host's GNU
# C++ runtime; it exists only to build stage 2, and its runtimes and musl are
# what stage 2 compiles and links against.
phase "stage 1: tools, runtimes, install"
rm -rf "$STAGE1"
cmake --build "$BUILD" --target install-distribution
[ -x "${STAGE1}/bin/clang" ] || die "stage 1 did not install into ${STAGE1}"

# -- musl -------------------------------------------------------------------------
# The bundled libc is built by clang and compiler-rt, with no GCC-built object in
# it, and out of tree so the pinned source stays pristine. Only libc.a, the
# startup objects, and musl's empty stub archives are shipped: target headers stay
# the consumer's.
build_musl() {
    local prefix=$1 build="${STATE}/musl-build"
    rm -rf "$build"
    mkdir -p "$build"
    (
        cd "$build"
        CC="${prefix}/bin/clang" \
        AR="${prefix}/bin/llvm-ar" \
        RANLIB="${prefix}/bin/llvm-ranlib" \
        LIBCC="${prefix}/${runtime_dir}/libclang_rt.builtins-${LLVM_ARCH}.a" \
            "${MUSL_SRC}/configure" --disable-shared --target="${LLVM_ARCH}"
        make -j"$(nproc)"
    )
    mkdir -p "${prefix}/lib/musl"
    install -m 644 "${build}/lib/libc.a" "${prefix}/lib/musl/libc.a"
    for obj in crt1.o rcrt1.o Scrt1.o crti.o crtn.o; do
        install -m 644 "${build}/lib/${obj}" "${prefix}/lib/musl/${obj}"
    done
    "${REPO}/scripts/install-musl-stubs.sh" "${prefix}/bin/llvm-ar" "${prefix}/lib/musl"
    # A directory holding only libc.a would win -lc for ordinary links too,
    # turning every default link into a static-libc one. The script keeps -lc
    # dynamic, and '=' makes lld resolve the loader inside --sysroot; -static and
    # -static-pie skip libc.so and take the archive.
    printf 'GROUP ( =/lib/ld-musl-%s.so.1 )\n' "${LLVM_ARCH}" > "${prefix}/lib/musl/libc.so"
    chmod 644 "${prefix}/lib/musl/libc.so"
}

# Clang reads <bin>/<name>.cfg. Select the bundled lld and compiler-rt, and search
# the flat lib/ (libc++.a, libc++abi.a, libunwind.a) and lib/musl/ (startup
# objects, libc.a). -B is a driver option: it makes the startup objects resolve
# inside the package, so no GCC-built crt1.o or crti.o from the host is linked;
# on its own the driver searches only per-target subdirectories. <CFGDIR> keeps
# the package relocatable, and the bracketed arguments are not reported as unused
# when only compiling. libc++abi's exception support references the unwinder, so
# clang++ links the bundled libunwind; clang leaves unwinding to the caller, which
# keeps C and foreign-runtime links (Rust brings its own unwinder) free of it.
write_driver_config() {
    local prefix=$1 cfg
    for cfg in clang:none clang++:libunwind; do
        cat > "${prefix}/bin/${cfg%%:*}.cfg" <<CFG
-fuse-ld=lld
--rtlib=compiler-rt
--unwindlib=${cfg#*:}
--start-no-unused-arguments
-B<CFGDIR>/../lib/musl
-L<CFGDIR>/../lib/musl
-L<CFGDIR>/../lib
--end-no-unused-arguments
CFG
    done
}

# compiler-rt's crtbegin/crtend are the real objects: they define __dso_handle and
# run C++ static destructors, which an empty stub would break. The GCC names and
# the non-arch compiler-rt names are aliases, so a driver that falls back to
# GetFilePath never needs a GCC crt file.
alias_crt_objects() {
    local rt="${1}/${runtime_dir}" name
    ln -sf "clang_rt.crtbegin-${LLVM_ARCH}.o" "${rt}/clang_rt.crtbegin.o"
    ln -sf "clang_rt.crtend-${LLVM_ARCH}.o" "${rt}/clang_rt.crtend.o"
    for name in crtbegin crtbeginS crtbeginT; do
        ln -sf "clang_rt.crtbegin-${LLVM_ARCH}.o" "${rt}/${name}.o"
    done
    for name in crtend crtendS; do
        ln -sf "clang_rt.crtend-${LLVM_ARCH}.o" "${rt}/${name}.o"
    done
}

phase "stage 1: musl libc ${MUSL_VERSION}"
build_musl "$STAGE1"
write_driver_config "$STAGE1"
alias_crt_objects "$STAGE1"

# lld and the LLVM libraries keep zlib so linkers can read compressed debug
# sections (Rust's musl objects carry them). The host's static zlib is built by
# GCC, so stage 1's clang builds the one stage 2 links, static and PIC.
phase "stage 1: zlib ${ZLIB_VERSION}"
ZLIB_PREFIX="${STATE}/zlib"
rm -rf "${STATE}/zlib-build" "$ZLIB_PREFIX"
cp -a "$ZLIB_SRC" "${STATE}/zlib-build"
(
    cd "${STATE}/zlib-build"
    CC="${STAGE1}/bin/clang" AR="${STAGE1}/bin/llvm-ar" RANLIB="${STAGE1}/bin/llvm-ranlib" \
    CFLAGS="-O2 -fPIC" ./configure --static --prefix="$ZLIB_PREFIX"
    make -j"$(nproc)" libz.a
    make install
)
[ -f "${ZLIB_PREFIX}/lib/libz.a" ] || die "zlib did not install"

# -- stage 2 ----------------------------------------------------------------------
# The shipped tools and the development libraries are rebuilt by stage 1's clang
# against libc++, libc++abi, libunwind, compiler-rt, and the clang-built musl
# startup objects, all linked statically except musl itself, so nothing shipped
# contains GNU runtime code.
phase "stage 2: configure"
BUILD2="${STATE}/build2"
CMAKE_ARGS2=(
    -C "${REPO}/cmake/llvm-musl-distribution.cmake"
    -DCMAKE_C_COMPILER="${STAGE1}/bin/clang"
    -DCMAKE_CXX_COMPILER="${STAGE1}/bin/clang++"
    -DCMAKE_INSTALL_PREFIX="${PREFIX}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    -DLLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS}"
    -DLLVM_ENABLE_LIBCXX=ON
    -DZLIB_LIBRARY="${ZLIB_PREFIX}/lib/libz.a"
    -DZLIB_LIBRARY_RELEASE="${ZLIB_PREFIX}/lib/libz.a"
    -DZLIB_LIBRARY_DEBUG="${ZLIB_PREFIX}/lib/libz.a"
    -DZLIB_INCLUDE_DIR="${ZLIB_PREFIX}/include"
    -DCMAKE_EXE_LINKER_FLAGS=
    -DCMAKE_SHARED_LINKER_FLAGS=
    -DCMAKE_MODULE_LINKER_FLAGS=
)
if [ "$LLVM_USE_CCACHE" = 1 ]; then
    CMAKE_ARGS2+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi
config2_id=$({
    cat "${REPO}/cmake/llvm-musl-distribution.cmake"
    printf '%s\n' "${CMAKE_ARGS2[@]}"
    "${STAGE1}/bin/clang" --version
    sha256sum "${STAGE1}/lib/libc++.a" "${STAGE1}/lib/musl/libc.a" "${ZLIB_PREFIX}/lib/libz.a"
} | sha256sum | cut -d' ' -f1)
if [ "$(cat "${BUILD2}/.config-id" 2>/dev/null)" != "$config2_id" ]; then
    echo "Configuring a fresh stage 2 build tree"
    mkdir -p "$BUILD2"
    find "$BUILD2" -mindepth 1 -delete
    cmake -G Ninja -S "${SRC}/llvm" -B "$BUILD2" "${CMAKE_ARGS2[@]}" -Wno-dev
    echo "$config2_id" > "${BUILD2}/.config-id"
fi

phase "stage 2: tools, runtimes, development libraries"
[ "${PREFIX#"${STATE}"/install/}" != "$PREFIX" ] || die "unexpected install prefix ${PREFIX}"
rm -rf "$PREFIX"
cmake --build "$BUILD2" --target install-distribution
(cd "$PREFIX" && find . -mindepth 1 | LC_ALL=C sort) > "${STATE}/base.files"
cmake --build "$BUILD2" --target llvm-libraries llvm-config
cmake --build "$BUILD2" --target install-llvm-libraries install-llvm-headers install-llvm-config install-cmake-exports
install -m 644 "${ZLIB_PREFIX}/lib/libz.a" "${PREFIX}/lib/libz.a"
install -m 644 "${ZLIB_PREFIX}/include/zlib.h" "${ZLIB_PREFIX}/include/zconf.h" "${PREFIX}/include/"
(cd "$PREFIX" && find . -mindepth 1 | LC_ALL=C sort) > "${STATE}/all.files"
LC_ALL=C comm -13 "${STATE}/base.files" "${STATE}/all.files" > "${STATE}/dev.files"
[ -s "${STATE}/dev.files" ] || die "stage 2 installed no development files"

phase "musl libc ${MUSL_VERSION}"
build_musl "$PREFIX"

# -- package ----------------------------------------------------------------------
phase "package"
write_driver_config "$PREFIX"
alias_crt_objects "$PREFIX"

for required in bin/clang bin/clang++ bin/ld.lld bin/llvm-ar lib/libclang.so lib/libLTO.so \
                include/clang-c/Index.h include/c++/v1/__config_site include/c++/v1/iostream \
                lib/libc++.a lib/libc++abi.a lib/libunwind.a \
                "${runtime_dir}/libclang_rt.builtins-${LLVM_ARCH}.a" \
                "${runtime_dir}/clang_rt.crtbegin-${LLVM_ARCH}.o" "${runtime_dir}/clang_rt.crtend-${LLVM_ARCH}.o" \
                lib/musl/libc.a lib/musl/crt1.o lib/musl/rcrt1.o lib/musl/Scrt1.o \
                lib/musl/crti.o lib/musl/crtn.o lib/musl/libc.so \
                bin/llvm-config include/llvm/IR/Module.h include/llvm-c/Core.h \
                lib/libLLVMCore.a lib/cmake/llvm/LLVMConfig.cmake lib/libz.a; do
    [ -e "${PREFIX}/${required}" ] || die "install is missing ${required}"
done
"${PREFIX}/bin/clang" --version
"${REPO}/scripts/check-purity.sh" "${PREFIX}" "${LLVM_ARCH}"

(cd "$PREFIX" && find . -mindepth 1 | LC_ALL=C sort) > "${STATE}/package.files"
LC_ALL=C comm -23 "${STATE}/package.files" "${STATE}/dev.files" > "${DIST}/${NAME}.manifest"
cp "${STATE}/dev.files" "${DIST}/${NAME}-dev.manifest"
pack() {
    local tarball=$1 list=$2
    (cd "${STATE}/install" && sed "s|^\./|${NAME}/|" "$list" |
        tar --sort=name --owner=0 --group=0 --numeric-owner --no-recursion -cf - -T -) |
        xz -T0 -6 > "${tarball}.tmp"
    mv "${tarball}.tmp" "$tarball"
    ls -l "$tarball"
}
pack "${DIST}/${NAME}.tar.xz" "${DIST}/${NAME}.manifest"
pack "${DIST}/${NAME}-dev.tar.xz" "${DIST}/${NAME}-dev.manifest"
phase "done"
