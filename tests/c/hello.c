#include <stdio.h>

/* 128-bit division and quad-precision long double are not ISA operations on
   these targets; they are calls into compiler-rt builtins (__udivti3,
   __umodti3, and on aarch64 __divtf3), since musl has no libgcc. Volatile
   inputs keep the compiler from folding them away. */
int main(void) {
    volatile unsigned __int128 num =
        ((unsigned __int128)0x0123456789abcdefULL << 64) | 0xfedcba9876543210ULL;
    volatile unsigned __int128 den = 0x1000000007ULL;
    unsigned __int128 q = num / den;
    unsigned __int128 r = num % den;
    volatile long double one = 1.0L, three = 3.0L;
    long double third = one / three;

    printf("hello from C\n");
    printf("q=%016llx%016llx r=%llx\n", (unsigned long long)(q >> 64),
           (unsigned long long)q, (unsigned long long)r);
    printf("third=%.15Lf\n", third);
    return 0;
}
