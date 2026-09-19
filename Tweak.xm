#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdint.h>

/*
 * BiliDanmaku120 0.3.0 BFCTargetSafe
 *
 * Findings from the device log:
 *   BFCDisplayLink              displayLinkDidRefresh:
 *   BFCCRONRenderViewV2        onDisplayLink: / mainOnDisplayLink:
 *   BFCCommentFrameRateBooster _displayLinkTick
 *
 * Design:
 * - DO NOT hook CADisplayLink at all. BiliVideoFPS120 remains the sole owner of
 *   the global 60->120 DisplayLink lift, avoiding the 0.2.2 conflict that made
 *   VID disappear.
 * - Hook only the exact BFCCommentFrameRateBooster _displayLinkTick method when
 *   its ABI is verified as void/no-explicit-argument, and count real comment
 *   update ticks for the DMK overlay.
 * - Inspect only two exact Bilibili comment classes for likely speed/rate
 *   setters. If a whitelisted setter exists and is ABI-safe void(float/double),
 *   clamp requests in (1x, 4x] back to 1x. No broad runtime scanning.
 * - Dump interesting methods/properties/ivars once into a bounded log so the
 *   next build can target the real media-time coupling if Bilibili does not use
 *   one of the common setters.
 */

@interface GTDPassWindow : UIWindow @end
@implementation GTDPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static NSString *gLogPath = nil;
static dispatch_queue_t gLogQueue;
static const unsigned long long gMaxLogBytes = 128ULL * 1024ULL;
static NSMutableSet<NSString *> *gDumpedClasses = nil;
static NSMutableSet<NSString *> *gInstalledSpeedKeys = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gOrigDoubleIMPs = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gOrigFloatIMPs = nil;
static volatile uint64_t gDmkTickCount = 0;
static volatile uint64_t gSpeedCapCount = 0;
static BOOL gTickHooked = NO;
static void (*gOrigCommentTick)(id, SEL) = NULL;

static NSInteger GTDMaxScreenFPS(void) {
    UIScreen *s = UIScreen.mainScreen;
    if ([s respondsToSelector:@selector(maximumFramesPerSecond)]) return s.maximumFramesPerSecond;
    return 60;
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
            NSDictionary *attrs = [fm attributesOfItemAtPath:gLogPath error:nil];
            unsigned long long size = attrs ? [[attrs objectForKey:NSFileSize] unsignedLongLongValue] : 0;
            if (size >= gMaxLogBytes) {
                [fm removeItemAtPath:gLogPath error:nil];
                NSString *reset = [NSString stringWithFormat:@"%.3f LOG RESET oldSize=%llu max=%llu\n", NSDate.date.timeIntervalSince1970, size, gMaxLogBytes];
                [[reset dataUsingEncoding:NSUTF8StringEncoding] writeToFile:gLogPath atomically:YES];
            }
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

static BOOL GTDNameContainsAny(NSString *name, NSArray<NSString *> *terms) {
    if (name.length == 0) return NO;
    NSString *low = name.lowercaseString;
    for (NSString *term in terms) if ([low containsString:term]) return YES;
    return NO;
}

static NSString *GTDMethodEncoding(Method m) {
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    return enc ? [NSString stringWithUTF8String:enc] : @"?";
}

static void GTDDumpExactClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    @synchronized (gDumpedClasses) {
        if ([gDumpedClasses containsObject:className]) return;
        [gDumpedClasses addObject:className];
    }

    NSArray<NSString *> *terms = @[@"speed", @"rate", @"time", @"clock", @"tick", @"display", @"render", @"comment", @"danmaku", @"duration", @"progress", @"position", @"frame"];

    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    NSMutableArray<NSString *> *mhits = [NSMutableArray array];
    for (unsigned int i = 0; i < mc; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel) ?: @"";
        if (GTDNameContainsAny(name, terms)) {
            [mhits addObject:[NSString stringWithFormat:@"%@<%@>", name, GTDMethodEncoding(methods[i])]];
        }
    }
    if (methods) free(methods);

    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pc);
    NSMutableArray<NSString *> *phits = [NSMutableArray array];
    for (unsigned int i = 0; i < pc; i++) {
        const char *n = property_getName(props[i]);
        NSString *name = n ? [NSString stringWithUTF8String:n] : @"";
        if (GTDNameContainsAny(name, terms)) [phits addObject:name];
    }
    if (props) free(props);

    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    NSMutableArray<NSString *> *ihits = [NSMutableArray array];
    for (unsigned int i = 0; i < ic; i++) {
        const char *n = ivar_getName(ivars[i]);
        const char *t = ivar_getTypeEncoding(ivars[i]);
        NSString *name = n ? [NSString stringWithUTF8String:n] : @"";
        if (GTDNameContainsAny(name, terms)) {
            [ihits addObject:[NSString stringWithFormat:@"%@<%s>", name, t ?: "?"]];
        }
    }
    if (ivars) free(ivars);

    GTDLog(@"CLASS %@ methods=%@", className, mhits.count ? [mhits componentsJoinedByString:@", "] : @"(none)");
    GTDLog(@"CLASS %@ props=%@", className, phits.count ? [phits componentsJoinedByString:@", "] : @"(none)");
    GTDLog(@"CLASS %@ ivars=%@", className, ihits.count ? [ihits componentsJoinedByString:@", "] : @"(none)");
}

