# Internal Build Documentation

User-facing artifact contents, usage, and Rust configuration are documented in `README.md`.

Builds a musl-linked LLVM/Clang toolchain for `x86_64-linux-musl` and `aarch64-linux-musl`.
The tools and shared libraries depend dynamically on musl only. The package also carries a static
musl libc (libc.a and startup objects) built by the shipped clang, so consumers need no GCC-built
libc.

## Build graph

```
Alpine's packaged Clang + LLD
          |
          v
Stage 1: build patched LLVM/Clang/LLD 23.1.5 ONCE ----> optimizer regressions (opt, FileCheck)
          |
          v
Stage 1 runtimes (compiler-rt builtins, libc++, libc++abi, libunwind) by that clang,
installed to .work/<arch>/stage1; musl 1.2.6, zlib, and mimalloc built by that clang
          |
          v
Stage 2: rebuild the shipped tools and the LLVM development libraries with stage 1's
clang, against libc++/libunwind/compiler-rt and the clang-built musl and zlib
          |
          v
install-distribution + development components -> rebuild musl with the shipped clang
          |
          v
check-purity -> package (compiler tar.xz, -dev tar.xz) -> validate in a clean container
```

One CMake configuration file, two build trees: stage 1 (`build`) and stage 2 (`build2`). Nothing shipped may contain GNU runtime code; `scripts/check-purity.sh` enforces it. `scripts/build.sh` runs the phases inside a single
build container; `make build` and CI both call it.

## Commands

| Command | What |
|---------|------|
| `make fetch` | Fetch, verify, and extract the sources pinned in `sources.lock.json` |
| `make build` | Fetch, build the image, run `scripts/build.sh` in it, then name the release assets (`scripts/package.sh`) |
| `make verify` | Run `scripts/validate.sh` on the package in a separate, clean, network-less container, then check the release assets against it |
| `make` | `build` and `verify` |
| `make lint` | shellcheck over `scripts/` and a shape check of `sources.lock.json` (CI: `lint.yml`) |
| `make clean` / `make distclean` | Remove this target's state / all generated state (never a user-supplied `LLVM_DIR`) |

The host needs Docker, GNU make, `curl`, `tar`, `xz`, `jaq` (`scripts/install-jaq.sh`), and `sha256sum` (or
`shasum`); `make lint` also needs shellcheck. `TARGET=x86_64-unknown-linux-musl|aarch64-unknown-linux-musl`
selects the package (default: host architecture) and derives the architecture and Docker platform;
`scripts/build.sh` still receives `LLVM_ARCH`, `LLVM_VERSION`, `MUSL_VERSION`, `ZLIB_VERSION`, and
`MIMALLOC_VERSION`, which the Makefile reads from the lock. Other knobs: `WORK_DIR` (all generated
files, default `.work/`, git-ignored; repomod skips it), `LLVM_DIR` (an existing checkout of the pinned
release; it is patched, never deleted), `MUSL_DIR`, `OUT_DIR` (release assets, default `dist/release`),
`USE_CCACHE=0`, `LLVM_PARALLEL_LINK_JOBS` (default 2: linking LLVM tools needs several GiB each).
Outputs: `.work/<arch>/dist/clang+llvm-<version>-<arch>-linux-musl.tar.xz` (and `-dev`), a `.manifest`,
and `.work/<arch>/logs/build.log`; `dist/release/` holds each package under both asset names plus manifests.

Only the native architecture is built locally. The `aarch64` package is built and validated natively on
`ubuntu-26.04-arm` in CI; do not build it under emulation.

A CI run (both native jobs) is slow and expensive. Dispatch `build.yml` (or `release.yml`) only after a
clean local x86_64 `make build` and `make verify` pass, and do not dispatch either speculatively.

## Upgrading LLVM

- Pin an exact upstream stable release (not an RC or a branch). Take the `sha256` from the release
  metadata (`gh api repos/llvm/llvm-project/releases/tags/llvmorg-<version>`, asset
  `llvm-project-<version>.src.tar.xz`); the `llvm-project` entry of `sources.lock.json` is the only
  place the version is set (update its `url`, `archive`, `dir`, and `size` with it).
