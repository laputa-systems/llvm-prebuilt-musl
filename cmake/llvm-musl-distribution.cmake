# ── Host tool paths (set by build script env vars) ──────────────────
if(DEFINED ENV{LLVM_NATIVE_TOOL_DIR})
    set(LLVM_NATIVE_TOOL_DIR $ENV{LLVM_NATIVE_TOOL_DIR} CACHE FILEPATH "")
    message(STATUS "LLVM_NATIVE_TOOL_DIR: ${LLVM_NATIVE_TOOL_DIR}")
endif()
if(DEFINED ENV{CLANG_TABLEGEN})
    set(CLANG_TABLEGEN $ENV{CLANG_TABLEGEN} CACHE FILEPATH "")
endif()
if(DEFINED ENV{LLVM_TABLEGEN})
    set(LLVM_TABLEGEN $ENV{LLVM_TABLEGEN} CACHE FILEPATH "")
endif()
if(DEFINED ENV{LLVM_CONFIG_PATH})
    set(LLVM_CONFIG_PATH $ENV{LLVM_CONFIG_PATH} CACHE FILEPATH "")
endif()
if(DEFINED ENV{LLVM_VERSION})
    set(LLVM_VERSION $ENV{LLVM_VERSION} CACHE FILEPATH "")
endif()
if(DEFINED ENV{CMAKE_INSTALL_PREFIX})
    set(CMAKE_INSTALL_PREFIX $ENV{CMAKE_INSTALL_PREFIX} CACHE FILEPATH "")
endif()

# ── Build configuration ──────────────────────────────────────────────
set(CMAKE_BUILD_TYPE Release CACHE STRING "")
set(LLVM_ENABLE_ASSERTIONS OFF CACHE BOOL "")
set(LLVM_INCLUDE_DOCS OFF CACHE BOOL "")
set(LLVM_INCLUDE_TESTS OFF CACHE BOOL "")
set(LLVM_INCLUDE_BENCHMARKS OFF CACHE BOOL "")
set(LLVM_INCLUDE_EXAMPLES OFF CACHE BOOL "")
set(LLVM_INCLUDE_GO_TESTS OFF CACHE BOOL "")
set(LLVM_INCLUDE_UTILS OFF CACHE BOOL "" FORCE)
set(LLVM_BUILD_UTILS OFF CACHE BOOL "")
set(LLVM_INSTALL_UTILS OFF CACHE BOOL "")

# ── Target backends: only what Laputa targets ────────────────────────
set(LLVM_TARGETS_TO_BUILD "X86;AArch64" CACHE STRING "" FORCE)

# ── Projects: no clang-tools-extra ───────────────────────────────────
set(LLVM_ENABLE_PROJECTS "clang;lld" CACHE STRING "" FORCE)

# ── Disable optional dependencies ────────────────────────────────────
set(LLVM_ENABLE_LIBXML2 OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_ZLIB OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_ZSTD OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_TERMINFO OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_BACKTRACES OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_UNWIND_TABLES OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_EH OFF CACHE BOOL "" FORCE)
set(LLVM_ENABLE_RTTI OFF CACHE BOOL "" FORCE)

# ── Runtimes: compiler-rt builtins + libc++ + libcxxabi ──────────────
# libc++/libcxxabi are LLVM code, not GNU — building them in stage1 is fine.
set(LLVM_ENABLE_RUNTIMES "compiler-rt;libcxx;libcxxabi;libunwind" CACHE STRING "" FORCE)
set(COMPILER_RT_BUILD_BUILTINS ON CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_SANITIZERS OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_XRAY OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_LIBFUZZER OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_PROFILE OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_MEMPROF OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_ORC OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_GWP_ASAN OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_CTX_PROFILE OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_XRAY_NO_PREINIT OFF CACHE BOOL "" FORCE)
set(COMPILER_RT_BUILD_SCUDO_STANDALONE_WITH_LLVM_LIBC OFF CACHE BOOL "" FORCE)

# ── Distribution: tools only, no development libs/headers/exports ────
set(LLVM_DISTRIBUTION_COMPONENTS
    clang
    clang-resource-headers
    lld
    LTO
    llvm-ar
    llvm-nm
    llvm-objcopy
    llvm-objdump
    llvm-ranlib
    llvm-readelf
    llvm-readobj
    llvm-size
    llvm-strings
    llvm-strip
    llvm-symbolizer
    CACHE STRING "" FORCE)

set(LLVM_UNUSED_TOOL_DIRS
    bugpoint
    bugpoint-passes
    dsymutil
    dxil-dis
    gold
    llc
    lli
    llvm-as
    llvm-as-fuzzer
    llvm-bcanalyzer
    llvm-c-test
    llvm-cas
    llvm-cat
    llvm-cfi-verify
    llvm-cgdata
    llvm-cov
    llvm-ctxprof-util
    llvm-cvtres
    llvm-cxxdump
    llvm-cxxfilt
    llvm-cxxmap
    llvm-debuginfo-analyzer
    llvm-debuginfod
    llvm-debuginfod-find
    llvm-diff
    llvm-dis
    llvm-dis-fuzzer
    llvm-dlang-demangle-fuzzer
    llvm-driver
    llvm-dwarfdump
    llvm-dwarfutil
    llvm-dwp
    llvm-exegesis
    llvm-extract
    llvm-gpu-loader
    llvm-gsymutil
    llvm-ifs
    llvm-ir2vec
    llvm-isel-fuzzer
    llvm-itanium-demangle-fuzzer
    llvm-jitlink
    llvm-jitlistener
    llvm-libtool-darwin
    llvm-link
    llvm-lipo
    llvm-lto
    llvm-lto2
    llvm-mc
    llvm-mc-assemble-fuzzer
    llvm-mc-disassemble-fuzzer
    llvm-mca
    llvm-microsoft-demangle-fuzzer
    llvm-ml
    llvm-modextract
    llvm-mt
    llvm-offload-binary
    llvm-offload-wrapper
    llvm-opt-fuzzer
    llvm-opt-report
    llvm-pdbutil
    llvm-profdata
    llvm-profgen
    llvm-rc
    llvm-readtapi
    llvm-reduce
    llvm-remarkutil
    llvm-rtdyld
    llvm-rust-demangle-fuzzer
    llvm-shlib
    llvm-sim
    llvm-special-case-list-fuzzer
    llvm-split
    llvm-stress
    llvm-tli-checker
    llvm-undname
    llvm-xray
    llvm-yaml-numeric-parser-fuzzer
    llvm-yaml-parser-fuzzer
    obj2yaml
    opt
    opt-viewer
    reduce-chunk-list
    remarks-shlib
    sancov
    sanstats
    spirv-tools
    verify-uselistorder
    vfabi-demangle-fuzzer
    xcode-toolchain
    yaml2obj)

foreach(tool IN LISTS LLVM_UNUSED_TOOL_DIRS)
    string(REPLACE "-" "_" tool_var "${tool}")
    string(TOUPPER "${tool_var}" tool_var)
    set("LLVM_TOOL_${tool_var}_BUILD" OFF CACHE BOOL "" FORCE)
endforeach()

# ── libc++ / libcxxabi / libunwind: static only ──────────────────────
set(LIBCXX_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(LIBCXX_ENABLE_STATIC ON CACHE BOOL "" FORCE)
set(LIBCXX_HAS_MUSL_LIBC ON CACHE BOOL "" FORCE)
set(LIBCXXABI_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(LIBCXXABI_ENABLE_STATIC ON CACHE BOOL "" FORCE)
set(LIBUNWIND_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(LIBUNWIND_ENABLE_STATIC ON CACHE BOOL "" FORCE)
