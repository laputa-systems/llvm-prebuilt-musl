# LLVM Prebuilt Musl

Prebuilt LLVM/Clang 23.1.5 toolchains for `x86_64-linux-musl` and
`aarch64-linux-musl`. Each package also carries musl 1.2.6's static libc and
startup objects, built by the packaged clang with compiler-rt, so a program can
be linked against a GCC-free musl without building one first. Packages target
their own architecture and contain both the X86 and AArch64 compiler backends.
The tools and shared libraries are dynamically linked against musl and nothing
else (`libc.musl-<arch>.so.1`); libstdc++, libgcc, and zlib are linked into
them statically, so no GNU runtime libraries or `libz.so` are needed to run
them.

## Artifact Contents

| Path | What |
|------|------|
| `bin/clang`, `bin/clang++`, `bin/clang-23`, `bin/clang-cl`, `bin/clang-cpp` | C/C++ compiler; defaults to the bundled libc++, compiler-rt, and lld |
| `bin/clang.cfg`, `bin/clang++.cfg` | Driver configuration: select `ld.lld` and compiler-rt, the bundled libunwind for `clang++` and no implicit unwinder for `clang`; search the package's `lib/` and `lib/musl/` |
| `bin/lld`, `bin/ld.lld`, `bin/ld64.lld`, `bin/lld-link`, `bin/wasm-ld` | LLVM linker |
| `bin/llvm-{ar,nm,objcopy,objdump,ranlib,readelf,readobj,size,strings,strip,symbolizer}` | Binary utilities |
| `lib/libclang.so`, `include/clang-c/` | Musl-linked libclang C API library and headers |
| `lib/libLTO.so`, `include/llvm-c/lto.h` | Musl-linked LTO library and header |
| `lib/clang/23/include/` | Clang resource headers |
| `lib/clang/23/lib/linux/libclang_rt.builtins-<arch>.a` | compiler-rt builtins for the package's architecture |
| `lib/clang/23/lib/linux/clang_rt.crt{begin,end}[-<arch>].o`, `crtbegin{,S,T}.o`, `crtend{,S}.o` | compiler-rt startup files under its own and GCC's names (symlinks), so the driver needs no GCC crt files |
| `include/c++/v1/` | libc++ headers, including the generated `__config_site` |
| `lib/libc++.a`, `lib/libc++abi.a`, `lib/libunwind.a`, `lib/libc++experimental.a` | Static C++ runtime libraries (`libc++.a` also contains the libc++abi objects) |
| `lib/musl/libc.a`, `lib/musl/{crt1,rcrt1,Scrt1,crti,crtn}.o` | musl 1.2.6 static libc and startup objects, built by the packaged clang with compiler-rt |
| `lib/musl/libc.so` | Link-time script naming the system's `/lib/ld-musl-<arch>.so.1` for dynamic links; static links take `libc.a` |

Not included: musl headers or a target sysroot, sanitizers, shared C++
runtimes, clang-tools-extra, CMake exports and other LLVM development files,
libxml2, zstd, and terminfo.

## Usage

Extract the archive and add its `bin` directory to `PATH`:

```sh
tar xf clang+llvm-23.1.5-aarch64-linux-musl.tar.xz
export TOOLCHAIN="$PWD/clang+llvm-23.1.5-aarch64-linux-musl"
export PATH="$TOOLCHAIN/bin:$PATH"
```

The package needs the target's musl headers only: a musl-dev installation or a
sysroot that provides them. It does not need that sysroot's startup objects,
`libc.a`, GCC, libstdc++, or libgcc. `clang.cfg` searches `lib/musl/` first for
startup files and libraries, so a plain link uses the bundled musl 1.2.6 libc;
`libc.so` there is a link-time script that keeps an ordinary link dynamic
against the system's musl loader.

Compile and link C or C++ for the package's architecture:

```sh
clang --target=aarch64-linux-musl --sysroot=/path/to/musl-sysroot hello.c -o hello
clang++ --target=aarch64-linux-musl --sysroot=/path/to/musl-sysroot hello.cpp -o hello
```

Add `-static` or `-static-pie` for a fully static executable linked with the
bundled `libc.a`. The defaults are libc++ (`-stdlib=libc++`), compiler-rt
(`--rtlib=compiler-rt`), and the bundled lld (`-fuse-ld=lld`); the headers and
static archives come from the package. `clang++` links the bundled libunwind
(`--unwindlib=libunwind`), which libc++abi's exception support needs. `clang`
links no unwinder (`--unwindlib=none`), so C links and links for runtimes that
bring their own unwinder, such as Rust's, stay free of it; a C program that
unwinds adds `--unwindlib=libunwind`.

Every default can also be spelled out. This explicit form is equivalent for
programs that unwind and does not depend on `clang++.cfg`:

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

`lib/musl/libc.so` is a linker script, not a shared library: it resolves `-lc`
to the system's musl loader (through the sysroot, so `--sysroot` keeps working).
Without it, the bundled `libc.a` would win for dynamic links too and silently
produce a static-libc executable.

For tools that use libclang through bindgen or another C API client, point the
loader at the bundled library:

```sh
export LIBCLANG_PATH="$TOOLCHAIN/lib"
```

For callers that intentionally use libstdc++, pass
`-stdlib=libstdc++ -static-libstdc++ -static-libgcc`; the package does not
supply that runtime, so the caller's GCC installation must.

## Bundled musl

The libc is musl 1.2.6, built out-of-tree from the upstream release tarball
with the packaged clang, `llvm-ar`, `llvm-ranlib`, and compiler-rt builtins
(`--disable-shared`, no GCC anywhere in the build). The version and tarball
sha256 are pinned in [`musl-source.env`](musl-source.env), and the release notes
repeat the version. Only the static libc and startup objects are shipped; the
target's headers come from the consumer, and the dynamic loader is the system's.

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
`clang` driver. The driver selects the shipped `ld.lld` and links static musl
targets against the bundled `libc.a` and startup objects.

Create `.cargo/config.toml` in the Rust workspace:

```toml
[target.aarch64-unknown-linux-musl]
linker = "/opt/clang+llvm-23.1.5-aarch64-linux-musl/bin/clang"
rustflags = [
  "-Clink-arg=--target=aarch64-linux-musl",
  "-Clink-arg=--sysroot=/opt/musl/aarch64",
]
```

Replace `/opt/clang+llvm-23.1.5-aarch64-linux-musl` and
`/opt/musl/aarch64` with the actual toolchain and musl sysroot paths. The
sysroot supplies the target's libc headers; the startup objects, `libc.a`, and
C++ runtimes come from the package. For x86_64, use the corresponding values:

```toml
[target.x86_64-unknown-linux-musl]
linker = "/opt/clang+llvm-23.1.5-x86_64-linux-musl/bin/clang"
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
