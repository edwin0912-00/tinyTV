#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
#include "VirtualDisplay.h"

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain) dispatch_queue_t queue;
@property(copy) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property unsigned int serialNum, productID, vendorID;
@property(copy) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(readonly) unsigned int displayID;
@end

static id gDisplay;

// Without this macOS put the new display in a mirror set and made it the main display, so the Mac's own screen
// showed 1920x1080 (measured 2026-10-20). Same fix as kindle-screen's arrange_extended: unmirror, keep the old main
// display at the origin, place the TV display to its right.
static void arrange_extended(CGDirectDisplayID vd, CGDirectDisplayID keepMain) {
    for (int attempt = 0; attempt < 25; attempt++) {
        CGDirectDisplayID active[16]; uint32_t n = 0;
        CGGetActiveDisplayList(16, active, &n);
        double rightEdge = 0;
        for (uint32_t i = 0; i < n; i++) {
            if (active[i] == vd) continue;
            CGRect r = CGDisplayBounds(active[i]);
            if (CGRectGetMaxX(r) > rightEdge) rightEdge = CGRectGetMaxX(r);
        }
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) { usleep(120000); continue; }
        CGConfigureDisplayMirrorOfDisplay(cfg, vd, kCGNullDirectDisplay);
        if (keepMain) CGConfigureDisplayMirrorOfDisplay(cfg, keepMain, kCGNullDirectDisplay);
        if (keepMain) CGConfigureDisplayOrigin(cfg, keepMain, 0, 0);
        CGConfigureDisplayOrigin(cfg, vd, (int32_t)rightEdge, 0);
        CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        usleep(220000);
        if (!CGDisplayIsInMirrorSet(vd) && (!keepMain || CGDisplayIsMain(keepMain))) return;
    }
}

uint32_t tinytv_vd_create(unsigned int w, unsigned int h) {
    if (gDisplay) return ((CGVirtualDisplay *)gDisplay).displayID;
    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor"), dispCls = NSClassFromString(@"CGVirtualDisplay");
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode"), setCls = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!descCls || !dispCls || !modeCls || !setCls) return 0;
    CGDirectDisplayID before[16]; uint32_t nb = 0;
    CGGetActiveDisplayList(16, before, &nb);
    CGDirectDisplayID keepMain = nb > 0 ? CGMainDisplayID() : 0;
    CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];
    desc.queue = dispatch_queue_create("tinytv.vd", DISPATCH_QUEUE_SERIAL);
    desc.name = @"tinyTV";
    desc.sizeInMillimeters = CGSizeMake(1210, 680);   // a 55" TV
    desc.maxPixelsWide = 4096; desc.maxPixelsHigh = 4096;
    desc.redPrimary = CGPointMake(0.640, 0.330); desc.greenPrimary = CGPointMake(0.300, 0.600);
    desc.bluePrimary = CGPointMake(0.150, 0.060); desc.whitePoint = CGPointMake(0.3127, 0.3290);
    desc.productID = 0x7417; desc.vendorID = 0x4B1D; desc.serialNum = 1;
    desc.terminationHandler = ^(id a, id b) { gDisplay = nil; };
    CGVirtualDisplay *d = [[dispCls alloc] initWithDescriptor:desc];
    if (!d) return 0;
    CGVirtualDisplaySettings *s = [[setCls alloc] init];
    s.hiDPI = 1;
    // Both entries: the width field means points with hiDPI=1 (measured in kindle-screen), pixels otherwise.
    s.modes = @[[[modeCls alloc] initWithWidth:w height:h refreshRate:60.0],
                [[modeCls alloc] initWithWidth:w * 2 height:h * 2 refreshRate:60.0]];
    if (![d applySettings:s]) return 0;
    gDisplay = d;
    for (int t = 0; t < 40; t++) {   // wait until it is online with modes
        CGDirectDisplayID on[16]; uint32_t n = 0; BOOL online = NO;
        CGGetOnlineDisplayList(16, on, &n);
        for (uint32_t i = 0; i < n; i++) if (on[i] == d.displayID) online = YES;
        CFArrayRef ms = CGDisplayCopyAllDisplayModes(d.displayID, NULL);
        CFIndex cnt = ms ? CFArrayGetCount(ms) : 0; if (ms) CFRelease(ms);
        if (online && cnt > 0) break;
        usleep(250000);
    }
    arrange_extended(d.displayID, keepMain);
    return d.displayID;
}

void tinytv_vd_destroy(void) { gDisplay = nil; }
