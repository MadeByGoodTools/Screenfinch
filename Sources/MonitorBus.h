#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct DDMonitorBus DDMonitorBus;

DDMonitorBus *DDOpenMonitorBus(CGDirectDisplayID display);
void DDCloseMonitorBus(DDMonitorBus *bus);
bool DDMonitorBusMatches(DDMonitorBus *bus);
bool DDSendMonitorPacket(DDMonitorBus *bus, const uint8_t *bytes, size_t count);
size_t DDReadMonitorPacket(DDMonitorBus *bus, uint8_t *bytes, size_t capacity);
