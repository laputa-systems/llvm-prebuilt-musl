#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "repros/highway-bitsfrommask.cpp"
#include <hwy/foreach_target.h>
#include <hwy/highway.h>

#include <cstdint>

HWY_BEFORE_NAMESPACE();
namespace llvm_musl_repro {
namespace HWY_NAMESPACE {
namespace hn = hwy::HWY_NAMESPACE;

void BitsFromMaskRepro() {
  const hn::CappedTag<uint8_t, 64> d;
  const auto v = hn::Set(d, uint8_t{0});
  (void)hn::BitsFromMask(d, hn::Eq(v, v));
}

}
}
HWY_AFTER_NAMESPACE();
