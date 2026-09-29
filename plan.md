# Upgrade llvm-prebuilt-musl to LLVM 23.1.2 and simplify its build

Implement this to completion, including build scripts, CMake configuration, CI, validation, packaging, and documentation. Do not stop at a proposal.

Read `AGENTS.md`, the workflow, `Makefile`, Dockerfile, distribution cache, stage runner, and patch documentation first. Adapt to the current checkout rather than assuming every file is unchanged. Preserve unrelated work.

## 0. Execution environment and completion criteria

The development host is x86_64 Linux. Do all local building and validation for `x86_64-linux-musl` only; do not build or emulate `aarch64-linux-musl` locally (no QEMU-backed `docker build --platform linux/arm64` and no `LLVM_ARCH=aarch64 make build` on this host). The `aarch64` path is exercised natively by CI (`ubuntu-24.04-arm`), not by local emulation — treat the local x86_64 build as the correctness signal for shared build-graph, CMake, and script changes, and rely on CI for aarch64-specific confirmation.

`gh` is available for driving CI, but a full CI run (both native architecture jobs) is expensive and slow. Do not dispatch the GitHub Actions workflow speculatively or to "see what happens." Only run `gh workflow run` once the local `x86_64-linux-musl` build and its full validation suite pass cleanly end-to-end and you are highly confident the same changes will succeed on CI (script/CMake logic is shared between local and CI, platform mappings are correct, no host-only paths or assumptions were introduced). Treat a CI dispatch as the last action of this task: after triggering it, stop — do not poll, watch logs, or wait for it to finish.

## 1. End state and scope

Target exactly **LLVM 23.1.2**, not an RC, a moving branch, or a newer release substituted opportunistically. Make this a clean LLVM 23-only build: retire LLVM 22 compatibility machinery while retaining useful regression inputs and brief upstream provenance.

The intended build graph is:

```text
Alpine's packaged Clang + LLD
              |
              v
Build patched LLVM/Clang 23.1.2 tools ONCE
              |
              v
Build compiler-rt builtins and C++ runtimes with that new Clang
              |
              v
Install selected components -> validate installed package -> package/release
```

Remove the standalone host-tools build and the full Clang self-bootstrap. Building TableGen executables as ordinary dependencies, or building Clang/LLD before runtime configuration, does not constitute a second compiler build. Do not retain the old architecture as a permanent optional mode, add a general bootstrap framework, or introduce PGO/BOLT/LTO optimization of LLVM itself in this change.

Use LLVM's supported native build and runtime machinery. Prefer `LLVM_ENABLE_RUNTIMES` to build runtimes with the newly built compiler. A small explicit runtime sub-build using that compiler is acceptable if it materially simplifies a real LLVM 23.1.2 limitation; document the reason. It must not rebuild LLVM/Clang.

Self-bootstrap can be useful for release-compiler code generation, but is not required merely to produce musl-linked tools. Preserve this distinction in the documentation rather than claiming bootstrap is universally pointless.

## 2. Preserve the artifact contract

Produce both `x86_64-linux-musl` and `aarch64-linux-musl` packages. Each compiler retains the X86 and AArch64 backends; each package supplies runtimes for its own architecture, not an invented cross-sysroot.

Keep the existing intended tool selection and layout: Clang and its aliases/configuration, LLD, the selected LLVM binary utilities, `libclang.so` and C API headers, `libLTO.so`, Clang resource headers, compiler-rt builtins, libc++ headers including generated configuration headers, and static libc++/libc++abi/libunwind archives. Compare the actual distribution before and after; avoid accidentally dropping installed aliases or existing runtime components.

Preserve these properties:

- Shipped tools and shared libraries are musl-linked, with no external dynamic dependency beyond musl. Preserve static zlib support and do not introduce `libstdc++.so`, `libgcc_s.so`, shared libunwind/libc++, glibc, or `libz.so` dependencies.
- Downstream Clang defaults remain libc++, compiler-rt, libunwind, and the bundled LLD. Keep documented explicit sysroot/header/library flags working; do not silently require new build-machine paths or environment variables.
- Musl itself, a target sysroot, sanitizers, shared C++ runtimes, clang-tools-extra, LLVM development exports, and unrelated projects remain outside the package.

