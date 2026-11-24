#import "DisplayDetailsBridge.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>

@protocol DDOrientablePanel
- (instancetype)initWithCGSDisplayID:(int32_t)displayID;
@property(nonatomic, readonly) int32_t displayID;
@property(nonatomic) int32_t orientation;
- (BOOL)canChangeOrientation;
@end

// MonitorPanel is also used by the macOS Displays settings pane. Look up its methods
// at runtime so a missing or changed private interface only disables the rotation control.
static id<DDOrientablePanel> DDPanel(CGDirectDisplayID display) {
    static Class panelClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *module = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
                              RTLD_LOCAL | RTLD_LAZY);
        if (!module) return;
        Class type = NSClassFromString(@"MPDisplay");
        if (![type instancesRespondToSelector:@selector(initWithCGSDisplayID:)] ||
            ![type instancesRespondToSelector:@selector(displayID)] ||
            ![type instancesRespondToSelector:@selector(canChangeOrientation)] ||
            ![type instancesRespondToSelector:@selector(setOrientation:)]) return;
        panelClass = type;
    });
    if (!panelClass || !CGDisplayIsOnline(display)) return nil;
    id<DDOrientablePanel> panel = [(id<DDOrientablePanel>)[panelClass alloc] initWithCGSDisplayID:(int32_t)display];
    return panel && (CGDirectDisplayID)panel.displayID == display ? panel : nil;
}

bool DDCanRotateDisplay(CGDirectDisplayID display) {
    @try { return [DDPanel(display) canChangeOrientation]; }
    @catch (NSException *exception) { return false; }
}

bool DDRequestRotation(CGDirectDisplayID display, int32_t degrees) {
    if (degrees != 0 && degrees != 90 && degrees != 180 && degrees != 270) return false;
    @try {
        id<DDOrientablePanel> panel = DDPanel(display);
        if (!panel || !panel.canChangeOrientation) return false;
        [panel setOrientation:degrees];
        // This acknowledges submission. Quartz readback confirms the actual result.
        return true;
    } @catch (NSException *exception) { return false; }
}
