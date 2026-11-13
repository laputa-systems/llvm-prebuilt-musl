# Clean consumer environment for validating a built package: musl's headers and
# dynamic loader plus test tooling. The startup objects and libc.a come from the
# package, and musl-dev's own GCC-built archives are there to prove the package's
# are the ones linked. Deliberately no compiler, linker, libstdc++, or libgcc, so
# nothing can silently fall back to the host. Alpine 3.24 carries musl 1.2.6, the
# release the bundled static libc is built from.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache \
    bash=5.3.9-r1 \
    musl-dev=1.2.6-r3 \
    tar=1.35-r5 \
    xz=5.8.4-r0