**Compiler implementation linkage and downstream runtime defaults are different layers.** Statically embedding the host libstdc++/libgcc in the compiler tools is acceptable and matches the current practical contract. “No dynamic GNU-runtime dependency” does not mean “no GNU code.” Do not expand this task into removing every statically linked GNU component.

Preserve the effective optimization settings of the previously shipped compiler, not merely the temporary stage-1 flags. Keep the existing configurable link-concurrency limit. Do not silently introduce `-march=native`, a higher CPU baseline, or a size/performance tradeoff unrelated to removing bootstrap.

## 3. First checkpoint: upgrade without changing the build architecture

Make the version upgrade a separate logical commit from the build simplification. Initially keep the existing bootstrap so failures can be attributed to the version change independently.

Verify the upstream `llvmorg-23.1.2` release and source archive. Pin and verify the source checksum using upstream release metadata; use the same verification for fresh and cached downloads. Do not mark partially downloaded or extracted sources complete.

Centralize the default version in one small source of truth used by local builds, CI, source URLs, artifact names, and release tags. Do not introduce a version-management framework. Update the separately hard-coded release version as well as the build version, remove stable-release use of `--prerelease`, and update active documentation examples. Preserve the archive naming convention `clang+llvm-<version>-<arch>-linux-musl.tar.xz` and checksum output.

### Patch decisions

Verify these findings against pristine 23.1.2 source rather than relying on patch filenames, changelog omissions, or failed patch application:

**Retain `0001-llvm23-dse-use-iterative-dominance-walk.patch`.** The reviewed tagged source still uses the recursive `VisitNode` traversal in `DSEState::eliminateRedundantStoresViaDominatingConditions()`. Its depth guard already existed in the implementation being patched; do not mistake that guard for a subsequent fix. Rebase only where necessary and preserve DFS order, condition-scope lifetime, sibling isolation, and the existing optimization depth limit.

**Remove `0002-llvm22-instcombine-recognize-non-negative-subtraction-patterns.patch`.** The non-negative `b - smin(b, a)` recognition is upstream. Verify `computeKnownBitsAddSub()` and the corresponding regression behavior. Provenance: LLVM commit `6f68daa42cab4884102a3688d4c13d732da6defd`.

**Remove `0003-llvm22-scev-limit-getrangeref-phi-recursion.patch`.** The relevant PHI-range recursion changes are upstream. Verify `RangeRefPHIAllowedOperands()` and its use in ScalarEvolution, together with the retained reproducer. Provenance: LLVM PR #152823, commit `7bc3bb0196d593d57ce5acbecd0b3c26e15b83a5`, issue #148253.

Keep useful regression inputs under `repros/`; retaining a historical filename does not imply continued LLVM 22 support. Remove now-dead major-version patch-selection branches and obsolete support instructions. Keep patch application small, deterministic, and repeatable: strict forward application to pristine sources, intentional recognition of an already-applied identical patch, and an actionable failure for incompatible sources. Retain content-sensitive patch-state checks; a stale marker must not hide a changed patch. Do not accept unexplained fuzzy application or silently skip failures.

Build and validate this upgraded baseline on the available native architecture before rewriting the build graph. Preserve its logs and artifact for comparison without checking generated data into Git. Exercise the existing downstream regression where available. Record honestly which architecture and integration checks have actually run.

## 4. Replace bootstrap with a single native compiler build

Remove the independent `llvm-host` tree, host-tools cache, exported host-tool paths, and copied host executables. Let LLVM build the native TableGen and other build-time tools it actually needs in its normal graph.

Remove `CLANG_ENABLE_BOOTSTRAP`, `BOOTSTRAP_*`, `CLANG_BOOTSTRAP_CMAKE_ARGS`, stage2 targets and directories, and helpers whose only purpose was coordinating those mechanisms. Move required final-stage settings into the real distribution configuration rather than dropping them with their former variable prefix.

Build LLVM/Clang/LLD with Alpine's packaged compiler and linker. Build compiler-rt builtins, libc++, libc++abi, and libunwind using the just-built Clang from the same pinned source. Ensure runtime configuration finds the intended linker. An explicit build of the current tree's `clang` and `lld` targets before configuring runtimes is fine; creating another compiler tree is not.

### Resolve runtime bootstrapping correctly

The shipped Clang's desired defaults may name runtimes that are not installed yet. Handle this through supported, narrowly scoped runtime-build settings and correct dependency ordering. Inspect the tagged runtime CMake files and verbose commands rather than guessing variable names or reviving old workaround comments.

