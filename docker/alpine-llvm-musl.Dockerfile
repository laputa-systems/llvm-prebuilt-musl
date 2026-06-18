# Build for the target architecture matching the desired output.
# On x86_64 host:  docker build --platform linux/amd64 ...   (native)
# On aarch64 host: docker build --platform linux/arm64 ...   (native)
# Cross builds (e.g. aarch64 build on x86_64 host) need --platform + QEMU.

FROM alpine:3.23

RUN apk update && apk add --no-cache \
    bash \
    build-base \
    ccache \
    clang \
    cmake \
    curl \
    file \
    git \
    lld \
    ninja \
    python3 \
    tar \
    xz \
    zstd

# Alpine linux-headers omits some kernel UAPI headers that libcxx expects.
# Provide minimal stubs with just the constants libcxx needs.
RUN mkdir -p /usr/include/linux && \
    cat > /usr/include/linux/futex.h <<'EOF'
#ifndef _STUB_LINUX_FUTEX_H
#define _STUB_LINUX_FUTEX_H
#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_WAIT_PRIVATE 128
#define FUTEX_WAKE_PRIVATE 129
#endif
EOF

WORKDIR /work
