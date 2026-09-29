# LLVM Prebuilt Musl

Prebuilt LLVM/Clang 23.1.2 toolchains for `x86_64-linux-musl` and
`aarch64-linux-musl`. Each package targets its own architecture and contains
both the X86 and AArch64 compiler backends. The tools and shared libraries are
dynamically linked against musl and nothing else (`libc.musl-<arch>.so.1`);
libstdc++, libgcc, and zlib are linked into them statically, so no GNU runtime
libraries or `libz.so` are needed to run them.

## Artifact Contents

| Path | What |
|------|------|
| `bin/clang`, `bin/clang++`, `bin/clang-23`, `bin/clang-cl`, `bin/clang-cpp` | C/C++ compiler; defaults to the bundled libc++, libunwind, compiler-rt, and lld |
| `bin/clang.cfg`, `bin/clang++.cfg` | Driver configuration: select `ld.lld` and add the package's `lib/` to the library search path |
| `bin/lld`, `bin/ld.lld`, `bin/ld64.lld`, `bin/lld-link`, `bin/wasm-ld` | LLVM linker |
| `bin/llvm-{ar,nm,objcopy,objdump,ranlib,readelf,readobj,size,strings,strip,symbolizer}` | Binary utilities |
| `lib/libclang.so`, `include/clang-c/` | Musl-linked libclang C API library and headers |
| `lib/libLTO.so`, `include/llvm-c/lto.h` | Musl-linked LTO library and header |
| `lib/clang/23/include/` | Clang resource headers |
| `lib/clang/23/lib/linux/libclang_rt.builtins-<arch>.a` | compiler-rt builtins for the package's architecture |
| `lib/clang/23/lib/linux/clang_rt.crt{begin,end}-<arch>.o` | compiler-rt startup files, used by the driver in place of GCC's |
| `include/c++/v1/` | libc++ headers, including the generated `__config_site` |
| `lib/libc++.a`, `lib/libc++abi.a`, `lib/libunwind.a`, `lib/libc++experimental.a` | Static C++ runtime libraries (`libc++.a` also contains the libc++abi objects) |

Not included: musl itself or a target sysroot, sanitizers, shared C++
runtimes, clang-tools-extra, CMake exports and other LLVM development files,
libxml2, zstd, and terminfo.

## Usage

Extract the archive and add its `bin` directory to `PATH`:

```sh
tar xf clang+llvm-23.1.2-aarch64-linux-musl.tar.xz
export TOOLCHAIN="$PWD/clang+llvm-23.1.2-aarch64-linux-musl"
export PATH="$TOOLCHAIN/bin:$PATH"
```

The package needs a musl sysroot that provides the target libc: system
headers, startup objects (`crt1.o`, `crti.o`, `crtn.o`, ...), and `libc.a` or
the musl shared library. It does not bundle one, and it does not need GCC,
libstdc++, or libgcc on the build machine.

Compile and link C or C++ for the package's architecture:

```sh
clang --target=aarch64-linux-musl --sysroot=/path/to/musl-sysroot hello.c -o hello
clang++ --target=aarch64-linux-musl --sysroot=/path/to/musl-sysroot hello.cpp -o hello
```

Add `-static` for a fully static executable. The defaults are libc++
(`-stdlib=libc++`), compiler-rt (`--rtlib=compiler-rt`), libunwind
(`--unwindlib=libunwind`), and the bundled lld (`-fuse-ld=lld`, from
`clang.cfg`); the headers and static archives come from the package.

Every default can also be spelled out. This explicit form is equivalent and
does not depend on `clang++.cfg`:

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

`-flto=thin` works with the bundled lld, including for static musl links.

For tools that use libclang through bindgen or another C API client, point the
loader at the bundled library:

```sh
export LIBCLANG_PATH="$TOOLCHAIN/lib"
```

For callers that intentionally use libstdc++, pass
`-stdlib=libstdc++ -static-libstdc++ -static-libgcc`; the package does not
supply that runtime, so the caller's GCC installation must.

## Patches

The build applies one local LLVM patch, an iterative rewrite of the Dead Store
Elimination dominator-tree walk that cannot overflow a small stack. See
[`patches/README.md`](patches/README.md).

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
linker = "/opt/clang+llvm-23.1.2-aarch64-linux-musl/bin/clang"
rustflags = [
  "-Clink-arg=--target=aarch64-linux-musl",
  "-Clink-arg=--sysroot=/opt/musl/aarch64",
]
```

Replace `/opt/clang+llvm-23.1.2-aarch64-linux-musl` and
`/opt/musl/aarch64` with the actual toolchain and musl sysroot paths. For
x86_64, use the corresponding values:

```toml
[target.x86_64-unknown-linux-musl]
linker = "/opt/clang+llvm-23.1.2-x86_64-linux-musl/bin/clang"
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
