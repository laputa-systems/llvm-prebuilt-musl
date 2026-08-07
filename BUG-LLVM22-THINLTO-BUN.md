# LLVM 22 prebuilt ThinLTO crash while linking Bun

Date: 2026-08-03

## Summary

The released `llvm-musl-22.1.8` prebuilt toolchain crashes inside the final
ThinLTO link of Bun. The failure reproduces on native `x86_64` Linux, so it is
not caused by ARM emulation, ARM ELF layout, or the target CPU. The same link
also crashes in an `aarch64` Alpine build under QEMU.

Alpine edge's distro Clang/LLD 22.1.8 packages complete the equivalent native
`x86_64` Bun link successfully. This points to a difference in the prebuilt
toolchain build or shipped defaults, rather than an unconditional LLVM 22
source-level failure.

## Reproduction

The Bun build is a static musl Release build with ThinLTO and contains 1,178
explicit link inputs. The native reproduction was captured without rerunning
the compile phase, then replayed with the prebuilt toolchain's `clang++`:

```text
-flto=thin -fwhole-program-vtables -fforce-emit-vtables -O2
-static-libstdc++ -static-libgcc -static
-Wl,--lto-whole-program-visibility
-Wl,--gc-sections -Wl,-icf=safe -Wl,--gdb-index
```

The exact replay ends with:

```text
clang++: error: unable to execute command: Segmentation fault (core dumped)
clang++: error: linker command failed due to signal 11
```

GDB resolves the fault to:

```text
computeKnownBitsAddSub(...)
```

The crashing thread is an in-process ThinLTO backend. The main lld thread is
waiting in `llvm::lto::ThinBackendProc::wait()`. With
`--lto-debug-pass-manager`, the trace reaches ordinary InstCombine processing
of the libjpeg function `encode_one_block` before the crash.

The failure was reproduced with:

- whole-program visibility enabled and disabled;
- lld's normal thread count and `--threads=1`;
- ThinLTO optimization levels O1 and O2;
- the prebuilt lld wrapper both with and without the unrelated zlib debug-section
  flag filtering.

Disabling LTO does not provide a fallback: it reaches the final link but has
thousands of missing WebKit C++ symbols, so it is not an equivalent build.

## Comparison

The following native Alpine edge packages complete the same Bun build:

```text
clang22  22.1.8-r0
lld22    22.1.8-r0
llvm22   22.1.8-r1
```

That build produces a static x86-64 Bun binary and passes startup, arithmetic,
symbol, and live mimalloc heap-stat/heap-dump checks. The resulting Bun binary
The corresponding Alpine aarch64 build also reaches the final ThinLTO link
without the prebuilt-toolchain SIGSEGV, but the full link under QEMU exhausts
the emulated process's memory after about two hours (`qemu_memalign: failed to
allocate 64 bytes ... Out of memory`). That is an emulation/resource failure,
not evidence of a second LLVM optimizer crash.

## Suggested investigation

Compare the prebuilt and Alpine package builds for:

1. LLVM/LLD CMake options affecting ThinLTO's in-process optimizer and pass
   pipeline;
2. compiler-rt, libc++, libc++abi, and libunwind versions and link inputs;
3. target CPU/features and default optimization/configuration files;
4. assertions, sanitizers, and any downstream Alpine LLVM patches;
5. the exact `computeKnownBitsAddSub` implementation and LLVM 22.1.8 fixes
   present in Alpine's package sources.

The Highway scalable-SVE `BitsFromMask` failure documented in `TODO.md` is a
separate frontend compatibility issue and is not the cause of this ThinLTO
linker crash.
