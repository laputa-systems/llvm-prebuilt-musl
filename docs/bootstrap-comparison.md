# Comparison with the previous bootstrap build (LLVM 23.1.2, x86_64)

Why the build is a single stage 1 plus stage 2 pass. [Design notes](design.md) describe the current build.

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
  flags of a representative tool source (`SemaExpr.cpp` in clang's Sema library) are identical apart from the
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
