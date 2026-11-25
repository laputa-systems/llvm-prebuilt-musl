# Build environment for the LLVM/Clang toolchain. Alpine's packaged clang, lld,
# and libstdc++ are build inputs only: the shipped tools embed what they need
# and depend on musl alone. The image is architecture-specific; `make` selects
# the matching --platform.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
COPY --from=oci.17166969.xyz/owned-tools@sha256:aaec19e7a44cbc53b40db2d22093600ee888689b89be94da90e5398ed02f1883 /opt/laputa /opt/laputa
ENV PATH=$PATH:/opt/laputa/bin

RUN apk add --no-cache \
    bash=5.3.9-r1 \
    build-base=0.5-r4 \
    ccache=4.13.6-r0 \
    clang22=22.1.3-r2 \
    linux-headers=7.0.0-r1 \
    lld22=22.1.3-r0 \
    ninja-is-really-ninja=1.13.2-r1 \
    patch=2.8.1-r0 \
    python3=3.14.10-r2 \
    tar=1.35-r5 \
    xz=5.8.4-r0 \
    zlib-dev=1.4-r0 \
    zlib-static=1.4-r0

WORKDIR /work
