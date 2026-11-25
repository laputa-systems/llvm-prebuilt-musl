Prefix: LLVM
Next: 2

# Open work

### LLVM-1 · P2 · libunwind embeds build paths and crtbegin imports frame registration, failing consumer linkage audits

- **Area:** runtimes, reproducibility
- **Where:** cmake/llvm-musl-distribution.cmake (LIBUNWIND_* and compiler-rt crt settings); the libunwind.a and clang_rt.crtbegin-*.o the release ships
- **Problem:** joshuarli/play's `scripts/audit-linux.sh` rejects binaries linked by the owned clang (branch build/owned-clang): `no build paths: /work/src/libunwind/src/DwarfInstructions.hpp /work/src/libunwind/src/DwarfParser.hpp`, because libunwind is built without a prefix map, and `no GNU runtime imports: __deregister_frame_info __register_frame_info`, because the compiler-rt crtbegin objects reference frame registration weakly (confirmed with llvm-nm on clang_rt.crtbegin-x86_64.o), so every dynamically linked binary imports those symbols. This blocks play's move off Alpine build-base (stuff OT7).
- **Recommendation:** Build the runtimes with `-ffile-prefix-map=<source>=.` (and the equivalent debug prefix map), and set `COMPILER_RT_CRT_USE_EH_FRAME_REGISTRY=OFF` for the crt objects; release, bump the owned-tools image digest, and rerun play's `make linux` audit.
- **Fix with:** root-cause
- **Effort:** M
