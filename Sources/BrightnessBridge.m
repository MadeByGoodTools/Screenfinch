#import "BrightnessBridge.h"
#import <Foundation/Foundation.h>
#import "MonitorBus.h"
#import <dlfcn.h>
#import <math.h>
#import <unistd.h>
#import <time.h>

typedef int (*AppleLightGetter)(CGDirectDisplayID, float *);
typedef int (*AppleLightSetter)(CGDirectDisplayID, float);

static AppleLightGetter getAppleLight;
static AppleLightSetter setAppleLight;

static void loadAppleLightControls(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                               RTLD_LOCAL | RTLD_LAZY);
        if (library) {
            getAppleLight = dlsym(library, "DisplayServicesGetBrightness");
            setAppleLight = dlsym(library, "DisplayServicesSetBrightness");
        }
    });
}

bool DDReadAppleBacklight(CGDirectDisplayID display, double *value) {
    if (!CGDisplayIsOnline(display) ||
        (!CGDisplayIsBuiltin(display) && CGDisplayVendorNumber(display) != 0x0610)) {
        return false;
    }
    loadAppleLightControls();
    float level = NAN;
    if (!getAppleLight || !setAppleLight || getAppleLight(display, &level) != 0 ||
        !isfinite(level) || level < 0 || level > 1) {
        return false;
    }
    *value = level;
    return true;
}

bool DDWriteAppleBacklight(CGDirectDisplayID display, double requested,
                           DDBrightnessConnectionCheck connected, double *actual) {
    if (!isfinite(requested) || requested < 0 || requested > 1 || !connected() ||
        !DDReadAppleBacklight(display, actual)) {
        return false;
    }
    if (fabs(*actual - requested) < 0.0001) {
        return true;
    }
    if (!connected() || setAppleLight(display, (float)requested) != 0) {
        return false;
    }
    for (int attempt = 0; attempt < 3 && connected(); attempt++) {
        if (attempt) usleep(45000);
        if (DDReadAppleBacklight(display, actual) && fabs(*actual - requested) <= 0.02) return true;
    }
    return false;
}

static const uint32_t monitorAddress = 0x37;
static const uint32_t hostAddress = 0x51;

static uint8_t packetChecksum(uint8_t seed, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) seed ^= bytes[i];
    return seed;
}

typedef struct {
    uint16_t value, maximum;
} VCPReading;

typedef struct {
    uint16_t value, maximum;
    bool specialVolume;
} MonitorLevel;

static bool supportedControl(uint8_t feature) {
    return feature == 0x10 || feature == 0x12 || feature == 0x62;
}

static bool queryFeature(DDMonitorBus *service, uint8_t feature, DDBrightnessConnectionCheck connected,
                         VCPReading *level) {
    uint8_t query[] = {0x82, 0x01, feature, 0};
    query[3] = packetChecksum((uint8_t)((monitorAddress << 1) ^ hostAddress), query, 3);
    for (int attempt = 0; attempt < 2 && connected(); attempt++) {
        if (!DDSendMonitorPacket(service, query, sizeof(query))) {
            continue;
        }
        usleep(attempt == 0 ? 60000 : 110000);
        uint8_t bytes[11] = {0};
        if (!connected()) return false;
        if (DDReadMonitorPacket(service, bytes, sizeof(bytes)) != sizeof(bytes) ||
            bytes[0] != 0x6e || bytes[1] != 0x88 || bytes[2] != 0x02 || bytes[4] != feature ||
            packetChecksum(0x50, bytes, sizeof(bytes)) != 0) {
            continue;
        }
        if (bytes[3] != 0 || bytes[5] != 0) return false;
        level->maximum = (uint16_t)bytes[6] << 8 | bytes[7];
        level->value = (uint16_t)bytes[8] << 8 | bytes[9];
        return true;
    }
    return false;
}

static bool getMonitorLevel(DDMonitorBus *service, uint8_t feature, DDBrightnessConnectionCheck connected,
                            MonitorLevel *level) {
    VCPReading raw;
    if (!queryFeature(service, feature, connected, &raw)) return false;
    *level = (MonitorLevel){.value = raw.value, .maximum = raw.maximum};

    // In MCCS 2.2 and 3.x, 0x00 is a fixed default and 0xff means mute.
    // With no readable numeric level, a slider would imply a made-up position.
    if (feature == 0x62) {
        VCPReading version;
        if (!queryFeature(service, 0xdf, connected, &version)) return false;
        uint16_t major = version.value >> 8;
        if (major < 2 || major > 3) return false;
        if (version.value >= 0x0202) {
            if (raw.value == 0 || raw.value > 0xff) return false;
            level->specialVolume = true;
            level->value = raw.value == 0xff ? 0 : raw.value;
            level->maximum = raw.maximum > 0 && raw.maximum < 0xff ? raw.maximum : 0xfe;
        }
    }
    return level->maximum > 0 && level->value <= level->maximum;
}

bool DDReadMonitorVCP(CGDirectDisplayID display, uint8_t feature,
                      DDBrightnessConnectionCheck connected, double *value) {
    if (!supportedControl(feature) || !connected()) return false;
    DDMonitorBus *service = DDOpenMonitorBus(display);
    if (!service) return false;
    MonitorLevel level;
    bool read = getMonitorLevel(service, feature, connected, &level);
    if (read) *value = (double)level.value / level.maximum;
    DDCloseMonitorBus(service);
    return read;
}

