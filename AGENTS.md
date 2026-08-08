# Internal Build Documentation

User-facing artifact contents, usage, and Rust configuration are documented in `README.md`.

Builds a musl-linked LLVM/Clang toolchain for `x86_64-linux-musl`, `aarch64-linux-musl`.
Binaries are dynamically linked against musl only — zero GNU runtime dependencies.

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
  uses LLVM 23 `ld.lld`, not Alpine's packaged linker.
- **Shipped defaults**: `CLANG_DEFAULT_CXX_STDLIB=libstdc++`,
  `CLANG_DEFAULT_RTLIB=compiler-rt`, and `CLANG_DEFAULT_UNWINDLIB=libgcc`.
  The artifact still ships libc++ headers and static runtimes for explicit use.
- **Zlib support**: `LLVM_ENABLE_ZLIB=ON`, linked from Alpine's static `libz.a` so the artifact keeps no `libz.so` runtime dependency.
- **Link parallelism**: `LLVM_PARALLEL_LINK_JOBS=2`.
- **LLVM 23 DSE patch**: `patches/0001-dse-use-iterative-dominance-walk.patch` replaces
  the recursive DSE dominator-tree walk with an explicit worklist. The stage runner
  applies this patch before configuring the build.
- **Build dirs**: mounted to host filesystem (Docker overlay would fill up with ~30 GB).

### Local build

```sh
curl -fsSL -o llvm-project.tar.xz \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.0-rc2/llvm-project-23.1.0-rc2.src.tar.xz"
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

Runs inline during `scripts/stages/install-validate.sh`. Current coverage is 81 checks across:

- ELF linkage — every binary + libLTO.so: musl interpreter, musl-only NEEDED
- Artifact presence — all tools, headers, libraries present; no sanitizers
- Tool exercise — compile C, compile C++, default stdlib, exceptions, TLS, nm,
  readelf, readobj, objdump, objcopy, zlib debug-section compression, strip,
  ar+ranlib, lld (C + C++ link), strings, size, symbolizer, runtime execution
