# Internal Build Documentation

User-facing artifact contents, usage, and Rust configuration are documented in `README.md`.

Builds a musl-linked LLVM/Clang toolchain for `x86_64-linux-musl` and `aarch64-linux-musl`.
The tools and shared libraries depend dynamically on musl only.

## Build graph

```
Alpine's packaged Clang + LLD
          |
          v
Build patched LLVM/Clang/LLD 23.1.2 tools ONCE ----> optimizer regressions (opt, FileCheck)
          |
          v
Build compiler-rt builtins and C++ runtimes with that new Clang (same build tree)
          |
          v
install-distribution -> package (tar.xz) -> validate in a clean container
```

One CMake configuration, one LLVM build tree. `scripts/build.sh` runs the phases inside a single
build container; `make build` and CI both call it.

## Commands

| Command | What |
|---------|------|
| `make build` | Fetch and verify the pinned source, build the image, run `scripts/build.sh` in it |
| `make validate` | Run `scripts/validate.sh` on the package in a separate, clean, network-less container |
| `make` | Both |
| `make source` | Only fetch, verify, and extract the source |
| `make clean` / `make distclean` | Remove this architecture's state / all generated state (never a user-supplied `LLVM_DIR`) |

The host needs Docker, GNU make, `curl`, `tar`, `xz`, and `sha256sum` (or `shasum`). `LLVM_ARCH=x86_64|aarch64` selects the package (default: host architecture; `arm64` and `amd64` are
normalized) and the matching Docker platform. Other knobs: `WORK_DIR` (all generated files, default
`work/`, git-ignored), `LLVM_DIR` (an existing checkout of the pinned release; it is patched, never
deleted), `USE_CCACHE=0`, `LLVM_PARALLEL_LINK_JOBS` (default 2: linking LLVM tools needs several GiB
each). Outputs: `work/<arch>/dist/clang+llvm-<version>-<arch>-linux-musl.tar.xz`, a `.manifest`, and
`work/<arch>/logs/build.log`.

Only the native architecture is built locally. The `aarch64` package is built and validated natively on
`ubuntu-24.04-arm` in CI; do not build it under emulation.

## Files

```
llvm-source.env                    Pinned LLVM version + source sha256 (Makefile, scripts, CI)
Makefile                           Thin entry points; derives Docker platform from LLVM_ARCH
docker/build.Dockerfile            Alpine 3.23 build image (clang, lld, cmake, ninja, ccache, zlib-static, ...)
docker/validate.Dockerfile         Clean consumer image: musl-dev only, no compiler or linker
cmake/llvm-musl-distribution.cmake Initial CMake cache: what is built, how, and the distribution components
scripts/fetch-llvm-source.sh       Download, verify (fresh or cached), extract the source archive
scripts/apply-patches.sh           Strict, repeatable application of patches/*.patch
scripts/build.sh                   configure -> compiler -> regressions -> distribution -> package
scripts/run-optimizer-regressions.sh  Runs repros/*.ll RUN lines with the new opt and FileCheck
scripts/validate.sh                Installed-package validation (runs in the clean container)
repros/                            Optimizer regression inputs and the DSE IR generator
tests/                             Programs compiled and run by validate.sh
patches/                           Local LLVM patch and its documentation
.github/workflows/llvm-prebuilt-musl.yml  CI: same make targets on native x86_64 and aarch64 runners
```

## Design notes

- **Compilers.** LLVM/Clang/LLD are built with Alpine's packaged clang and ld.lld (build inputs only).
  The runtimes are built by the clang from the same tree. Building `clang` and `lld` first
  (`scripts/build.sh`) makes the runtimes configure with LLVM 23.1.2's `ld.lld`, not Alpine's.
- **Runtimes.** `LLVM_ENABLE_RUNTIMES=compiler-rt;libcxx;libcxxabi;libunwind`. LLVM's own runtimes
  machinery handles the fact that the shipped defaults (libc++, compiler-rt, libunwind) are not
  installed yet: builtins are built first, and the runtimes configure with `--unwindlib=none` and
  `-nostdlib++` when the driver supports them. No compiler probe results are pre-seeded.
- **Bootstrap.** The previous design self-hosted Clang (build the tools, then rebuild them with the
  result). That is not needed to produce musl-linked tools, and it is not limited by CMake to two stages
  (`BOOTSTRAP_` variables nest). It does change the code generation of the shipped compiler, which is
  why tool speed is compared below. It is not a supported mode of this repository.
