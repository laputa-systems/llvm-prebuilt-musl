#include "lto_text.h"

#include <string>

std::string describe(int v) {
    return "value=" + std::to_string(v) + (v % 2 == 0 ? " (even)" : " (odd)");
}
