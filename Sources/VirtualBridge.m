#import "VirtualBridge.h"

// WindowServer exposes these selectors through CoreGraphics at runtime.
// Local protocols type the messages without linking to private class symbols.
@protocol DDDescriptorProperties
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t vendorID, productID, serialNum, serialNumber;
@property(nonatomic) uint32_t maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@protocol DDVirtualModeInit
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)rate;
@end

@protocol DDVirtualSettings
@property(nonatomic) uint32_t hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end

@protocol DDVirtualOutput
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

static BOOL DDHasMethods(Class type, NSArray<NSString *> *names) {
    if (!type) return NO;
    for (NSString *name in names) {
        if (![type instancesRespondToSelector:NSSelectorFromString(name)]) return NO;
    }
    return YES;
}

static void DDVirtualError(NSError **error, NSInteger code, NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:@"DisplayDesk.VirtualScreens" code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}

@implementation DDVirtualScreenHandle {
    id<DDVirtualOutput> _output;
}

- (nullable instancetype)initWithName:(NSString *)name
                         logicalWidth:(uint32_t)width
                        logicalHeight:(uint32_t)height
                                hiDPI:(BOOL)hiDPI
                               serial:(uint32_t)serial
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class outputClass = NSClassFromString(@"CGVirtualDisplay");
    if (!DDHasMethods(descriptorClass, @[@"setName:", @"setVendorID:", @"setProductID:",
                                         @"setSerialNum:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                                         @"setSizeInMillimeters:", @"setWhitePoint:", @"setRedPrimary:",
                                         @"setGreenPrimary:", @"setBluePrimary:", @"setQueue:"]) ||
        !DDHasMethods(settingsClass, @[@"setHiDPI:", @"setModes:"]) ||
        !DDHasMethods(modeClass, @[@"initWithWidth:height:refreshRate:"]) ||
        !DDHasMethods(outputClass, @[@"initWithDescriptor:", @"applySettings:", @"displayID"])) {
        DDVirtualError(error, 1, @"This version of macOS does not provide the required virtual display controls.");
        return nil;
    }

    @try {
        id<DDDescriptorProperties> descriptor = [[descriptorClass alloc] init];
        descriptor.name = name;
        descriptor.vendorID = 0x4444;
        descriptor.productID = 0x5653;
        descriptor.serialNum = serial;
        if ([descriptorClass instancesRespondToSelector:@selector(setSerialNumber:)]) {
            descriptor.serialNumber = serial;
        }
        uint32_t scale = hiDPI ? 2 : 1;
        descriptor.maxPixelsWide = width * scale;
        descriptor.maxPixelsHigh = height * scale;
        // Physical dimensions correspond to a desktop panel at 110 logical points/inch.
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0);
        // Standard sRGB chromaticities and the D65 white point.
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        descriptor.queue = dispatch_get_main_queue();

        id<DDVirtualModeInit> mode = [(id<DDVirtualModeInit>)[modeClass alloc]
            initWithWidth:width height:height refreshRate:60.0];
        id<DDVirtualSettings> settings = [[settingsClass alloc] init];
        if (!descriptor || !settings || !mode) {
            DDVirtualError(error, 2, @"macOS could not create the requested virtual display mode.");
            return nil;
        }
        settings.hiDPI = hiDPI ? 1 : 0;
        settings.modes = @[mode];
        id<DDVirtualOutput> output = [(id<DDVirtualOutput>)[outputClass alloc] initWithDescriptor:descriptor];
        if (!output || ![output applySettings:settings] || output.displayID == kCGNullDirectDisplay) {
            DDVirtualError(error, 3, @"macOS declined this virtual display. Try a smaller size or release another virtual screen.");
            return nil;
        }
        _output = output;
        _displayID = output.displayID;
    } @catch (NSException *exception) {
        DDVirtualError(error, 4, [NSString stringWithFormat:@"macOS could not configure the virtual display (%@).", exception.name]);
        return nil;
    }
    return self;
}
@end
