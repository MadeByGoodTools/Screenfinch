#import "MonitorBus.h"
#import "BrightnessBridge.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#if !defined(__arm64__)
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/i2c/IOI2CInterface.h>
#endif

typedef struct {
    uint32_t vendor, product, serial;
} MonitorIdentity;

struct DDMonitorBus {
    CGDirectDisplayID display;
    MonitorIdentity identity;
#if defined(__arm64__)
    CFTypeRef service;
#else
    IOI2CConnectRef connection;
    IOOptionBits replyType;
#endif
};

static MonitorIdentity identityOf(CGDirectDisplayID display) {
    return (MonitorIdentity){CGDisplayVendorNumber(display), CGDisplayModelNumber(display),
                             CGDisplaySerialNumber(display)};
}

static bool sameIdentity(MonitorIdentity a, MonitorIdentity b) {
    return a.vendor == b.vendor && a.product == b.product && a.serial == b.serial;
}

static bool isUniqueOnline(CGDirectDisplayID display, MonitorIdentity identity) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return false;
    CGDirectDisplayID *list = calloc(count, sizeof(*list));
    if (!list) return false;
    uint32_t written = 0, matches = 0, after = 0;
    bool found = false;
    if (CGGetOnlineDisplayList(count, list, &written) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < written; i++) {
            if (sameIdentity(identityOf(list[i]), identity)) {
                matches++;
                found |= list[i] == display;
            }
        }
    }
    free(list);
    return found && matches == 1 && CGGetOnlineDisplayList(0, NULL, &after) == kCGErrorSuccess && after == written;
}

static bool edidMatches(const uint8_t *edid, size_t count, MonitorIdentity identity) {
    static const uint8_t header[] = {0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00};
    if (count < 128 || memcmp(edid, header, sizeof(header))) return false;
    uint8_t sum = 0;
    for (size_t i = 0; i < 128; i++) sum += edid[i];
    MonitorIdentity physical = {
        .vendor = (uint32_t)edid[8] << 8 | edid[9],
        .product = edid[10] | (uint32_t)edid[11] << 8,
        .serial = edid[12] | (uint32_t)edid[13] << 8 | (uint32_t)edid[14] << 16 | (uint32_t)edid[15] << 24
    };
    return sum == 0 && sameIdentity(physical, identity);
}

static bool dataMatches(CFDataRef data, MonitorIdentity identity) {
    return data && CFGetTypeID(data) == CFDataGetTypeID() &&
           edidMatches(CFDataGetBytePtr(data), (size_t)CFDataGetLength(data), identity);
}

#if defined(__arm64__)
// ABI references: wine-mirror/wine (cocoa_display.m), waydabber/m1ddc (i2c.h).
// These symbols have no public headers and may be absent on a future macOS.
typedef CFTypeRef (*CreateAVService)(CFAllocatorRef, io_service_t);
typedef IOReturn (*CopyAVEdid)(CFTypeRef, CFDataRef *);
typedef IOReturn (*WriteAVBus)(CFTypeRef, uint32_t, uint32_t, const void *, uint32_t);
typedef IOReturn (*ReadAVBus)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
static CreateAVService makeAVService;
static CopyAVEdid copyAVEdid;
static WriteAVBus writeAVBus;
static ReadAVBus readAVBus;

static bool haveAVControls(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LOCAL | RTLD_LAZY);
        if (library) {
            makeAVService = dlsym(library, "IOAVServiceCreateWithService");
            copyAVEdid = dlsym(library, "IOAVServiceCopyEDID");
            writeAVBus = dlsym(library, "IOAVServiceWriteI2C");
            readAVBus = dlsym(library, "IOAVServiceReadI2C");
        }
    });
    return makeAVService && copyAVEdid && writeAVBus && readAVBus;
}

static bool serviceMatches(CFTypeRef service, MonitorIdentity identity) {
    CFDataRef edid = NULL;
    bool matches = copyAVEdid(service, &edid) == kIOReturnSuccess && dataMatches(edid, identity);
    if (edid) CFRelease(edid);
    return matches;
}