Keep flags used to link the compiler tools distinct from flags used to build the bundled runtimes. Use `LLVM_STATIC_LINK_CXX_STDLIB` where suitable, with any required static GCC runtime linkage applied to executables and shared/module outputs as necessary. That option alone must not be assumed to prove the complete linkage contract.

Configure libc++/libc++abi/libunwind consistently. Diagnose actual include paths, link commands, and undefined symbols when a runtime check fails. Do not globally disable exception/unwind support, fabricate successful compiler probes, or rely on Alpine's development libraries being present in the final consumer environment.

Remove the pre-seeded compiler-working, atomics, and obsolete-host-toolchain results unless a specific remaining native-build failure justifies a narrowly documented exception. Static C++ runtime linkage does not itself justify pretending every compiler probe succeeded.

### Simplify CMake and installation

Use `LLVM_DISTRIBUTION_COMPONENTS` and supported runtime distribution components/install targets to install the intended package. Inspect LLVM 23.1.2's available targets; do not hard-code target names from a different release.

Replace recursive directory searches and manual copying of libc++ headers, `__config_site`, builtins, and runtime archives with their actual install rules wherever possible. Avoid building everything and then deleting unwanted output. Retain only a small, deterministic layout adjustment if required to preserve a real driver/consumer contract.

In particular, do not choose an arbitrary first archive from a build tree or mix headers and generated configuration from different builds. Ensure x86-64 builtins cannot be replaced by i386 builtins. Check the installed driver's resource/runtime lookup paths and actual links, not just filenames.

Retain only configuration exclusions that serve the intended distribution. Test tools may be built without being installed; disabling `opt` or FileCheck so aggressively that regression testing becomes impossible is not useful simplification.

Review the Dockerfile's hand-written futex header and pre-stripping of system objects. Prefer real packaged Linux UAPI headers and correct linker support. Remove obsolete workarounds when tests show they are unnecessary; do not substitute new fabricated system headers. Keep any genuinely necessary exception small and explained.

## 5. Unify local builds and CI

Keep a thin local entrypoint and a small number of scripts organized around genuine responsibilities, such as build and installed-package validation. The final implementation should be substantially simpler than the current shared stage runner plus stage wrappers. Do not replace it with a generic orchestration library or many tiny wrapper scripts.

Use the same build implementation in `make build` and GitHub Actions. Prefer one main build-container invocation with clear internal phases over repeated Docker invocations with duplicated mounts/environment. A separate clean validation container is intentional and should remain separate.

Use canonical platform mappings consistently:

```text
x86_64  -> linux/amd64
aarch64 -> linux/arm64
```

Normalize `arm64` to `aarch64` where appropriate. Derive the selected Docker platform from the requested build architecture, not unconditionally from the host's `uname`. Validate that the container architecture matches the requested artifact. Preserve native `ubuntu-24.04` and `ubuntu-24.04-arm` CI jobs unless an actual runner limitation requires a documented change.

Keep source and ccache caching; remove the dedicated host-tools cache. Invalidate obsolete build state for the architectural migration, and ensure cache keys distinguish architecture and relevant compiler/build inputs. Caches must not be necessary for correctness. Keep ccache statistics and failure-tolerant cache saving without duplicating the build definition.

Keep generated files in ignored working directories and make reruns reliable. Honor documented directory overrides without deleting user-owned source trees. Cleanup and test operations must be confined to known build or temporary directories; no host-wide cleanup, Docker pruning, or removal of unrelated caches.

Retain clear failure diagnostics and nonzero exit statuses. Replace fragile `find | head` patterns with deterministic paths or appropriate bounded searches instead of sprinkling `|| true` throughout the implementation.

Ensure CI can build and validate without publishing a release; a single dispatch boolean is enough if one is needed. Publish stable artifacts only after both native architecture jobs pass. Do not push changes or publish a release merely to test the workflow.

## 6. Strengthen meaningful integration validation

Preserve the useful existing tests, but do not preserve a magic test count or weak assertions. Prefer a few broad integration suites over shell-helper unit tests, command-string snapshots, or tests that only assert files exist.

### Installed artifact and relocation