- **Tool code generation.** `CMAKE_BUILD_TYPE=Release` gives `-O3 -DNDEBUG`, which is what the
  previously shipped (stage-2) compiler used; the `-O2` seen in the old stage-1 flags never reached it.
  Alpine's clang additionally defaults to stack protection, stack-clash probes, and `_FORTIFY_SOURCE=2`;
  those are switched off for the tools so the build image's distro patches do not change the shipped
  compiler (see the comparison below for the size and speed they cost).
- **Linkage.** The tools embed the host libstdc++ and libgcc: `LLVM_STATIC_LINK_CXX_STDLIB=ON` plus
  `-static-libgcc` on executables, shared libraries, and modules (LLVM has no option for the latter).
  That is GNU code linked in statically, not a dynamic GNU dependency; the contract is "no dynamic GNU
  runtime dependency", enforced by `validate.sh` with an exact `DT_NEEDED` set (musl's libc only).
  zlib comes from Alpine's `libz.a`, so there is no `libz.so` dependency.
  These flags apply to the tools only; the runtimes are separate CMake projects that do not inherit them.
- **Runtime layout.** `LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF` keeps the flat layout of earlier packages
  (`lib/libc++.a`, `lib/clang/23/lib/linux/libclang_rt.builtins-<arch>.a`, `include/c++/v1/__config_site`),
  independent of how a consumer spells the target triple. `COMPILER_RT_DEFAULT_TARGET_ONLY=ON` means an
  x86-64 package never contains i386 builtins. The generated `clang{,++}.cfg` select lld and add
  `-L<CFGDIR>/../lib` (the driver only searches per-target subdirectories on its own).
  compiler-rt's `crtbegin`/`crtend` are installed with the builtins: with `--rtlib=compiler-rt` the driver
  uses them when present and otherwise falls back to GCC's, which made earlier packages link only on
  machines with a GCC installation. `libc++.a` includes the libc++abi objects
  (`LIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY`) so the driver's default `-lc++` is a complete link.
- **Distribution.** `LLVM_DISTRIBUTION_COMPONENTS` lists the tools plus the runtime install targets
  (`builtins`, `cxx`, `cxxabi`, `unwind`); `install-distribution` builds and installs exactly those.
  Nothing is built and then deleted. C++ module sources and libunwind headers are turned off to keep
  the package contents unchanged from earlier releases.
- **Alpine boundary.** Alpine packages are build inputs only. The package needs the target musl runtime
  and a sysroot at use time, but not Alpine's libclang, libstdc++, libgcc, or zlib. The image installs
  `linux-headers` for libc++'s futex support; no headers are fabricated.
- **Source and patches.** `llvm-source.env` pins the version and sha256 of the upstream source archive.
  `scripts/fetch-llvm-source.sh` verifies fresh and cached archives alike and extracts through
  `<dir>.partial`. `scripts/apply-patches.sh` applies `patches/*.patch` with zero fuzz, recognizes an
  already-applied patch, and keeps a content-hash stamp. See `patches/README.md`.
- **Reruns.** `build.sh` hashes the configuration inputs (cache file, CMake arguments, host compiler
  version) and reconfigures from an empty build tree when the hash changes; otherwise ninja is
  incremental. Cleanup only touches the build tree, the install prefix, and `WORK_DIR` state.
- **ccache.** LLVM uses CMake precompiled headers, which ccache refuses unless
  `CCACHE_SLOPPINESS=pch_defines,time_macros` (set by the Makefile). ccache statistics print at the end
  of every build log.

## Validation

`scripts/build.sh` runs the optimizer regressions (`repros/`, with the new `opt`/`FileCheck`, not
installed). `scripts/validate.sh` then runs in a container that has only musl's headers, startup
objects, and `libc.a` (no compiler, linker, libstdc++, or libgcc, and no network), on the package
extracted to a different absolute prefix:

- Package layout: exact expected entries for `bin/`, `lib/`, `include/`; required runtime files;
  no sanitizers, i386 runtimes, shared C++ runtimes, LLVM libraries, or development exports.
- ELF audit of every shipped ELF file (aliases are symlinks): machine, interpreter, exact `DT_NEEDED`
  (`libc.musl-<arch>.so.1` only), no `DT_RPATH`, `RUNPATH` only `$ORIGIN/../lib`, shared libraries have
  a `SONAME` and no interpreter. `libclang.so` and `libLTO.so` are included.
- Driver defaults (`-###`): libc++, libunwind, compiler-rt builtins and startup files, the package's
  `ld.lld`, no libstdc++/libgcc/GCC paths.
