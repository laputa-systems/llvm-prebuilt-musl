# Internal Build Documentation

User-facing artifact contents, usage, and Rust configuration are documented in `README.md`.

Builds a musl-linked LLVM/Clang toolchain for `x86_64-linux-musl` and `aarch64-linux-musl`.
The tools and shared libraries depend dynamically on musl only. The package also carries a static
musl libc (libc.a and startup objects) built by the shipped clang, so consumers need no GCC-built
libc.

## Build graph

```
Alpine's packaged Clang + LLD
          |
          v
Build patched LLVM/Clang/LLD 23.1.5 tools ONCE ----> optimizer regressions (opt, FileCheck)
          |
          v
Build compiler-rt builtins and C++ runtimes with that new Clang (same build tree)
          |
          v
install-distribution -> build musl 1.2.6 with the installed clang -> add lib/musl
          |
          v
package (tar.xz) -> validate in a clean container
```

One CMake configuration, one LLVM build tree. `scripts/build.sh` runs the phases inside a single
build container; `make build` and CI both call it.

## Commands

| Command | What |
|---------|------|
| `make build` | Fetch and verify the pinned source, build the image, run `scripts/build.sh` in it |
| `make validate` | Run `scripts/validate.sh` on the package in a separate, clean, network-less container |
| `make` | Both |
| `make source` | Only fetch, verify, and extract the LLVM and musl sources |
| `make clean` / `make distclean` | Remove this architecture's state / all generated state (never a user-supplied `LLVM_DIR`) |

The host needs Docker, GNU make, `curl`, `tar`, `xz`, and `sha256sum` (or `shasum`). `LLVM_ARCH=x86_64|aarch64` selects the package (default: host architecture; `arm64` and `amd64` are
normalized) and the matching Docker platform. Other knobs: `WORK_DIR` (all generated files, default
`work/`, git-ignored), `LLVM_DIR` (an existing checkout of the pinned release; it is patched, never
deleted), `MUSL_DIR` (an existing checkout of the pinned musl release), `USE_CCACHE=0`,
`LLVM_PARALLEL_LINK_JOBS` (default 2: linking LLVM tools needs several GiB each). Outputs:
`work/<arch>/dist/clang+llvm-<version>-<arch>-linux-musl.tar.xz`, a `.manifest`, and
`work/<arch>/logs/build.log`.

Only the native architecture is built locally. The `aarch64` package is built and validated natively on
`ubuntu-24.04-arm` in CI; do not build it under emulation.

A CI run (both native jobs) is slow and expensive. Dispatch it only after a clean local x86_64
`make build` and `make validate` pass, and do not dispatch it speculatively.

## Upgrading LLVM

- Pin an exact upstream stable release (not an RC or a branch). Take `LLVM_SOURCE_SHA256` from the
  release metadata (`gh api repos/llvm/llvm-project/releases/tags/llvmorg-<version>`, asset
  `llvm-project-<version>.src.tar.xz`); `llvm-source.env` is the only place the version is set.
- Re-check each patch against the pristine tarball of the new release: drop a patch only after
  confirming the fix is in the source (not because it fails to apply), and keep its reproducer in
  `repros/`. Rebase with zero fuzz. Record the decision in `patches/README.md`.
- Keep the shipped compiler's code generation unchanged: `-O3 -DNDEBUG`, no `-march=native` or higher
  CPU baseline, no PGO/BOLT/LTO of LLVM itself unless that is the change being made.
- The bundled musl is pinned separately in `musl-source.env`; bump it only when changing the libc,
  and let both versions reach the release notes.

## Files

