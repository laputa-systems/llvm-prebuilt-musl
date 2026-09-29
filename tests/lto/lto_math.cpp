#include "lto_math.h"

// Small and externally visible: ThinLTO imports and inlines it into main.
int scale_and_offset(int x) { return x * 37 + 11; }
