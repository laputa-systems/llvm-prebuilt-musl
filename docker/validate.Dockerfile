# Clean consumer environment for validating a built package: the declared musl
# prerequisites (headers, startup objects, libc.a, dynamic loader) plus test
# tooling. Deliberately no compiler, linker, libstdc++, or libgcc, so nothing
# can silently fall back to the host.
FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    musl-dev \
    tar \
    xz
