#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "VirtualDisplayBridge.h"

// These classes are private macOS API. Their signatures follow the MIT-licensed
// DeskPad header: https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

void *VDCreate(uint32_t pixelWidth, uint32_t pixelHeight,
               uint32_t logicalWidth, uint32_t logicalHeight,
               uint32_t *displayID) {
    if (pixelWidth < 640 || pixelHeight < 480 || pixelWidth > 4096 || pixelHeight > 4096) return NULL;
    if (logicalWidth < 320 || logicalHeight < 240) return NULL;
    if (logicalWidth > pixelWidth || logicalHeight > pixelHeight) return NULL;
    if (!NSClassFromString(@"CGVirtualDisplay")) {
        NSLog(@"CGVirtualDisplay class is unavailable");
        return NULL;
    }

    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.name = @"Tablet Display";
    descriptor.maxPixelsWide = pixelWidth;
    descriptor.maxPixelsHigh = pixelHeight;
    descriptor.sizeInMillimeters = CGSizeMake(270, 170);
    descriptor.vendorID = 0x5442;
    descriptor.productID = 0x4453;
    descriptor.serialNum = 1;
    descriptor.queue = dispatch_get_main_queue();
    descriptor.terminationHandler = ^(id _unused, id display) { (void)display; };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) {
        NSLog(@"CGVirtualDisplay initWithDescriptor failed");
        return NULL;
    }

    BOOL hiDPI = (logicalWidth * 2 == pixelWidth && logicalHeight * 2 == pixelHeight);
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:logicalWidth
                                                             height:logicalHeight
                                                        refreshRate:60]];
    if (![display applySettings:settings]) {
        NSLog(@"CGVirtualDisplay applySettings failed");
        return NULL;
    }
    if (!display.displayID) {
        NSLog(@"CGVirtualDisplay has zero displayID");
        return NULL;
    }

    *displayID = display.displayID;
    return (__bridge_retained void *)display;
}

bool VDSetNativeMode(uint32_t displayID, uint32_t width, uint32_t height) {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    if (!modes) return false;
    bool selected = false;
    for (CFIndex index = 0; index < CFArrayGetCount(modes); index++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index);
        if (CGDisplayModeGetPixelWidth(mode) == width &&
            CGDisplayModeGetPixelHeight(mode) == height) {
            selected = CGDisplaySetDisplayMode(displayID, mode, NULL) == kCGErrorSuccess;
            break;
        }
    }
    CFRelease(modes);
    return selected;
}

bool VDPlaceRightOfMain(uint32_t displayID) {
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    if (!mainDisplay || mainDisplay == displayID) return false;
    CGRect mainBounds = CGDisplayBounds(mainDisplay);
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return false;
    CGError result = CGConfigureDisplayOrigin(config, displayID,
                                               (int32_t)CGRectGetMaxX(mainBounds),
                                               (int32_t)CGRectGetMinY(mainBounds));
    if (result != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

void VDDestroy(void *handle) {
    if (!handle) return;
    id display = (__bridge_transfer id)handle;
    (void)display;
}