#pragma mark - Exact BFC comment tick counter

static BOOL GTDVoidNoArgMethod(Method m) {
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == 'v';
}

static void GTDCommentTickHook(id self, SEL _cmd) {
    __sync_fetch_and_add(&gDmkTickCount, 1);
    if (gOrigCommentTick) gOrigCommentTick(self, _cmd);
}

static void GTDTryInstallTickHook(void) {
    if (gTickHooked) return;
    Class cls = NSClassFromString(@"BFCCommentFrameRateBooster");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"_displayLinkTick");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        GTDLog(@"TICK BFCCommentFrameRateBooster has no _displayLinkTick");
        gTickHooked = YES;
        return;
    }
    if (!GTDVoidNoArgMethod(m)) {
        GTDLog(@"TICK skipped encoding=%@ argc=%u", GTDMethodEncoding(m), method_getNumberOfArguments(m));
        gTickHooked = YES;
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)GTDCommentTickHook, &orig);
    if (orig) {
        gOrigCommentTick = (void(*)(id,SEL))orig;
        gTickHooked = YES;
        GTDLog(@"TICK hook OK class=BFCCommentFrameRateBooster sel=_displayLinkTick encoding=%@", GTDMethodEncoding(m));
    }
}

#pragma mark - Exact, ABI-checked speed/rate setters

static NSString *GTDSpeedKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static uintptr_t GTDLookupOrig(NSMutableDictionary<NSString *, NSNumber *> *map, id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSNumber *n = map[GTDSpeedKey(c, sel)];
        if (n) return (uintptr_t)[n unsignedLongLongValue];
        c = class_getSuperclass(c);
    }
    return (uintptr_t)0;
}

static double GTDClampSpeed(double requested, id self, SEL _cmd) {
    if (requested > 1.001 && requested <= 4.001) {
        uint64_t n = __sync_add_and_fetch(&gSpeedCapCount, 1);
        if (n <= 12) {
            GTDLog(@"SPEED CAP class=%@ sel=%@ %.3f -> 1.000", NSStringFromClass([self class]), NSStringFromSelector(_cmd), requested);
        }
        return 1.0;
    }
    return requested;
}

static void GTDHookDoubleSetter(id self, SEL _cmd, double requested) {
    uintptr_t p = GTDLookupOrig(gOrigDoubleIMPs, self, _cmd);
    if (!p) return;
    double adjusted = GTDClampSpeed(requested, self, _cmd);
    ((void(*)(id,SEL,double))(void *)p)(self, _cmd, adjusted);
}