static bool sendFeature(DDMonitorBus *bus, uint8_t feature, uint16_t wireValue) {
    uint8_t frame[] = {0x84, 0x03, feature, (uint8_t)(wireValue >> 8), (uint8_t)wireValue, 0};
    frame[5] = packetChecksum((uint8_t)((monitorAddress << 1) ^ hostAddress), frame, 5);
    return DDSendMonitorPacket(bus, frame, sizeof(frame));
}

bool DDWriteMonitorVCP(CGDirectDisplayID display, uint8_t feature, double requested,
                       DDBrightnessConnectionCheck connected, double *actual) {
    if (!supportedControl(feature) || !isfinite(requested) || requested < 0 || requested > 1 || !connected()) return false;
    DDMonitorBus *service = DDOpenMonitorBus(display);
    if (!service) return false;

    MonitorLevel before, after;
    bool success = false;
    if (getMonitorLevel(service, feature, connected, &before)) {
        uint16_t target = (uint16_t)lround(requested * before.maximum);
        if (before.specialVolume && requested > 0 && target == 0) target = 1;
        if (target == before.value) {
            *actual = (double)before.value / before.maximum;
            success = true;
        } else if (connected() && DDMonitorBusMatches(service)) {
            uint16_t wireValue = before.specialVolume && target == 0 ? 0xff : target;
            if (connected() && sendFeature(service, feature, wireValue)) {
                usleep(65000);
                if (getMonitorLevel(service, feature, connected, &after)) {
                    *actual = (double)after.value / after.maximum;
                    success = abs((int)after.value - (int)lround(requested * after.maximum)) <= 1;
                }
            }
        }
    }

    DDCloseMonitorBus(service);
    return success;
}

// VESA DDC/CI capabilities are a series of at most 32 ASCII bytes per reply.
// Validate the echoed offset, payload length and checksum before appending data.
static int getCapabilityChunk(DDMonitorBus *bus, uint16_t offset, DDBrightnessConnectionCheck connected,
                              uint8_t *chunk) {
    uint8_t query[] = {0x83, 0xf3, (uint8_t)(offset >> 8), (uint8_t)offset, 0};
    query[4] = packetChecksum((uint8_t)((monitorAddress << 1) ^ hostAddress), query, 4);
    for (int attempt = 0; attempt < 2 && connected(); attempt++) {
        if (!DDSendMonitorPacket(bus, query, sizeof(query))) continue;
        usleep(attempt == 0 ? 65000 : 120000);
        if (!connected()) return -1;
        uint8_t reply[38] = {0};
        size_t received = DDReadMonitorPacket(bus, reply, sizeof(reply));
        size_t payload = reply[1] & 0x7f;
        if (received < 6 || reply[0] != 0x6e || !(reply[1] & 0x80) || payload < 3 || payload > 35 ||
            received < payload + 3 || reply[2] != 0xe3 || reply[3] != query[2] || reply[4] != query[3] ||
            packetChecksum(0x50, reply, payload + 3) != 0) continue;
        size_t length = payload - 3;
        memcpy(chunk, reply + 5, length);
        return (int)length;
    }
    return -1;
}

static CFDataRef copyCapabilities(DDMonitorBus *bus, DDBrightnessConnectionCheck connected) {
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    if (!data) return NULL;
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 8 * NSEC_PER_SEC;
    while (connected() && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline) {
        size_t offset = (size_t)CFDataGetLength(data);
        uint8_t chunk[32] = {0};
        int length = getCapabilityChunk(bus, (uint16_t)offset, connected, chunk);
        if (length == 0) return data;
        if (length < 0 || offset + (size_t)length > 4096) break;
        uint8_t *terminator = memchr(chunk, 0, (size_t)length);
        if (terminator) {
            // A few monitors end the last fragment with NUL padding.
            for (uint8_t *p = terminator; p < chunk + length; p++) {
                if (*p) { CFRelease(data); return NULL; }
            }
            CFDataAppendBytes(data, chunk, terminator - chunk);
            return data;
        }
        CFDataAppendBytes(data, chunk, length);
    }
    CFRelease(data);
    return NULL;
}

CFDataRef DDCopyInputCapabilities(CGDirectDisplayID display, DDBrightnessConnectionCheck connected,
                                  uint16_t *current) {
    if (!connected()) return NULL;
    DDMonitorBus *bus = DDOpenMonitorBus(display);
    if (!bus) return NULL;
    CFDataRef data = NULL;
    VCPReading source, version;
    // MCCS 3.0 models 0x60 as a table. This picker implements scalar sources.
    if (queryFeature(bus, 0x60, connected, &source) && source.value > 0 && source.value <= 0xff &&
        queryFeature(bus, 0xdf, connected, &version) && (version.value >> 8) == 2) {
        data = copyCapabilities(bus, connected);
        *current = source.value;
    }
    DDCloseMonitorBus(bus);
    return data;
}

bool DDRequestMonitorInput(CGDirectDisplayID display, uint16_t expectedCurrent, uint16_t selected,
                           DDBrightnessConnectionCheck connected) {
    if (!selected || selected > 0xff || !connected()) return false;
    DDMonitorBus *bus = DDOpenMonitorBus(display);
    if (!bus) return false;
    VCPReading source;
    bool sent = false;
    if (queryFeature(bus, 0x60, connected, &source) && source.value == expectedCurrent) {
        // Check identity immediately before the handoff. A successful change can
        // disconnect this Mac's DDC path, so the command must never be retried.
        sent = source.value == selected ||
               (DDMonitorBusMatches(bus) && connected() && sendFeature(bus, 0x60, selected));
    }
    DDCloseMonitorBus(bus);
    return sent;
}
