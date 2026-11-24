#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

CF_ASSUME_NONNULL_BEGIN

typedef bool (^DDBrightnessConnectionCheck)(void);

bool DDReadAppleBacklight(CGDirectDisplayID display, double *value);
bool DDWriteAppleBacklight(CGDirectDisplayID display, double requested,
                           DDBrightnessConnectionCheck connected, double *actual);
bool DDReadMonitorVCP(CGDirectDisplayID display, uint8_t feature,
                      DDBrightnessConnectionCheck connected, double *value);
bool DDWriteMonitorVCP(CGDirectDisplayID display, uint8_t feature, double requested,
                       DDBrightnessConnectionCheck connected, double *actual);

CFDataRef _Nullable DDCopyMatchedEDID(CGDirectDisplayID display) CF_RETURNS_RETAINED;

CFDataRef _Nullable DDCopyInputCapabilities(CGDirectDisplayID display, DDBrightnessConnectionCheck connected,
                                            uint16_t *current) CF_RETURNS_RETAINED;
bool DDRequestMonitorInput(CGDirectDisplayID display, uint16_t expectedCurrent, uint16_t selected,
                           DDBrightnessConnectionCheck connected);

CF_ASSUME_NONNULL_END