static void GTDHookFloatSetter(id self, SEL _cmd, float requested) {
    uintptr_t p = GTDLookupOrig(gOrigFloatIMPs, self, _cmd);
    if (!p) return;
    float adjusted = (float)GTDClampSpeed((double)requested, self, _cmd);
    ((void(*)(id,SEL,float))(void *)p)(self, _cmd, adjusted);
}

static BOOL GTDSetterKind(Method m, char *kindOut) {
    if (!m || method_getNumberOfArguments(m) != 3) return NO;
    char ret[16] = {0};
    char arg[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    method_getArgumentType(m, 2, arg, sizeof(arg));
    if (ret[0] != 'v') return NO;
    if (arg[0] == 'd' || arg[0] == 'f') {
        *kindOut = arg[0];
        return YES;
    }
    return NO;
}

static void GTDTryInstallSpeedSetter(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    NSString *key = GTDSpeedKey(cls, sel);
    @synchronized (gInstalledSpeedKeys) {
        if ([gInstalledSpeedKeys containsObject:key]) return;
    }

    char kind = 0;
    if (!GTDSetterKind(m, &kind)) {
        GTDLog(@"SPEED skip %@ encoding=%@", key, GTDMethodEncoding(m));
        @synchronized (gInstalledSpeedKeys) { [gInstalledSpeedKeys addObject:key]; }
        return;
    }

    IMP orig = NULL;
    IMP replacement = (kind == 'd') ? (IMP)GTDHookDoubleSetter : (IMP)GTDHookFloatSetter;
    MSHookMessageEx(cls, sel, replacement, &orig);
    if (!orig) {
        GTDLog(@"SPEED hook failed %@", key);
        return;
    }

    NSNumber *boxed = [NSNumber numberWithUnsignedLongLong:(unsigned long long)(uintptr_t)orig];
    if (kind == 'd') gOrigDoubleIMPs[key] = boxed;
    else gOrigFloatIMPs[key] = boxed;
    @synchronized (gInstalledSpeedKeys) { [gInstalledSpeedKeys addObject:key]; }
    GTDLog(@"SPEED hook OK %@ kind=%c encoding=%@", key, kind, GTDMethodEncoding(m));
}

static void GTDTryInstallExactSpeedHooks(void) {
    NSArray<NSString *> *classes = @[@"BFCCRONRenderViewV2", @"BFCCommentFrameRateBooster"];
    NSArray<NSString *> *sels = @[@"setPlaybackRate:", @"setSpeed:", @"setRate:", @"setTimeScale:", @"setTimeRate:"];
    for (NSString *cls in classes) {
        for (NSString *sel in sels) GTDTryInstallSpeedSetter(cls, sel);
    }
}

static void GTDProbeExactClasses(void) {
    NSArray<NSString *> *classes = @[@"BFCDisplayLink", @"BFCCRONRenderViewV2", @"BFCCommentFrameRateBooster"];
    for (NSString *name in classes) GTDDumpExactClass(name);
    GTDTryInstallTickHook();
    GTDTryInstallExactSpeedHooks();
}

#pragma mark - DMK overlay

@interface GTDOverlay : NSObject
@property(nonatomic, strong) GTDPassWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) uint64_t lastCount;
@property(nonatomic, assign) CFTimeInterval lastTime;
@property(nonatomic, assign) double smoothFPS;
+ (instancetype)shared;
- (void)start;
@end

@implementation GTDOverlay
+ (instancetype)shared {
    static GTDOverlay *o = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ o = [GTDOverlay new]; });
    return o;
}
- (UIWindowScene *)foregroundScene API_AVAILABLE(ios(13.0)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive)) return (UIWindowScene *)scene;
    }
    return nil;
}
- (CGRect)statusBarFrame {
    CGRect f = CGRectZero;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *s = self.window.windowScene ?: [self foregroundScene];
        if (s.statusBarManager) f = s.statusBarManager.statusBarFrame;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CGRectIsEmpty(f)) f = UIApplication.sharedApplication.statusBarFrame;
