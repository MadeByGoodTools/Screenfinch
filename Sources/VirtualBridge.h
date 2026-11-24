#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Retaining this object keeps its WindowServer display connected.
@interface DDVirtualScreenHandle : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithName:(NSString *)name
                         logicalWidth:(uint32_t)width
                        logicalHeight:(uint32_t)height
                                hiDPI:(BOOL)hiDPI
                               serial:(uint32_t)serial
                                error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
