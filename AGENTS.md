# LLVM Prebuilt (musl)

Builds musl-linked LLVM/Clang release artifacts for [Laputa](https://github.com/laputa-systems/laputa).
Binaries are dynamically linked against musl only — zero GNU runtime dependencies.

LLVM `22.1.8`. Architectures: `x86_64`, `aarch64`. Triples: `x86_64-linux-musl`, `aarch64-linux-musl`.

## Artifact Contents

| Path | What |
|------|------|
| `bin/clang`, `bin/clang++`, `bin/clang-22` | C/C++ compiler (defaults: `-stdlib=libc++`, `--rtlib=compiler-rt`) |
| `bin/lld`, `bin/ld.lld` | ELF linker |
| `bin/llvm-{ar,nm,objcopy,objdump,ranlib,readelf,readobj,size,strings,strip,symbolizer}` | Binary utilities |
| `lib/clang/22/include/` | Clang resource headers |
| `lib/clang/22/lib/linux/libclang_rt.builtins-*.a` | compiler-rt builtins |
| `include/c++/v1/` | libc++ headers |
| `lib/libc++.a`, `lib/libc++abi.a`, `lib/libunwind.a` | C++ runtime (static only, no .so) |
| `lib/libLTO.so` | LTO plugin (musl-linked) |

Not included: sanitizers, shared C++ libraries, clang-tools-extra, cmake exports, libxml2/zlib/zstd/terminfo.

## Usage

```
tar xf clang+llvm-22.1.8-aarch64-linux-musl.tar.xz
export PATH="$PWD/clang+llvm-22.1.8-aarch64-linux-musl/bin:$PATH"
```

Compile and link:
```
clang   --target=aarch64-linux-musl --sysroot=/path/to/sysroot hello.c  -o hello
clang++ --target=aarch64-linux-musl --sysroot=/path/to/sysroot hello.cpp -o hello
```

In most cases you also need to point at the shipped libc++ headers and libraries,
since they live outside a typical musl sysroot:
```
clang++ --target=aarch64-linux-musl --sysroot=/path/to/sysroot         \
        -cxx-isystem $TOOLCHAIN/include/c++/v1 -L $TOOLCHAIN/lib       \
        hello.cpp -o hello
```

**Known issue**: clang targeting musl may not auto-append `-lc++abi -lunwind`.
If linking fails with undefined `__cxa_*`/`_Unwind_*`/vtable symbols, add them explicitly:
```
clang++ ... -lc++abi -lunwind hello.cpp -o hello
```

Every shipped binary has only `libc.musl-*.so.1` in NEEDED (no libstdc++.so.6, no libgcc_s.so.1).

## Build

Two paths, same artifact:

| Path | Where | How |
|------|-------|-----|
| CI | ubuntu-24.04 / ubuntu-24.04-arm | Container-native Alpine (no cross) |
| Local | macOS / Linux | Docker + `make build` |

```
LLVM source → host tools → configure → stage1 lld → stage2 (shipped) → install → validate
```

- **Host compiler**: Alpine clang (not GCC).
- **Stage entrypoints**: CI calls `scripts/stages/*.sh` directly. `scripts/build-llvm-musl.sh`
  remains the local full-build wrapper and runs those stages in order.
- **Stage2 linkage**: `-static-libstdc++ -static-libgcc`. We tried `BOOTSTRAP_LLVM_ENABLE_LIBCXX=ON`
  to link against libc++ instead, but stage1 libc++.a carries host libstdc++ ABI references and
  stage1 runtimes can't be built with `-stdlib=libc++` (chicken-and-egg — libc++ must exist to
  build libc++). LLVM's 2-stage bootstrap can't resolve this. Static linking is the practical fix.
- **Stage1 linker**: build same-tree `lld` before stage2 runtimes configure so `-fuse-ld=lld`
  uses LLVM 22 `ld.lld`, not Alpine's packaged linker.
- **Shipped defaults**: `CLANG_DEFAULT_CXX_STDLIB=libc++`, `CLANG_DEFAULT_RTLIB=compiler-rt`.
- **Link parallelism**: `LLVM_PARALLEL_LINK_JOBS=2`.
- **Build dirs**: mounted to host filesystem (Docker overlay would fill up with ~30 GB).

### Local build

```sh
curl -fsSL -o llvm-project.tar.xz \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.8/llvm-project-22.1.8.src.tar.xz"
mkdir -p llvm-project && tar -xf llvm-project.tar.xz -C llvm-project --strip-components=1
docker build --platform linux/arm64 -f docker/alpine-llvm-musl.Dockerfile -t llvm-prebuilt-musl:alpine .
LLVM_ARCH=aarch64 make build
```

On x86_64 omit `--platform` (native).

## Files

```
scripts/build-llvm-musl.sh        Full local wrapper: runs all stage scripts
scripts/llvm-musl-stage-runner.sh Shared implementation used by each stage
scripts/stages/host-tools.sh      Build + validate native host tools
scripts/stages/configure.sh       Configure bootstrap build + validate CMake graph
scripts/stages/stage1-lld.sh      Build + validate same-tree stage1 ld.lld
scripts/stages/stage2.sh          Build + validate stage2 tree
scripts/stages/install-validate.sh Install, normalize runtime files, full validation
cmake/llvm-musl-distribution.cmake Distribution cache (targets, components, OFF flags)
docker/alpine-llvm-musl.Dockerfile Alpine 3.23 image (bash, clang, lld, ninja, ccache…)
.github/workflows/llvm-prebuilt-musl.yml CI
```

CI restores caches before the build and saves them at useful boundaries:

- LLVM source tarball after download
- host tools after `host-tools`
- ccache after the job, even if a later build stage fails

## Validation

Runs inline during `scripts/stages/install-validate.sh`. Current coverage is 80 checks across:

- ELF linkage — every binary + libLTO.so: musl interpreter, musl-only NEEDED
- Artifact presence — all tools, headers, libraries present; no sanitizers
- Tool exercise — compile C, compile C++, default stdlib, exceptions, TLS, nm,
  readelf, readobj, objdump, objcopy, strip, ar+ranlib, lld (C + C++ link),
  strings, size, symbolizer, runtime execution