- C and C++ programs are compiled, linked, and **run**: default, explicit, documented (README), fully
  static, no-option, and `PATH`-lookup invocations. C++ covers exceptions with RAII unwinding, threads
  and `thread_local` destructors, libc++ facilities, RTTI, `__int128` and `long double` builtins.
- Multi-translation-unit `-flto=thin` (dynamic and static) with a check that cross-module inlining
  happened and a non-LTO control.
- Both compiled-in backends, LLVM utilities, zlib debug-section compression through lld and
  `llvm-symbolizer`, archives, and a libclang C API client.

## CI

`.github/workflows/llvm-prebuilt-musl.yml` (dispatch only; a `release` boolean input, default false)
runs `make source`, `make build`, `make validate` on `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm`
(aarch64). Caches: the source archive (content-addressed, re-verified on use) and ccache (key includes
architecture, LLVM version, and a hash of the image, cache file, build script, and patches). Neither is
needed for correctness. The release job runs only when requested and only if both architectures pass;
it publishes the two tarballs and a `checksums` file under `llvm-musl-<version>-<short sha>`.

## Comparison with the previous bootstrap build (LLVM 23.1.2, x86_64)

Measured on one 32-core, 60 GiB x86_64 Linux host with Docker; each build run once, no ccache. The
aarch64 package is not measured locally (CI builds it natively). Baseline = commit 0dba9a6: LLVM 23.1.2
built with the previous architecture (host tools, then a Clang self-bootstrap with stage-1 runtimes).

| | Bootstrap baseline | Single build |
|---|---|---|
| Clean build, wall clock | 14 min 18 s | 7 min 30 s |
| Peak container memory (`docker stats`, 20 s samples) | 7.96 GiB | 6.07 GiB |
| Build trees on disk | 4.1 GiB + 0.3 GiB (host tools) | 2.0 GiB |
| Package `.tar.xz` | 101,265,148 B | 101,372,860 B (+0.1%) |
| Unpacked | 472,146,559 B, 2141 files | 476,799,937 B, 2143 files |
| File list | | identical plus `clang_rt.crtbegin/crtend-x86_64.o`; `libc++.a` also holds the libc++abi objects (+0.7 MB) |
| Dynamic dependencies of every ELF | `libc.musl-x86_64.so.1` only | same |
| RUNPATH | `$ORIGIN/../lib:$ORIGIN/../lib/x86_64-linux-musl` | `$ORIGIN/../lib` |
| `scripts/validate.sh` (clean container) | 61 passed, 41 failed | 119 passed, 0 failed |
| Compile 173 LLVM `Support`/`Demangle` files, `-O2`, user CPU, 3 runs | 145.8-148.6 s | 147.6-150.1 s (+1%) |
| Same files with `-flto=thin` (bitcode emission), user CPU | 132.1-134.4 s | 133.4-135.3 s |
| ThinLTO link of those 173 modules into a shared library (all symbols live), wall | 9.23-9.39 s | 9.40-9.45 s |

- The baseline package cannot link any program in the clean container: it ships no compiler-rt startup
  files (the driver then wants GCC's `crtbeginS.o`), and its `lib/` is not on the driver's search path.
  Its own build-time validator passed 85/85 only because the build image has GCC installed and passed
  `-L` explicitly.
- The two builds' generated `config.h`/`llvm-config.h`/`abi-breaking.h` are identical, and the compile
  flags of a representative tool source (`clang/lib/Sema/SemaExpr.cpp`) are identical apart from the
  three hardening-neutralizing flags. Relinking the new
  `clang` with the tree's LLD 23 instead of Alpine's LLD 21 changed neither its size nor its speed.
- The old and new compilers generate byte-identical assembly (seven `Support`/`Demangle` translation units
  at `-O2`) and identical IR (`-O0` and `-O2`).
- Tool speed depends on the host compiler's defaults: with Alpine's hardening left on (stack protector,
  stack-clash probes, `_FORTIFY_SOURCE=2`) the same build gave a 152.2 MB `clang-23` (+12%), a 110.3 MB
  tarball, and a compiler 30-35% slower on the compile row above (188-198 s user CPU; parsing/Sema about
  1.7x). Removing stack protection alone did not close the gap; removing `_FORTIFY_SOURCE` as well did.
  On the workloads above the single-build compiler is within about 1% of the self-hosted one. That is
  one host and two workloads, not a claim of equivalence for every input.
