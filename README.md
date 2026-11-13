# LLVM Prebuilt Musl

Prebuilt LLVM/Clang 23.1.5 toolchains for `x86_64-linux-musl` and
`aarch64-linux-musl`. Each package also carries musl 1.2.6's static libc and
startup objects, built by the packaged clang with compiler-rt, so a program can
be linked against a GCC-free musl without building one first. Packages target
their own architecture and contain the X86 and AArch64 compiler backends, with
compiler-rt for both, so either package also links the other architecture
against a sysroot the caller supplies. They also contain the BPF backend for
freestanding eBPF objects (`-target bpf`, `-ffreestanding -nostdinc`).
The tools and shared libraries are dynamically linked against musl and nothing
else (`libc.musl-<arch>.so.1`). They are built in two stages so that nothing
shipped contains GNU runtime code: libc++, libc++abi, libunwind, compiler-rt,
and a zlib built by the same clang are linked into them statically. The
executables also link mimalloc 2.5.2, built by the same clang, as their
allocator in place of musl's malloc, so a large ThinLTO link stays far below
the kernel's default `vm.max_map_count`. No glibc,
libgcc, libgcc_s, libstdc++, or `libz.so` is needed to run them, and
`scripts/check-purity.sh` fails the build and validation if any ELF file or
archive in either package names GCC in its `.comment`, links or references a GNU
runtime, or needs anything but musl.

## Artifact Contents

| Path | What |
|------|------|
| `bin/clang`, `bin/clang++`, `bin/clang-23`, `bin/clang-cl`, `bin/clang-cpp` | C/C++ compiler; defaults to the bundled libc++, compiler-rt, and lld |
| `bin/clang{,++}.cfg` | Driver configuration for every target: select `ld.lld` and compiler-rt, the bundled libunwind for `clang++` and no implicit unwinder for `clang` |
| `bin/<arch>-unknown-linux-musl.cfg` | Driver configuration for the package's own target only: search the package's `lib/` and `lib/musl/` |
| `bin/lld`, `bin/ld.lld`, `bin/ld64.lld`, `bin/lld-link`, `bin/wasm-ld` | LLVM linker |
| `bin/llvm-{ar,nm,objcopy,objdump,ranlib,readelf,readobj,size,strings,strip,symbolizer}` | Binary utilities |
| `lib/libclang.so`, `include/clang-c/` | Musl-linked libclang C API library and headers |
| `lib/libLTO.so`, `lto.h` in `include/llvm-c/` | Musl-linked LTO library and header |
| `lib/clang/23/include/` | Clang resource headers |
| `lib/clang/23/lib/linux/libclang_rt.builtins-{x86_64,aarch64}.a` | compiler-rt builtins for both architectures |
| `lib/clang/23/lib/linux/clang_rt.crt{begin,end}[-<arch>].o`, `crtbegin{,S,T}.o`, `crtend{,S}.o` | compiler-rt startup files under its own and GCC's names (symlinks), so the driver needs no GCC crt files |
| `include/c++/v1/` | libc++ headers, including the generated `__config_site` |
| `lib/libc++.a`, `lib/libc++abi.a`, `lib/libunwind.a`, `lib/libc++experimental.a` | Static C++ runtime libraries (`libc++.a` also contains the libc++abi objects) |
| `lib/musl/libc.a`, `lib/musl/{crt1,rcrt1,Scrt1,crti,crtn}.o` | musl 1.2.6 static libc and startup objects, built by the packaged clang with compiler-rt |
| `lib/musl/lib{m,rt,pthread,crypt,util,xnet,resolv,dl}.a` | musl's empty stub archives (everything lives in `libc.a`); they satisfy the dependent-library entries in `libunwind.a` and `-l` flags such as `-ldl` without a musl-dev sysroot |
| `lib/musl/libc.so` | Link-time script naming the system's `/lib/ld-musl-<arch>.so.1` for dynamic links; static links take `libc.a` |

Not included: musl headers or a target sysroot, sanitizers, shared C++
runtimes, clang-tools-extra, libxml2, zstd, and terminfo. The LLVM development
files are in the separate development package.

## Development package

`clang+llvm-<version>-<arch>-linux-musl-dev.tar.xz` holds `bin/llvm-config`, the
static LLVM component libraries for the X86, AArch64, and BPF targets, `include/llvm`,
`include/llvm-c`, the CMake exports under `lib/cmake/llvm`, and the
clang-built static zlib (`lib/libz.a`, `zlib.h` in `include/`) that
`llvm-config --system-libs` names as `-lz`. Its top-level
directory matches the compiler package, so extract both into the same place:

```sh
tar xf clang+llvm-23.1.5-aarch64-linux-musl.tar.xz
tar xf clang+llvm-23.1.5-aarch64-linux-musl-dev.tar.xz
clang+llvm-23.1.5-aarch64-linux-musl/bin/llvm-config --libs core
```

The libraries are built against libc++ with exceptions and RTTI off, like the
tools. Code that links them must use the package's libc++
(`clang++ $(llvm-config --cxxflags)`), never libstdc++. Rust's `rustc_llvm`, for
example, is built with `llvm.static-libstdcpp = false` and this package's
`clang++` as its C++ compiler.

