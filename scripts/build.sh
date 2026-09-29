#!/usr/bin/env bash
# Build, install, and package the musl LLVM toolchain for one architecture.
#
# Runs inside the build container started by `make build`, which is also what CI
# runs. The container mounts fix the paths below. Phases:
#
#   configure    patch the pinned source; configure only if the inputs changed
#   compiler     build clang + lld with Alpine's toolchain, once
#   regressions  run the optimizer regressions with the new opt
#   distribution build and install the package; compiler-rt builtins, libc++,
#                libc++abi, and libunwind are built by the new clang
#   package      add driver config files, write the tarball
set -euo pipefail

: "${LLVM_VERSION:?}" "${LLVM_ARCH:?x86_64 or aarch64}"
LLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS:-2}"
LLVM_USE_CCACHE="${LLVM_USE_CCACHE:-0}"

REPO=/work/repo
SRC=/work/src
STATE=/work/state
BUILD="${STATE}/build"
NAME="clang+llvm-${LLVM_VERSION}-${LLVM_ARCH}-linux-musl"
PREFIX="${STATE}/install/${NAME}"
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

CMAKE_ARGS=(
    -C "${REPO}/cmake/llvm-musl-distribution.cmake"
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DCMAKE_INSTALL_PREFIX="${PREFIX}"
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

# -- distribution -----------------------------------------------------------------
phase "distribution: tools, runtimes, install"
[ "${PREFIX#"${STATE}"/install/}" != "$PREFIX" ] || die "unexpected install prefix ${PREFIX}"
rm -rf "$PREFIX"
cmake --build "$BUILD" --target install-distribution

# -- package ----------------------------------------------------------------------
phase "package"
# Clang reads <bin>/<name>.cfg. Default to the bundled lld, and search the flat
# lib/ directory that holds libc++.a, libc++abi.a, and libunwind.a: on its own
# the driver only searches per-target subdirectories. <CFGDIR> keeps the package
# relocatable, and the bracketed -L is not reported as unused when only compiling.
for cfg in clang clang++; do
    cat > "${PREFIX}/bin/${cfg}.cfg" <<'EOF'
-fuse-ld=lld
--start-no-unused-arguments
-L<CFGDIR>/../lib
--end-no-unused-arguments
EOF
done

runtime_dir="lib/clang/${LLVM_VERSION%%.*}/lib/linux"
for required in bin/clang bin/clang++ bin/ld.lld bin/llvm-ar lib/libclang.so lib/libLTO.so \
                include/clang-c/Index.h include/c++/v1/__config_site include/c++/v1/iostream \
                lib/libc++.a lib/libc++abi.a lib/libunwind.a \
                "${runtime_dir}/libclang_rt.builtins-${LLVM_ARCH}.a" \
                "${runtime_dir}/clang_rt.crtbegin-${LLVM_ARCH}.o" "${runtime_dir}/clang_rt.crtend-${LLVM_ARCH}.o"; do
    [ -e "${PREFIX}/${required}" ] || die "install is missing ${required}"
done
"${PREFIX}/bin/clang" --version

tarball="${DIST}/${NAME}.tar.xz"
tar -C "${STATE}/install" --sort=name --owner=0 --group=0 --numeric-owner -cf - "$NAME" |
    xz -T0 -6 > "${tarball}.tmp"
mv "${tarball}.tmp" "$tarball"
(cd "$PREFIX" && find . -mindepth 1 | LC_ALL=C sort) > "${DIST}/${NAME}.manifest"
ls -l "$tarball"
phase "done"
