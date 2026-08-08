# LLVM Prebuilt Musl

Prebuilt LLVM/Clang 23.1.0-rc2 toolchains for `x86_64-linux-musl` and
`aarch64-linux-musl`. Shipped binaries and shared libraries are dynamically
linked against musl with no GNU runtime dependencies. LLVM zlib support is
statically linked into the tools, so no separate `libz.so` is required.

## Artifact Contents

| Path | What |
|------|------|
| `bin/clang`, `bin/clang++`, `bin/clang-23` | C/C++ compiler; defaults to bundled libc++, libunwind, and compiler-rt |
| `bin/lld`, `bin/ld.lld` | ELF linker |
| `bin/llvm-{ar,nm,objcopy,objdump,ranlib,readelf,readobj,size,strings,strip,symbolizer}` | Binary utilities |
| `lib/libclang.so` | Musl-linked libclang C API library |
| `include/clang-c/` | libclang C API headers |
| `lib/clang/23/include/` | Clang resource headers |
| `lib/clang/23/lib/linux/libclang_rt.builtins-*.a` | compiler-rt builtins |
| `include/c++/v1/` | libc++ headers |
| `lib/libc++.a`, `lib/libc++abi.a`, `lib/libunwind.a` | Static C++ runtime libraries |
| `lib/libLTO.so` | Musl-linked LTO plugin |

Not included: musl itself or a target sysroot, sanitizers, shared C++ libraries,
clang-tools-extra, CMake exports, libxml2, zstd, and terminfo.

## Usage

Extract the archive and add its `bin` directory to `PATH`:

```sh
tar xf clang+llvm-23.1.0-rc2-aarch64-linux-musl.tar.xz
export TOOLCHAIN="$PWD/clang+llvm-23.1.0-rc2-aarch64-linux-musl"
export PATH="$TOOLCHAIN/bin:$PATH"
```

Compile and link C:

```sh
clang --target=aarch64-linux-musl \
  --sysroot=/path/to/musl-sysroot \
  hello.c -o hello
```

Compile and link C++:

```sh
clang++ --target=aarch64-linux-musl \
  --sysroot=/path/to/musl-sysroot \
  -stdlib=libc++ \
  --unwindlib=libunwind \
  -cxx-isystem "$TOOLCHAIN/include/c++/v1" \
  -L "$TOOLCHAIN/lib" \
  -lc++abi -lunwind \
  hello.cpp -o hello
```

The musl sysroot must provide the target libc, startup objects, and system
headers. `clang++` defaults to the bundled libc++/libunwind/compiler-rt stack;
the explicit options above make the link contract clear and select the shipped
static C++ runtime libraries. The toolchain does not provide musl itself.

For tools that use libclang through bindgen or another C API client, point the
loader at the bundled library:

```sh
export LIBCLANG_PATH="$TOOLCHAIN/lib"
```

The LLVM 23 build applies `patches/0001-llvm23-dse-use-iterative-dominance-walk.patch`.
It replaces the recursive DSE dominator-tree walk with an explicit worklist;
the recursive implementation can overflow the stack during Bun's ThinLTO link.
See [`patches/README.md`](patches/README.md) for the patch history, upstream
references, and retained LLVM 22 reproductions.

The LLVM 22.1.8 build also applies
`patches/0002-llvm22-instcombine-recognize-non-negative-subtraction-patterns.patch`.
This is the upstream `computeKnownBitsAddSub` improvement and carries its
minimal InstCombine regression test. Patch filenames containing `-llvm22-` or
`-llvm23-` are applied only to the matching LLVM major version.
The standalone one-function input is retained at
`repros/llvm22-compute-known-bits-addsub.ll`.

It also applies
`patches/0003-llvm22-scev-limit-getrangeref-phi-recursion.patch`. This ports the
upstream ScalarEvolution PHI-range recursion fix for issue #148253, which can
otherwise exhaust the stack while ThinLTO runs loop unrolling.
The reduced control input is retained at
`repros/llvm22-scev-phi-range-recursion.ll`; with an unpatched LLVM 22 `opt`,
`ulimit -s 250; opt -passes=loop-unroll -disable-output repros/llvm22-scev-phi-range-recursion.ll`
exits with SIGSEGV, while the patched tool exits successfully.

For callers that intentionally use libstdc++, pass
`-stdlib=libstdc++ -static-libstdc++ -static-libgcc`. For explicit libc++
links, pass the shipped runtime libraries:

```sh
clang++ ... -lc++abi -lunwind hello.cpp -o hello
```

## Rust

Install the Rust musl target matching the toolchain:

```sh
rustup target add aarch64-unknown-linux-musl
```

Rust's `rust-lld` is a separate linker bundled with Rust. To use this
toolchain's zlib-enabled lld instead, configure Cargo to invoke the shipped
`clang` driver. The driver selects the shipped `ld.lld` and also supplies the
compiler-rt and musl link behavior.

Create `.cargo/config.toml` in the Rust workspace:

```toml
[target.aarch64-unknown-linux-musl]
linker = "/opt/clang+llvm-23.1.0-rc2-aarch64-linux-musl/bin/clang"
rustflags = [
  "-Clink-arg=--target=aarch64-linux-musl",
  "-Clink-arg=--sysroot=/opt/musl/aarch64",
]
```

Replace `/opt/clang+llvm-23.1.0-rc2-aarch64-linux-musl` and
`/opt/musl/aarch64` with the actual toolchain and musl sysroot paths. For
x86_64, use the corresponding values:

```toml
[target.x86_64-unknown-linux-musl]
linker = "/opt/clang+llvm-23.1.0-rc2-x86_64-linux-musl/bin/clang"
rustflags = [
  "-Clink-arg=--target=x86_64-linux-musl",
  "-Clink-arg=--sysroot=/opt/musl/x86_64",
]
```

Build with the target explicitly selected:

```sh
cargo build --target aarch64-unknown-linux-musl
```

Use `cargo build -vv` to confirm the linker command uses the shipped
`clang`. If the output still invokes `rust-lld`, Cargo is not using this
configuration and compressed debug sections may produce the original zlib
error.

For crates that compile native C or C++ code through the `cc` crate, also set
the target compiler and flags:

```sh
export CC_aarch64_unknown_linux_musl="$TOOLCHAIN/bin/clang"
export CFLAGS_aarch64_unknown_linux_musl="--target=aarch64-linux-musl --sysroot=/opt/musl/aarch64"
```
