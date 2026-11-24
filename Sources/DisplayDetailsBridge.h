#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

bool DDCanRotateDisplay(CGDirectDisplayID display);
bool DDRequestRotation(CGDirectDisplayID display, int32_t degrees);