static bool findPort(DDMonitorBus *bus) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (!haveAVControls() || IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                                          &iterator) != KERN_SUCCESS) return false;
    for (io_service_t port; (port = IOIteratorNext(iterator)); ) {
        CFTypeRef loc = IORegistryEntryCreateCFProperty(port, CFSTR("Location"), NULL, 0);
        bool external = loc && CFEqual(loc, CFSTR("External"));
        if (loc) CFRelease(loc);
        CFTypeRef service = external ? makeAVService(NULL, port) : NULL;
        IOObjectRelease(port);
        if (!service) continue;
        if (!serviceMatches(service, bus->identity)) {
            CFRelease(service);
            continue;
        }
        if (bus->service) {
            CFRelease(service);
            CFRelease(bus->service);
            bus->service = NULL;
            break;
        }
        bus->service = service;
    }
    IOObjectRelease(iterator);
    return bus->service != NULL;
}

static bool portMatches(DDMonitorBus *bus) { return serviceMatches(bus->service, bus->identity); }
static void closePort(DDMonitorBus *bus) { CFRelease(bus->service); }

bool DDSendMonitorPacket(DDMonitorBus *bus, const uint8_t *bytes, size_t count) {
    return count <= UINT32_MAX && writeAVBus(bus->service, 0x37, 0x51, bytes, (uint32_t)count) == kIOReturnSuccess;
}

size_t DDReadMonitorPacket(DDMonitorBus *bus, uint8_t *bytes, size_t capacity) {
    return capacity <= UINT32_MAX && readAVBus(bus->service, 0x37, 0x51, bytes, (uint32_t)capacity) == kIOReturnSuccess
           ? capacity : 0;
}

CFDataRef DDCopyMatchedEDID(CGDirectDisplayID display) {
    DDMonitorBus *bus = DDOpenMonitorBus(display);
    if (!bus) return NULL;
    CFDataRef edid = NULL;
    bool matched = copyAVEdid(bus->service, &edid) == kIOReturnSuccess && dataMatches(edid, bus->identity) &&
                   isUniqueOnline(display, bus->identity);
    DDCloseMonitorBus(bus);
    if (matched) return edid;
    if (edid) CFRelease(edid);
    return NULL;
}
#else
static bool requestSucceeded(IOI2CConnectRef connection, IOI2CRequest *request) {
    return IOI2CSendRequest(connection, 0, request) == kIOReturnSuccess && request->result == kIOReturnSuccess;
}

static bool portMatches(DDMonitorBus *bus) {
    // Check the EDID on the exact bus that will carry DDC writes. Framebuffer
    // identity alone is insufficient on GPUs exposing multiple I2C interfaces.
    uint8_t offset = 0, edid[128] = {0};
    IOI2CRequest request = {0};
    request.sendTransactionType = kIOI2CSimpleTransactionType;
    request.sendAddress = 0xa0;
    request.sendBuffer = (vm_address_t)&offset;
    request.sendBytes = 1;
    request.replyTransactionType = kIOI2CSimpleTransactionType;
    request.replyAddress = 0xa1;
    request.replyBuffer = (vm_address_t)edid;
    request.replyBytes = sizeof(edid);
    return requestSucceeded(bus->connection, &request) && request.replyBytes == sizeof(edid) &&
           edidMatches(edid, sizeof(edid), bus->identity);
}