## Usage

Extract the archive and add its `bin` directory to `PATH`:

```sh
tar xf clang+llvm-23.1.5-aarch64-linux-musl.tar.xz
export TOOLCHAIN="$PWD/clang+llvm-23.1.5-aarch64-linux-musl"
export PATH="$TOOLCHAIN/bin:$PATH"
```

The package needs the target's musl headers only: a musl-dev installation or a
sysroot that provides them. It does not need that sysroot's startup objects,
`libc.a`, GCC, libstdc++, or libgcc. For the package's own target,
`<arch>-unknown-linux-musl.cfg` searches `lib/musl/` first for startup files and
libraries, so a plain link uses the bundled musl 1.2.6 libc;
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

### Other targets

Clang reads `clang.cfg` or `clang++.cfg` for every target, and then
`<triple>.cfg` for the normalized target triple (`aarch64-linux-musl` normalizes
to `aarch64-unknown-linux-musl`). Only the package's own musl triple has one, so
the bundled musl, libc++, and libunwind are linked for that target alone. Any
other target, such as the other architecture or a glibc triple, links with the
shipped lld and compiler-rt, whose builtins and `crtbegin`/`crtend` objects the
package carries for both architectures, and takes its startup objects, libc,
and any C++ runtime from the `--sysroot` you pass:

```sh
clang --target=x86_64-unknown-linux-gnu --sysroot=/path/to/x86_64-glibc-sysroot hello.c -o hello
```

A vendor spelling other than `unknown`, such as `aarch64-alpine-linux-musl`,
is a different triple and does not get the package's musl paths either.

The BPF backend produces freestanding eBPF objects for a userspace loader to
embed. It takes no sysroot and links nothing:

```sh
clang --target=bpf -ffreestanding -nostdinc -O2 -c probe.c -o probe.o
```

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
sha256 are pinned in [`sources.lock.json`](sources.lock.json). Only the static libc, the startup objects, and musl's empty stub archives
(`libm.a`, `librt.a`, `libpthread.a`, `libcrypt.a`, `libutil.a`, `libxnet.a`,
`libresolv.a`, `libdl.a`, created with `llvm-ar`) are shipped; the
target's headers come from the consumer, and the dynamic loader is the system's.

## Patches

The build applies one local LLVM patch, an iterative rewrite of the Dead Store
Elimination dominator-tree walk that cannot overflow a small stack. See
[`patches/README.md`](patches/README.md).

## Building

The build runs in containers and needs Docker, `curl`, and `jaq`
(`sh scripts/install-jaq.sh <dir>` installs the pinned release). Builds take
hours; a ccache directory under `.work/` makes later ones faster.

| Command | What |
|---------|------|
| `make fetch` | Download, verify, and extract the sources pinned in [`sources.lock.json`](sources.lock.json) |
| `make build` | Fetch, build and package in a container, and name the release assets in `dist/release` |
| `make verify` | Test the packages in a clean, network-less container and check the release assets against them |
| `make lint` | Run shellcheck over the scripts and check the lock file |
| `make clean` | Remove this target's build tree and packages |

`TARGET` selects the package, `x86_64-unknown-linux-musl` or
`aarch64-unknown-linux-musl`, and defaults to the host's architecture. Docker
emulates the other architecture, slowly.

`sources.lock.json` pins every download: the LLVM, musl, zlib, and mimalloc
versions, URLs, and sha256 digests. `make fetch` verifies each archive on every
run, whether downloaded or cached, extracts it beside the cache under `.work/`,
and never modifies an extracted directory that already exists. To change a
version, update the lock entry together with the digest its `purpose` field
names as the source.

## Releases

`.github/workflows/release.yml` publishes a release. Dispatch it on the default
branch only: it builds and verifies both targets, checks `SHA256SUMS` with
`sha256sum -c`, and creates the pre-release `release-<commit sha>`, failing if
that tag exists. `.github/workflows/build.yml` builds and verifies both targets
on any branch without publishing. Releases made before this layout keep their
`llvm-musl-<version>-<short sha>` tags.

Each target publishes two layouts of the same bytes:

- `llvm-<version>-<target>.tar.xz` and `llvm-dev-<version>-<target>.tar.xz`, each
  with a `.manifest.json` naming the version, target, source commit, and the
  sha256 of `sources.lock.json`.
- `clang+llvm-<version>-<arch>-linux-musl.tar.xz` and the matching `-dev`
  archive, the original names. These stay because consumers pin them:
  laputa-systems/chromium-build, joshuarli/stats, joshuarli/soulseek-rs, the
  stuff fleet's musl toolchain policy, bctl, and hydrogen.

## Rust

Install the Rust musl target matching the toolchain:

```sh
rustup target add aarch64-unknown-linux-musl
```

Rust's `rust-lld` is a separate linker bundled with Rust. To use this
toolchain's zlib-enabled lld instead, configure Cargo to invoke the shipped
`clang` driver. The driver selects the shipped `ld.lld` and links static musl
targets against the bundled `libc.a` and startup objects.

Create `config.toml` in the Rust workspace's `.cargo/` directory:

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
