# Validation

What `make build` and `make verify` check. [AGENTS.md](../AGENTS.md) holds the commands.

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
- Links for the other architecture's musl and glibc triples and the package architecture's glibc
  triple against a stand-in sysroot: the plan names no package `lib/musl` path, takes `crt1.o` from the
  sysroot and compiler-rt's builtins and `crtbegin` for the right architecture, and the output has the
  right ELF machine.
- C and C++ programs are compiled, linked, and **run**: default, explicit, documented (README), fully
  static, static-PIE, no-option, and `PATH`-lookup invocations. C covers `unsigned __int128` division
  through compiler-rt builtins; C++ covers exceptions with RAII unwinding, threads and `thread_local`
  destructors, libc++ facilities, RTTI, `__int128` and `long double` builtins.
- Multi-translation-unit `-flto=thin` (dynamic and static) with a check that cross-module inlining
  happened and a non-LTO control.
- Both compiled-in backends, LLVM utilities, zlib debug-section compression through lld and
  `llvm-symbolizer`, archives, and a libclang C API client.