static bool inspectFramebuffer(io_service_t framebuffer, DDMonitorBus *bus) {
    CFDictionaryRef info = IODisplayCreateInfoDictionary(framebuffer, 0);
    bool registryMatches = info && dataMatches(CFDictionaryGetValue(info, CFSTR(kIODisplayEDIDKey)), bus->identity);
    if (info) CFRelease(info);
    IOItemCount count = 0;
    if (!registryMatches || IOFBGetI2CInterfaceCount(framebuffer, &count) != kIOReturnSuccess) return true;

    for (IOOptionBits index = 0; index < count; index++) {
        io_service_t interface = IO_OBJECT_NULL;
        if (IOFBCopyI2CInterfaceForBus(framebuffer, index, &interface) != kIOReturnSuccess) continue;
        CFNumberRef property = IORegistryEntryCreateCFProperty(interface, CFSTR(kIOI2CTransactionTypesKey), NULL, 0);
        uint32_t types = 0;
        if (property) {
            if (CFGetTypeID(property) == CFNumberGetTypeID()) CFNumberGetValue(property, kCFNumberSInt32Type, &types);
            CFRelease(property);
        }
        DDMonitorBus candidate = {.display = bus->display, .identity = bus->identity};
        candidate.replyType = (types & (1 << kIOI2CDDCciReplyTransactionType)) ?
                              kIOI2CDDCciReplyTransactionType : kIOI2CSimpleTransactionType;
        IOReturn opened = IOI2CInterfaceOpen(interface, 0, &candidate.connection);
        IOObjectRelease(interface);
        if (opened != kIOReturnSuccess || !candidate.connection) continue;
        if (!portMatches(&candidate)) {
            IOI2CInterfaceClose(candidate.connection, 0);
            continue;
        }
        if (bus->connection) {
            IOI2CInterfaceClose(candidate.connection, 0);
            IOI2CInterfaceClose(bus->connection, 0);
            bus->connection = NULL;
            return false;
        }
        *bus = candidate;
    }
    return true;
}

static bool findPort(DDMonitorBus *bus) {
    io_iterator_t frames = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &frames) != KERN_SUCCESS)
        return false;
    for (io_service_t frame; (frame = IOIteratorNext(frames)); ) {
        bool unique = inspectFramebuffer(frame, bus);
        IOObjectRelease(frame);
        if (!unique) break;
    }
    IOObjectRelease(frames);
    return bus->connection != NULL;
}

static void closePort(DDMonitorBus *bus) { IOI2CInterfaceClose(bus->connection, 0); }

bool DDSendMonitorPacket(DDMonitorBus *bus, const uint8_t *bytes, size_t count) {
    uint8_t wire[40] = {0x51};
    if (count > sizeof(wire) - 1) return false;
    memcpy(wire + 1, bytes, count);
    IOI2CRequest request = {0};
    request.sendTransactionType = kIOI2CSimpleTransactionType;
    request.sendAddress = 0x6e;
    request.sendBuffer = (vm_address_t)wire;
    request.sendBytes = (uint32_t)count + 1;
    return requestSucceeded(bus->connection, &request) && request.sendBytes == count + 1;
}

size_t DDReadMonitorPacket(DDMonitorBus *bus, uint8_t *bytes, size_t capacity) {
    if (capacity > UINT32_MAX) return 0;
    IOI2CRequest request = {0};
    request.replyTransactionType = bus->replyType;
    request.replyAddress = 0x6f;
    request.replySubAddress = 0x51;
    request.replyBuffer = (vm_address_t)bytes;
    request.replyBytes = (uint32_t)capacity;
    return requestSucceeded(bus->connection, &request) ? request.replyBytes : 0;
}

CFDataRef DDCopyMatchedEDID(CGDirectDisplayID display) { return NULL; }
#endif

DDMonitorBus *DDOpenMonitorBus(CGDirectDisplayID display) {
    MonitorIdentity identity = identityOf(display);
    if (CGDisplayIsBuiltin(display) || !identity.vendor || !identity.product ||
        !identity.serial || identity.serial == UINT32_MAX || !isUniqueOnline(display, identity)) return NULL;
    DDMonitorBus *bus = calloc(1, sizeof(*bus));
    if (!bus) return NULL;
    bus->display = display;
    bus->identity = identity;
    if (findPort(bus)) return bus;
    free(bus);
    return NULL;
}

bool DDMonitorBusMatches(DDMonitorBus *bus) {
    return isUniqueOnline(bus->display, bus->identity) && portMatches(bus);
}

void DDCloseMonitorBus(DDMonitorBus *bus) {
    closePort(bus);
    free(bus);
}