```
llvm-source.env                    Pinned LLVM version + source sha256 (Makefile, scripts, CI)
musl-source.env                    Pinned musl version + source sha256 for the bundled libc
Makefile                           Thin entry points; derives Docker platform from LLVM_ARCH
docker/build.Dockerfile            Alpine 3.23 build image (clang, lld, cmake, ninja, ccache, zlib-static, ...)
docker/validate.Dockerfile         Clean consumer image: Alpine 3.24 musl-dev only, no compiler or linker
cmake/llvm-musl-distribution.cmake Initial CMake cache: what is built, how, and the distribution components
scripts/fetch-llvm-source.sh       Download, verify (fresh or cached), extract the LLVM source archive
scripts/fetch-musl-source.sh       Download, verify (fresh or cached), extract the musl source archive
scripts/apply-patches.sh           Strict, repeatable application of patches/*.patch
scripts/install-musl-stubs.sh      Creates musl's empty stub archives in lib/musl (build.sh; validate.sh checks them)
scripts/build.sh                   configure -> compiler -> regressions -> distribution -> musl -> package
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
  (`scripts/build.sh`) makes the runtimes configure with LLVM 23.1.5's `ld.lld`, not Alpine's.
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
  x86-64 package never contains i386 builtins. The generated `clang{,++}.cfg` select lld and compiler-rt,
  set `--unwindlib=libunwind` for `clang++` and `--unwindlib=none` for `clang`, and add
  `-B<CFGDIR>/../lib/musl -L<CFGDIR>/../lib/musl -L<CFGDIR>/../lib`
  (the driver only searches per-target subdirectories on its own). `-B` is a driver option: it makes `crt1.o`,
  `Scrt1.o`, `rcrt1.o`, `crti.o`, and `crtn.o` resolve inside the package; `-L` makes `libc.a` the
  static-libc choice. libc++abi references the unwinder, so a default `clang++` link must add
  `-lunwind`; a default `clang` link must not, so C and Rust links keep their own unwinding choice.
  compiler-rt's `crtbegin`/`crtend` are installed with the builtins and are the real objects (an empty
  stub would lose `__dso_handle` and break C++ static destructors, which `tests/cxx/features.cpp`
  checks). The GCC names (`crtbegin{,S,T}.o`, `crtend{,S}.o`) and the non-arch names
  (`clang_rt.crt{begin,end}.o`) are symlinks to those objects in the resource dir, so a driver that
  falls back to `GetFilePath` still needs no GCC crt files. `libc++.a` includes the libc++abi objects
  (`LIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY`) so the driver's default `-lc++` is a complete link.
- **Bundled libc.** musl is pinned in `musl-source.env` and built out-of-tree after `install-distribution`,
  with the installed package's own `clang`, `llvm-ar`, and `llvm-ranlib`, and
  `LIBCC=<resource dir>/libclang_rt.builtins-<arch>.a`: `./configure --disable-shared --target=<arch>`,
  then `make`. `libc.a` and `crt1.o`, `rcrt1.o`, `Scrt1.o`, `crti.o`, `crtn.o` are installed to
  `lib/musl/`, next to musl's empty stub archives (`libm.a`, `librt.a`, `libpthread.a`, `libcrypt.a`,
  `libutil.a`, `libxnet.a`, `libresolv.a`, `libdl.a`) made by `scripts/install-musl-stubs.sh` with the
  packaged `llvm-ar`: `libunwind.a` carries dependent-library entries for `dl` and `pthread`, and lld fails
  the link unless it finds those files, which a headers-only sysroot does not provide; no musl headers are shipped. Because a directory holding only `libc.a` would also win
  `-lc` for ordinary links, `lib/musl/libc.so` is a generated linker script,
  `GROUP ( =/lib/ld-musl-<arch>.so.1 )`: lld expands `=` against `--sysroot`, so default links stay
  dynamically linked to the system loader and `-static`/`-static-pie` take the archive. The musl build
  uses no GCC, and `validate.sh` fails the job if any `.comment` in `libc.a`, the bundled crt objects,
  `libunwind.a`, or the builtins names GCC.
- **Distribution.** `LLVM_DISTRIBUTION_COMPONENTS` lists the tools plus the runtime install targets
  (`builtins`, `cxx`, `cxxabi`, `unwind`); `install-distribution` builds and installs exactly those.
  Nothing is built and then deleted. C++ module sources and libunwind headers are turned off to keep
  the package contents unchanged from earlier releases.
- **Alpine boundary.** Alpine packages are build inputs only. At use time the package needs the target's
  musl headers, but not its startup objects or `libc.a` (they come from the package), and not Alpine's
  libclang, libstdc++, libgcc, or zlib. The validation image is Alpine 3.24 so musl-dev matches the
  bundled musl 1.2.6; the build image stays 3.23 because musl builds freestanding. The build image
  installs `linux-headers` for libc++'s futex support; no headers are fabricated.
- **Source and patches.** `llvm-source.env` and `musl-source.env` pin the versions and sha256 of the
  upstream source archives. `scripts/fetch-*-source.sh` verify fresh and cached archives alike and
  extract through `<dir>.partial`. `scripts/apply-patches.sh` applies `patches/*.patch` with zero fuzz,
  recognizes an already-applied patch, and keeps a content-hash stamp. See `patches/README.md`.
- **Reruns.** `build.sh` hashes the configuration inputs (cache file, CMake arguments, host compiler
  version) and reconfigures from an empty build tree when the hash changes; otherwise ninja is
  incremental. Cleanup only touches the build tree, the install prefix, and `WORK_DIR` state.
- **ccache.** LLVM uses CMake precompiled headers, which ccache refuses unless
  `CCACHE_SLOPPINESS=pch_defines,time_macros` (set by the Makefile). ccache statistics print at the end
  of every build log.

## Validation

`scripts/build.sh` runs the optimizer regressions (`repros/`, with the new `opt`/`FileCheck`, not
installed). `scripts/validate.sh` then runs in a container that has musl's headers and dynamic loader
(no compiler, linker, libstdc++, or libgcc, and no network), on the package extracted to a different
absolute prefix. The container's musl-dev archives are GCC-built, so any accidental fallback to them
is caught:

- Package layout: exact expected entries for `bin/`, `lib/`, `include/`, and `lib/musl/`; required
  runtime files; no sanitizers, i386 runtimes, shared C++ runtimes, LLVM libraries, or development
  exports. `lib/musl/libc.so` must be the sysroot-relative loader script, and `libc.a` must carry the
  pinned musl version string.
- ELF audit of every shipped ELF file (aliases are symlinks): machine, interpreter, exact `DT_NEEDED`
  (`libc.musl-<arch>.so.1` only), no `DT_RPATH`, `RUNPATH` only `$ORIGIN/../lib`, shared libraries have
  a `SONAME` and no interpreter. `libclang.so` and `libLTO.so` are included.
- GCC-free provenance: `llvm-readelf -p .comment` over `libc.a`, its crt objects, `libunwind.a`, and
  the compiler-rt builtins contains no `GCC:` string; a linked static program's `.comment` must not
  either.
- Driver defaults (`-###`): libc++, compiler-rt builtins and startup files, `-lunwind` for `clang++`
  and none for `clang`, the package's musl startup objects and
  `libc.a`, the package's `ld.lld`, no libstdc++/libgcc/GCC paths.
- Static C++ and `--unwindlib=libunwind` C links against a headers-only `--sysroot` (a symlink to musl's
  headers, no `/usr/lib`), so the container's musl-dev stub archives cannot mask a missing `lib/musl` stub.
- C and C++ programs are compiled, linked, and **run**: default, explicit, documented (README), fully
  static, static-PIE, no-option, and `PATH`-lookup invocations. C covers `unsigned __int128` division
  through compiler-rt builtins; C++ covers exceptions with RAII unwinding, threads and `thread_local`
  destructors, libc++ facilities, RTTI, `__int128` and `long double` builtins.
- Multi-translation-unit `-flto=thin` (dynamic and static) with a check that cross-module inlining
  happened and a non-LTO control.
- Both compiled-in backends, LLVM utilities, zlib debug-section compression through lld and
  `llvm-symbolizer`, archives, and a libclang C API client.

## CI

`.github/workflows/llvm-prebuilt-musl.yml` (dispatch only; a `release` boolean input, default false)
runs `make source`, `make build`, `make validate` on `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm`
(aarch64). Caches: the pinned source archives (content-addressed with both LLVM and musl versions,
re-verified on use) and ccache (key includes architecture, LLVM version, and a hash of the image, cache
file, build script, and patches). Neither is needed for correctness. The release job runs only when
requested and only if both architectures pass; it publishes the two tarballs and a `checksums` file
under `llvm-musl-<version>-<short sha>`, with the LLVM and musl versions in the release notes.

## Comparison with the previous bootstrap build (LLVM 23.1.2, x86_64)

Measured on one 32-core, 60 GiB x86_64 Linux host with Docker; each build run once, no ccache. These
measurements predate the bundled musl libc. The aarch64 package is not measured locally (CI builds it
natively). Baseline = commit 0dba9a6: LLVM 23.1.2 built with the previous architecture (host tools,
then a Clang self-bootstrap with stage-1 runtimes).

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
