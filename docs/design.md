# Design notes

How the build produces the package and why. [AGENTS.md](../AGENTS.md) holds the build graph and commands.

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
  why tool speed is compared in [the bootstrap comparison](bootstrap-comparison.md). It is not a supported mode of this repository.
- **Tool code generation.** `CMAKE_BUILD_TYPE=Release` gives `-O3 -DNDEBUG`, which is what the
  previously shipped (stage-2) compiler used; the `-O2` seen in the old stage-1 flags never reached it.
  Alpine's clang additionally defaults to stack protection, stack-clash probes, and `_FORTIFY_SOURCE=2`;
  those are switched off for the tools so the build image's distro patches do not change the shipped
  compiler (see [the bootstrap comparison](bootstrap-comparison.md) for the size and speed they cost).
- **Linkage.** Stage 2's tools and libraries are built by stage 1's clang with `LLVM_ENABLE_LIBCXX=ON`
  and link libc++, libc++abi, libunwind, compiler-rt, the clang-built musl startup objects, and the
  clang-built zlib statically; only musl's libc is dynamic. The executables take the clang-built
  `libmimalloc.a` (pinned in `sources.lock.json`) with `--whole-archive`, so mimalloc replaces musl's
  malloc for the whole process: musl maps each large allocation group separately, and lld's ThinLTO
  link of a browser exceeded the default `vm.max_map_count` (65530) and failed with `LLVM ERROR: out
  of memory` while memory was free. `validate.sh` requires `clang` and `ld.lld` to report mimalloc's
  process init. `scripts/check-purity.sh` enforces it in
  `build.sh` and `validate.sh`: musl-only `DT_NEEDED` and interpreter, no `GCC:` in `.comment`, no
  libstdc++ or GNU symbol versions. The dev package ships that `libz.a` because `llvm-config
  --system-libs` reports `-lz`, and Alpine's `libz.a` is GCC-built.
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
- **Bundled libc.** musl is pinned in `sources.lock.json` and built out-of-tree after `install-distribution`,
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
  libclang, libstdc++, libgcc, or zlib. Both images use Alpine 3.24.2, pinned by digest with exact apk versions as the fleet's musl toolchain
  policy requires, so the validation image's musl-dev matches the bundled musl 1.2.6; musl itself builds
  freestanding. The build image
  installs `linux-headers` for libc++'s futex support; no headers are fabricated.
- **Source and patches.** `sources.lock.json` pins the version, URL, and sha256 of the LLVM, musl, zlib,
  and mimalloc source archives. `scripts/fetch-sources.sh` verifies fresh and cached archives alike and
  extracts through `<dir>.partial`. `scripts/apply-patches.sh` applies `patches/*.patch` with zero fuzz,
  recognizes an already-applied patch, and keeps a content-hash stamp. See `patches/README.md`.
- **Reruns.** `build.sh` hashes the configuration inputs (cache file, CMake arguments, host compiler
  version) and reconfigures from an empty build tree when the hash changes; otherwise ninja is
  incremental. Cleanup only touches the build tree, the install prefix, and `WORK_DIR` state.
- **ccache.** LLVM uses CMake precompiled headers, which ccache refuses unless
  `CCACHE_SLOPPINESS=pch_defines,time_macros` (set by the Makefile). ccache statistics print at the end
  of every build log.