#pragma clang diagnostic pop
    if (CGRectIsEmpty(f) || CGRectGetHeight(f) < 1.0) f = CGRectMake(0,0,CGRectGetWidth(UIScreen.mainScreen.bounds),20.0);
    return f;
}
- (void)layout {
    CGRect b = UIScreen.mainScreen.bounds;
    self.window.frame = b;
    CGRect sf = [self statusBarFrame];
    CGFloat h = MIN(19.0, MAX(18.0, CGRectGetHeight(sf)));
    CGSize fit = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    CGFloat w = MIN(MAX(1.0, ceil(fit.width + 10.0)), 180.0);
    CGFloat cx = CGRectGetWidth(b) * 0.40;
    CGFloat cy = CGRectGetMinY(sf) + MAX(18.0, CGRectGetHeight(sf))*0.5;
    CGFloat x = MAX(2.0, MIN(round(cx - w*0.5), CGRectGetWidth(b)-w-2.0));
    CGFloat y = MAX(0.0, round(cy-h*0.5));
    self.label.frame = CGRectIntegral(CGRectMake(x,y,w,h));
}
- (void)build {
    if (self.window) return;
    GTDPassWindow *w = [[GTDPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 997.0;
    w.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) { UIWindowScene *s = [self foregroundScene]; if (s) w.windowScene = s; }
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    w.rootViewController = root;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.18];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 5.0;
    l.layer.masksToBounds = YES;
    l.userInteractionEnabled = NO;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)]) l.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    else l.font = [UIFont boldSystemFontOfSize:10.5];
    l.text = @"DMK --/120";
    [root.view addSubview:l];
    self.window = w;
    self.label = l;
    [self layout];
    w.hidden = NO;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    GTDProbeExactClasses();
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t count = __sync_fetch_and_add(&gDmkTickCount, 0);
    double fps = 0.0;
    if (self.lastTime > 0.0 && now > self.lastTime && count >= self.lastCount) {
        double dt = now - self.lastTime;
        uint64_t delta = count - self.lastCount;
        if (dt > 0.10 && delta > 0) {
            double raw = (double)delta / dt;
            if (self.smoothFPS <= 0.0) self.smoothFPS = raw;
            else self.smoothFPS = self.smoothFPS * 0.45 + raw * 0.55;
            fps = self.smoothFPS;
        } else if (dt > 0.10 && delta == 0) {
            self.smoothFPS = 0.0;
        }
    }
    self.lastTime = now;
    self.lastCount = count;
    if (gTickHooked && fps > 0.05) self.label.text = [NSString stringWithFormat:@"DMK %.0f/%ld", fps, (long)GTDMaxScreenFPS()];
    else self.label.text = [NSString stringWithFormat:@"DMK --/%ld", (long)GTDMaxScreenFPS()];
    [self layout];
}
- (void)start {
    if (self.timer) return;
    [self build];
    self.lastCount = __sync_fetch_and_add(&gDmkTickCount, 0);
    self.lastTime = CACurrentMediaTime();
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;

        gLogQueue = dispatch_queue_create("com.chatgpt.bilidanmaku120.log", DISPATCH_QUEUE_SERIAL);
        gDumpedClasses = [NSMutableSet set];
        gInstalledSpeedKeys = [NSMutableSet set];
        gOrigDoubleIMPs = [NSMutableDictionary dictionary];
        gOrigFloatIMPs = [NSMutableDictionary dictionary];
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [docs stringByAppendingPathComponent:@"BiliDanmaku120.log"];
        GTDLog(@"BiliDanmaku120 0.3.0 START maxScreen=%ld globalCADisplayLinkHook=NO", (long)GTDMaxScreenFPS());

        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTDOverlay shared] start];
            const double delays[] = {0.2, 1.0, 2.0, 4.0, 8.0, 15.0};
            for (unsigned int i = 0; i < sizeof(delays)/sizeof(delays[0]); i++) {
                double d = delays[i];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GTDProbeExactClasses(); });
            }
        });
    }
}