Validate the installed package in a fresh container with no source/build-tree mounts and no host LLVM or C++ development stack available as fallback. Supply only the declared musl runtime/sysroot prerequisites, test infrastructure, and the package. Extract or stage the package at a different absolute prefix from its build/install location.

Exercise compiler/tool startup and downstream compilation there. Use explicit package tool paths and inspect driver commands so tests cannot accidentally use Alpine's Clang, LLD, or C++ libraries. Keep generated probe outputs inside isolated temporary directories.

### ELF and dependency contract

Inspect every shipped ELF executable and shared library, handling aliases appropriately. Check architecture, interpreter where applicable, `DT_NEEDED`, and inappropriate RPATH/RUNPATH entries. Use an explicit expected external dependency set for each architecture rather than accepting anything that merely does not mention glibc.

Do not classify a shared library as static just because it has no `PT_INTERP`. Do not label an unrecognized dependency set “musl-only.” Do not silently ignore inspection failures. Include `libclang.so` and `libLTO.so`, not just executables.

### Compiler, runtime, and tool behavior

Compile, link, and **run** representative C and C++ programs against the installed package. Cover libc++ facilities, C++ exceptions and unwinding through RAII cleanup, threads/TLS, and a nontrivial builtin operation. Test dynamic-musl and fully static downstream executables where supported by the supplied musl sysroot; this does not require changing the compiler tools themselves to fully static executables.

Verify the default C++/runtime/linker selection separately from tests that explicitly override those choices. Keep the documented explicit consumer invocation working as well. Exercise the chosen LLVM utilities, archive creation/indexing, debug-section zlib compression/decompression through an actual link or symbol lookup, and a small libclang C API client that parses a translation unit.

Add a real multi-translation-unit `-flto=thin` compile/link/run test using the installed compiler and linker, including a static musl case representative of the downstream usage. Check both compiled-in backends with small compile-only probes; do not expect a non-native sysroot to be bundled.

Native runtime failures are failures. The current validator can print a “cross-compiled or unsupported syscall” explanation and continue after an executable fails; remove that escape hatch from the native release-validation path. Capture diagnostics rather than redirecting important failures into `/dev/null`.

### Optimizer regressions

Run the retained InstCombine and ScalarEvolution regressions with the newly built version-matched `opt` and FileCheck where needed. Build those test executables in the existing tree without adding them to the release package. Enable only the testing support needed to run the selected regressions; do not require the entire LLVM test suite for every package build.

Add or retain a compact DSE regression that exercises deep dominator traversal and scoped conditions. Cover positive store elimination and a negative sibling-scope case to catch condition leakage. Prefer a reduced reproducer; a deterministic, bounded generated IR fixture is acceptable. Do not substitute “the patch contains a while loop” for behavioral testing.

Demonstrate the old failure against unpatched source when practical, and always run the patched behavioral tests. Apply any small-stack limit only to the isolated regression subprocess. A normal-stack test cannot be advertised as reproducing a musl worker-stack failure without evidence.

### Downstream Bun acceptance

Not required. In fact we should remove all docs here about bun acceptance.

## 7. Documentation, comparison, and completion

Update `README.md`, `AGENTS.md`, and `patches/README.md` to describe the implemented architecture, artifact contract, supported commands, and remaining patch. Remove obsolete stage diagrams, LLVM 22 support instructions, stale path references, and duplicate configuration explanations.

Correct the claims that LLVM CMake permits only two stages and that absence of dynamic GNU dependencies means absence of GNU runtime code. Remove contradictory historical explanations of runtime construction. Keep a brief current rationale, not a narrative of every failed experiment.

Compare the new 23.1.2 package with the upgraded bootstrap baseline: intended contents, linkage, test results, and package sizes. Record clean-build elapsed time and useful resource observations when available. Do not compare cached and uncached builds as if equivalent or claim compiler execution-speed equivalence merely because both pass tests. A small same-host representative C++ compile/ThinLTO timing comparison is useful when feasible; do not build a benchmark framework for this task.

Finish with the simplified implementation as the only supported build path. Run shell/workflow checks appropriate to the changed files, a clean native `x86_64-linux-musl` build and validation, and an incremental rerun, all locally. Once that passes and you are confident CI will succeed, dispatch the GitHub Actions workflow via `gh` and stop; do not wait for it to complete or poll its status. Distinguish completed local validation from a dispatched-but-unobserved CI run in your final report.
