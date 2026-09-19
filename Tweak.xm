#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>

/*
 * BiliDanmaku120 0.2.2 SafeExactSpeed
 *
 * Safety changes after the 0.2.1 launch crash:
 *  - NEVER replace CADisplayLink's original target with a proxy.
 *  - NEVER scan all Objective-C classes and hook arbitrary speed/rate methods.
 *  - Only hook exact, well-known BarrageRenderer/BarrageClock setSpeed: methods,
 *    and only after verifying a void(double) signature on arm64/old-arm64e.
 *  - Candidate danmaku CADisplayLinks keep their original target/selector.
 *
 * Goal remains:
 *  - Request up to 120Hz for likely danmaku display links.
 *  - If Bilibili uses the common BarrageRenderer/BarrageClock engine, clamp
 *    danmaku clock speed >1x back to 1x while video can remain 2x/3x.
 *  - If it uses a different engine, log the exact class and interesting methods
 *    for a later targeted build instead of guessing and risking another crash.
 */

static NSString *gLogPath = nil;
static dispatch_queue_t gLogQueue;
static NSMutableSet<NSString *> *gSeenLinks = nil;
static NSMutableSet<NSString *> *gDumpedClasses = nil;
static const void *kGTDCandidateKey = &kGTDCandidateKey;
static volatile uint64_t gExactSpeedCaps = 0;

static NSInteger GTDMaxScreenFPS(void) {
    UIScreen *s = UIScreen.mainScreen;
    if ([s respondsToSelector:@selector(maximumFramesPerSecond)]) return s.maximumFramesPerSecond;
    return 60;
}

static BOOL GTDIs120Hz(void) {
    return GTDMaxScreenFPS() >= 120;
}

static void GTDLog(NSString *format, ...) {
    if (!gLogQueue || !gLogPath) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    dispatch_async(gLogQueue, ^{
        @autoreleasepool {
            NSString *line = [NSString stringWithFormat:@"%.3f %@\n", NSDate.date.timeIntervalSince1970, msg];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSFileManager *fm = NSFileManager.defaultManager;
            if (![fm fileExistsAtPath:gLogPath]) {
                [data writeToFile:gLogPath atomically:YES];
            } else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:data];
                    [fh closeFile];
                }
            }
        }
    });
}

static BOOL GTDContainsAny(NSString *text, NSArray<NSString *> *terms) {
    if (text.length == 0) return NO;
    NSString *low = text.lowercaseString;
    for (NSString *term in terms) {
        if ([low containsString:term]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *GTDStrongTerms(void) {
    static NSArray<NSString *> *terms = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        terms = @[@"danmaku", @"danmu", @"barrage", @"bullet"];
    });
    return terms;
}

static BOOL GTDLooksLikeDanmakuTarget(id target, SEL selector) {
    NSString *cls = target ? NSStringFromClass([target class]) : @"";
    NSString *sel = selector ? NSStringFromSelector(selector) : @"";
    if ([cls isEqualToString:@"BarrageClock"] || [cls isEqualToString:@"BarrageRenderer"]) return YES;
    return GTDContainsAny(cls, GTDStrongTerms()) || GTDContainsAny(sel, GTDStrongTerms());
}

static void GTDDumpInterestingMethods(Class cls) {
    if (!cls) return;
    NSString *className = NSStringFromClass(cls) ?: @"?";
    @synchronized (gDumpedClasses) {
        if ([gDumpedClasses containsObject:className]) return;
        [gDumpedClasses addObject:className];
    }

    NSArray<NSString *> *terms = @[@"speed", @"rate", @"time", @"clock", @"update", @"tick", @"display", @"render", @"move", @"duration"];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (GTDContainsAny(name, terms)) {
            const char *enc = method_getTypeEncoding(methods[i]);
            [hits addObject:[NSString stringWithFormat:@"%@ <%s>", name, enc ?: "?"]];
        }
    }
    free(methods);
    GTDLog(@"DMK CLASS %@ methods=%@", className, hits.count ? [hits componentsJoinedByString:@", "] : @"(none)");
}

