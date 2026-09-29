# Initial CMake cache for the release toolchain (`cmake -C`).
#
# One LLVM build tree builds clang, lld, and the LLVM utilities with the host
# (Alpine) compiler. The runtimes -- compiler-rt builtins, libc++, libc++abi,
# libunwind -- are built by the same tree with the clang it just produced.
# Settings that depend on the environment (compilers, target triple, install
# prefix, ccache) are passed by scripts/build.sh, not set here.

# -- Build configuration -------------------------------------------------------
# Release without overriding the flags: the compiler tools are built with
# LLVM's default "-O3 -DNDEBUG".
set(CMAKE_BUILD_TYPE Release CACHE STRING "")
# Alpine's packaged clang hardens by default: stack protection, stack-clash
# probes, and _FORTIFY_SOURCE=2 (which routes memory and string calls through
# fortify-headers). Upstream's driver, and so the bootstrap-built compiler this
# package used to ship, does none of that. Keep the tools' code generation
# independent of the build image's distro patches. These flags apply to the LLVM
# tools only: the runtimes are separate CMake projects built by the new clang and
# do not inherit them.
set(CMAKE_C_FLAGS "-fno-stack-protector -fno-stack-clash-protection -U_FORTIFY_SOURCE" CACHE STRING "")
set(CMAKE_CXX_FLAGS "-fno-stack-protector -fno-stack-clash-protection -U_FORTIFY_SOURCE" CACHE STRING "")

# -- Compiler tools ------------------------------------------------------------
# Both backends in every package; the runtimes are for the package's own arch.
set(LLVM_TARGETS_TO_BUILD "X86;AArch64" CACHE STRING "")
set(LLVM_ENABLE_PROJECTS "clang;lld" CACHE STRING "")
set(LLVM_ENABLE_LLD ON CACHE BOOL "")
set(LLVM_ENABLE_LIBXML2 OFF CACHE BOOL "")
set(LLVM_ENABLE_ZSTD OFF CACHE BOOL "")
set(LLVM_ENABLE_TERMINFO OFF CACHE BOOL "")
set(LLVM_ENABLE_BACKTRACES OFF CACHE BOOL "")
set(LLVM_ENABLE_UNWIND_TABLES OFF CACHE BOOL "")
set(LLVM_ENABLE_EH OFF CACHE BOOL "")
set(LLVM_ENABLE_RTTI OFF CACHE BOOL "")

# zlib is linked statically so the tools need no libz.so at run time.
set(LLVM_ENABLE_ZLIB ON CACHE BOOL "")
set(ZLIB_USE_STATIC_LIBS ON CACHE BOOL "")
set(ZLIB_LIBRARY /usr/lib/libz.a CACHE FILEPATH "")
set(ZLIB_LIBRARY_RELEASE /usr/lib/libz.a CACHE FILEPATH "")
set(ZLIB_LIBRARY_DEBUG /usr/lib/libz.a CACHE FILEPATH "")

# The tools embed the host libstdc++ and libgcc instead of depending on them.
# LLVM_STATIC_LINK_CXX_STDLIB supplies -static-libstdc++; -static-libgcc has no
# LLVM option. These flags apply to the LLVM tools only: the runtimes below are
# separate CMake projects and do not inherit them.
set(LLVM_STATIC_LINK_CXX_STDLIB ON CACHE BOOL "")
set(CMAKE_EXE_LINKER_FLAGS "-static-libgcc" CACHE STRING "")
set(CMAKE_SHARED_LINKER_FLAGS "-static-libgcc" CACHE STRING "")
set(CMAKE_MODULE_LINKER_FLAGS "-static-libgcc" CACHE STRING "")

# Downstream defaults of the shipped compiler.
set(CLANG_DEFAULT_CXX_STDLIB libc++ CACHE STRING "")
set(CLANG_DEFAULT_RTLIB compiler-rt CACHE STRING "")
set(CLANG_DEFAULT_UNWINDLIB libunwind CACHE STRING "")

# -- Runtimes (built with the just-built clang) --------------------------------
set(LLVM_ENABLE_RUNTIMES "compiler-rt;libcxx;libcxxabi;libunwind" CACHE STRING "")
# Flat lib/ and include/c++/v1 layout (no per-target subdirectories), so
# __config_site and the archives do not depend on the consumer's triple spelling.
set(LLVM_ENABLE_PER_TARGET_RUNTIME_DIR OFF CACHE BOOL "")

# compiler-rt: builtins only, for the package's own architecture.
set(COMPILER_RT_DEFAULT_TARGET_ONLY ON CACHE BOOL "")
set(COMPILER_RT_BUILD_SANITIZERS OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_XRAY OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_LIBFUZZER OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_PROFILE OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_MEMPROF OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_ORC OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_GWP_ASAN OFF CACHE BOOL "")
set(COMPILER_RT_BUILD_CTX_PROFILE OFF CACHE BOOL "")

# libc++, libc++abi, libunwind: static archives only, musl flavor.
set(LIBCXX_HAS_MUSL_LIBC ON CACHE BOOL "")
set(LIBCXX_ENABLE_SHARED OFF CACHE BOOL "")
set(LIBCXX_ENABLE_STATIC ON CACHE BOOL "")
set(LIBCXXABI_ENABLE_SHARED OFF CACHE BOOL "")
set(LIBCXXABI_ENABLE_STATIC ON CACHE BOOL "")
set(LIBUNWIND_ENABLE_SHARED OFF CACHE BOOL "")
set(LIBUNWIND_ENABLE_STATIC ON CACHE BOOL "")
# The driver's default C++ link is "-lc++ ... -lunwind": have libc++.a carry the
# libc++abi objects so that is a complete link. libc++abi.a and libunwind.a are
# still shipped for explicit links.
set(LIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY ON CACHE BOOL "")
# Keep the package contents to libc++ headers and the archives: no C++ module
# sources (share/), no libunwind headers.
set(LIBCXX_INSTALL_MODULES OFF CACHE BOOL "")
set(LIBUNWIND_INSTALL_HEADERS OFF CACHE BOOL "")

# -- Distribution --------------------------------------------------------------
# `install-distribution` installs exactly these components, nothing else. The
# runtime components (builtins, cxx, cxxabi, unwind) are top-level install
# targets that forward to the runtimes sub-builds; `install-cxx` and
# `install-cxxabi` include their headers.
set(LLVM_DISTRIBUTION_COMPONENTS
    clang
    clang-resource-headers
    libclang
    libclang-headers
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
    builtins
    cxx
    cxxabi
    unwind
    CACHE STRING "")