- Re-check each patch against the pristine tarball of the new release: drop a patch only after
  confirming the fix is in the source (not because it fails to apply), and keep its reproducer in
  `repros/`. Rebase with zero fuzz. Record the decision in `patches/README.md`.
- Keep the shipped compiler's code generation unchanged: `-O3 -DNDEBUG`, no `-march=native` or higher
  CPU baseline, no PGO/BOLT/LTO of LLVM itself unless that is the change being made.
- The bundled musl is pinned separately (`musl` in `sources.lock.json`); bump it only when changing the
  libc, and keep `docker/validate.Dockerfile` on an Alpine release that carries the same musl.

## File layout

```
sources.lock.json                  Pinned LLVM, musl, zlib, and mimalloc versions, URLs, sha256 (Makefile, scripts, CI)
Makefile                           Thin entry points; derives architecture and Docker platform from TARGET
docker/build.Dockerfile            Alpine 3.24.2 build image (clang22, lld22, cmake, ninja, ccache, zlib-static, ...)
docker/validate.Dockerfile         Clean consumer image: Alpine 3.24.2 musl-dev only, no compiler or linker
cmake/llvm-musl-distribution.cmake Initial CMake cache: what is built, how, and the distribution components
scripts/lock.sh                    jaq readers for sources.lock.json (sourced by the fetch and package scripts)
scripts/fetch-sources.sh           Download, verify (fresh or cached), extract each source archive in the lock
scripts/install-jaq.sh             Install the pinned jaq release (CI and local)
scripts/apply-patches.sh           Strict, repeatable application of patches/*.patch
scripts/install-musl-stubs.sh      Creates musl's empty stub archives in lib/musl (build.sh; validate.sh checks them)
scripts/build.sh                   configure -> compiler -> regressions -> distribution -> musl -> package
scripts/package.sh                 Publish the packages as llvm[-dev]-<version>-<target> plus manifests and the legacy names
scripts/verify-release.sh          Check dist/release against the validated packages and the lock
scripts/run-optimizer-regressions.sh  Runs repros/*.ll RUN lines with the new opt and FileCheck
scripts/validate.sh                Installed-package validation (runs in the clean container)
repros/                            Optimizer regression inputs and the DSE IR generator
tests/                             Programs compiled and run by validate.sh
patches/                           Local LLVM patch and its documentation
docs/                              Design notes, validation checklist, bootstrap comparison
.github/actions/build/action.yml   Shared build steps: caches, make build, make verify, artifact upload
.github/workflows/                 build.yml (prove a branch), release.yml (publish), lint.yml
```

## Documentation

- [docs/design.md](docs/design.md): compilers, runtimes, linkage, runtime layout, bundled libc, distribution,
  Alpine boundary, source pinning, reruns, and ccache.
- [docs/validation.md](docs/validation.md): what `scripts/build.sh` and `scripts/validate.sh` check.
- [docs/bootstrap-comparison.md](docs/bootstrap-comparison.md): measurements against the previous
  self-hosted bootstrap build.
- [README.md](README.md): artifact contents, usage, Rust configuration, building, and releases.

## CI

- `build.yml` (dispatch only) builds and verifies both targets on any ref without publishing.
- `release.yml` (dispatch only, default branch only) runs the same steps through
  `.github/actions/build/action.yml`, then checks every asset against the commit and `sources.lock.json`
  and publishes the pre-release `release-<sha>` with `SHA256SUMS`. Assets keep the legacy
  `clang+llvm-<version>-<arch>-linux-musl[-dev].tar.xz` names beside the standard ones; consumers pin them
  (README lists them), so do not rename or drop them.
- Runners are `ubuntu-26.04` (x86_64) and `ubuntu-26.04-arm` (aarch64). Caches: the pinned source archives
  (keyed by the hash of the lock, re-verified on use) and ccache (key includes architecture, LLVM version,
  and a hash of the image, cache file, build script, patches, and lock). Neither is needed for correctness.
- Release notes come from the shared `Write release notes` step (commits since the previous release).