static BOOL GTDIsVoidDoubleSetter(Method m) {
    if (!m || method_getNumberOfArguments(m) != 3) return NO;
    char ret[16] = {0};
    char arg[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    method_getArgumentType(m, 2, arg, sizeof(arg));
    return ret[0] == 'v' && arg[0] == 'd';
}

typedef void (*GTDSetCGFloatIMP)(id, SEL, CGFloat);
static GTDSetCGFloatIMP origBarrageClockSetSpeed = NULL;
static GTDSetCGFloatIMP origBarrageRendererSetSpeed = NULL;
static BOOL gBarrageClockHooked = NO;
static BOOL gBarrageRendererHooked = NO;

static CGFloat GTDClampDanmakuSpeed(CGFloat requested, NSString *owner) {
    if (requested > 1.001 && requested <= 4.001) {
        __sync_fetch_and_add(&gExactSpeedCaps, 1);
        GTDLog(@"SPEED CAP %@ %.3f -> 1.000", owner, (double)requested);
        return 1.0;
    }
    return requested;
}

static void hookBarrageClockSetSpeed(id self, SEL _cmd, CGFloat requested) {
    CGFloat adjusted = GTDClampDanmakuSpeed(requested, @"BarrageClock");
    if (origBarrageClockSetSpeed) origBarrageClockSetSpeed(self, _cmd, adjusted);
}

static void hookBarrageRendererSetSpeed(id self, SEL _cmd, CGFloat requested) {
    CGFloat adjusted = GTDClampDanmakuSpeed(requested, @"BarrageRenderer");
    if (origBarrageRendererSetSpeed) origBarrageRendererSetSpeed(self, _cmd, adjusted);
}

static BOOL GTDInstallExactSpeedHook(NSString *className, IMP replacement, GTDSetCGFloatIMP *origStore, BOOL *installedFlag) {
    if (*installedFlag) return YES;
    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    SEL sel = @selector(setSpeed:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        GTDLog(@"EXACT %@ has no setSpeed:", className);
        *installedFlag = YES; // no need to repeat forever
        return NO;
    }
    if (!GTDIsVoidDoubleSetter(m)) {
        GTDLog(@"EXACT %@ setSpeed: skipped encoding=%s", className, method_getTypeEncoding(m));
        *installedFlag = YES;
        return NO;
    }

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, replacement, &orig);
    if (!orig) {
        GTDLog(@"EXACT %@ setSpeed: hook failed", className);
        return NO;
    }
    *origStore = (GTDSetCGFloatIMP)orig;
    *installedFlag = YES;
    GTDLog(@"EXACT %@ setSpeed: hook OK encoding=%s", className, method_getTypeEncoding(m));
    return YES;
}

static void GTDTryExactSpeedHooks(void) {
    GTDInstallExactSpeedHook(@"BarrageClock", (IMP)hookBarrageClockSetSpeed, &origBarrageClockSetSpeed, &gBarrageClockHooked);
    GTDInstallExactSpeedHook(@"BarrageRenderer", (IMP)hookBarrageRendererSetSpeed, &origBarrageRendererSetSpeed, &gBarrageRendererHooked);
}

typedef CADisplayLink *(*GTDCreateDLIMP)(id, SEL, id, SEL);
typedef void (*GTDSetFPSIMP)(id, SEL, NSInteger);
typedef void (*GTDSetIntervalIMP)(id, SEL, NSInteger);
static GTDCreateDLIMP origCreateDL = NULL;
static GTDSetFPSIMP origSetPreferredFPS = NULL;
static GTDSetIntervalIMP origSetFrameInterval = NULL;

