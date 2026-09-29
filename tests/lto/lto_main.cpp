#include <iostream>

#include "lto_math.h"
#include "lto_text.h"

int main(int argc, char **) {
    // argc keeps the call from being folded before the cross-module inliner sees it.
    std::cout << describe(scale_and_offset(argc + 4)) << '\n';
    return 0;
}
