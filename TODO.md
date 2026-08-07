# TODO

## LLVM 22 + Highway scalable SVE `BitsFromMask`

On an Alpine `aarch64` build with the LLVM 22.1.8 musl artifact, this minimal
Highway translation unit fails when the vendored Highway snapshot is compiled
for the scalable `N_SVE` and `N_SVE2` targets:

```sh
clang++ -std=c++17 \
  -I. \
  -I/path/to/bun/vendor/highway \
  -c repros/highway-bitsfrommask.cpp -o /tmp/highway-bitsfrommask.o
```

The diagnostic is:

```text
error: no member named 'BitsFromMask' in namespace 'hwy::N_SVE'
error: no member named 'BitsFromMask' in namespace 'hwy::N_SVE2'
```

The current downstream workaround is:

```sh
clang++ -std=c++17 \
  -DHWY_BROKEN_SVE=HWY_SVE \
  -DHWY_BROKEN_SVE2=HWY_SVE2 \
  -I. \
  -I/path/to/bun/vendor/highway \
  -c repros/highway-bitsfrommask.cpp -o /tmp/highway-bitsfrommask.o
```

TODO: determine whether the LLVM 22 prebuilt should expose a compatibility
configuration for this Highway snapshot, or whether Highway should be updated
to implement `BitsFromMask` for scalable SVE and SVE2. Keep the fixed-width
SVE targets enabled; only the scalable targets are currently disabled.