static CADisplayLink *hookCreateDisplayLink(id clsObj, SEL _cmd, id target, SEL selector) {
    if (!origCreateDL) return nil;
    CADisplayLink *link = origCreateDL(clsObj, _cmd, target, selector);
    if (!link) return nil;

    BOOL candidate = GTDLooksLikeDanmakuTarget(target, selector);
    NSString *targetClass = target ? NSStringFromClass([target class]) : @"nil";
    NSString *selectorName = selector ? NSStringFromSelector(selector) : @"nil";
    NSString *key = [NSString stringWithFormat:@"%@::%@", targetClass, selectorName];

    @synchronized (gSeenLinks) {
        if (![gSeenLinks containsObject:key]) {
            [gSeenLinks addObject:key];
            GTDLog(@"DL CREATE target=%@ selector=%@ candidate=%d", targetClass, selectorName, candidate);
        }
    }

    if (!candidate) return link;

    objc_setAssociatedObject(link, kGTDCandidateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GTDDumpInterestingMethods([target class]);
    GTDTryExactSpeedHooks();

    if (GTDIs120Hz()) {
        if (origSetPreferredFPS) origSetPreferredFPS(link, @selector(setPreferredFramesPerSecond:), 120);
        else link.preferredFramesPerSecond = 120;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([link respondsToSelector:@selector(setFrameInterval:)]) {
            if (origSetFrameInterval) origSetFrameInterval(link, @selector(setFrameInterval:), 1);
            else link.frameInterval = 1;
        }
#pragma clang diagnostic pop
    }

    GTDLog(@"DMK MATCH target=%@ selector=%@ requestFPS=%ld", targetClass, selectorName, (long)(GTDIs120Hz() ? 120 : GTDMaxScreenFPS()));
    return link;
}

static void hookSetPreferredFPS(id self, SEL _cmd, NSInteger fps) {
    NSInteger adjusted = fps;
    NSNumber *candidate = objc_getAssociatedObject(self, kGTDCandidateKey);
    if (candidate.boolValue && GTDIs120Hz() && fps > 0 && fps < 120) {
        adjusted = 120;
        GTDLog(@"DMK FPS request %ld -> 120", (long)fps);
    }
    if (origSetPreferredFPS) origSetPreferredFPS(self, _cmd, adjusted);
}

static void hookSetFrameInterval(id self, SEL _cmd, NSInteger interval) {
    NSInteger adjusted = interval;
    NSNumber *candidate = objc_getAssociatedObject(self, kGTDCandidateKey);
    if (candidate.boolValue && GTDIs120Hz() && interval > 1) {
        adjusted = 1;
        GTDLog(@"DMK frameInterval %ld -> 1", (long)interval);
    }
    if (origSetFrameInterval) origSetFrameInterval(self, _cmd, adjusted);
}

static void GTDInstallDisplayLinkHooks(void) {
    Class dl = [CADisplayLink class];
    Class meta = object_getClass(dl);
    Method createM = class_getClassMethod(dl, @selector(displayLinkWithTarget:selector:));
    if (createM && meta) {
        MSHookMessageEx(meta, @selector(displayLinkWithTarget:selector:), (IMP)hookCreateDisplayLink, (IMP *)&origCreateDL);
    }

    Method fpsM = class_getInstanceMethod(dl, @selector(setPreferredFramesPerSecond:));
    if (fpsM) {
        MSHookMessageEx(dl, @selector(setPreferredFramesPerSecond:), (IMP)hookSetPreferredFPS, (IMP *)&origSetPreferredFPS);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Method intervalM = class_getInstanceMethod(dl, @selector(setFrameInterval:));
    if (intervalM) {
        MSHookMessageEx(dl, @selector(setFrameInterval:), (IMP)hookSetFrameInterval, (IMP *)&origSetFrameInterval);
    }
#pragma clang diagnostic pop

    GTDLog(@"HOOK DL create=%d fps=%d interval=%d", origCreateDL != NULL, origSetPreferredFPS != NULL, origSetFrameInterval != NULL);
}

static void GTDScheduleExactHookRetries(void) {
    const double delays[] = {0.2, 1.0, 3.0, 8.0};
    for (unsigned int i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        double delay = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTDTryExactSpeedHooks();
        });
    }
}

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;

        gSeenLinks = [NSMutableSet set];
        gDumpedClasses = [NSMutableSet set];
        gLogQueue = dispatch_queue_create("com.chatgpt.bilidanmaku120.log", DISPATCH_QUEUE_SERIAL);
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [docs stringByAppendingPathComponent:@"BiliDanmaku120.log"];

        GTDLog(@"BiliDanmaku120 0.2.2 START maxScreen=%ld", (long)GTDMaxScreenFPS());
        GTDInstallDisplayLinkHooks();
        GTDScheduleExactHookRetries();
    }
}
