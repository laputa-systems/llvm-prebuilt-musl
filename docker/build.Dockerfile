# Build environment for the LLVM/Clang toolchain. Alpine's packaged clang, lld,
# and libstdc++ are build inputs only: the shipped tools embed what they need
# and depend on musl alone. The image is architecture-specific; `make` selects
# the matching --platform.
FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    build-base \
    ccache \
    clang \
    cmake \
    linux-headers \
    lld \
    ninja \
    patch \
    python3 \
    tar \
    xz \
    zlib-dev \
    zlib-static

WORKDIR /work
