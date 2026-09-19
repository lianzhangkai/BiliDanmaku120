#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>

/*
 * BiliDanmaku120 0.2.0 NormalSpeed120
 *
 * Goal:
 *   - Keep danmaku refresh at up to 120Hz on ProMotion.
 *   - Decouple danmaku movement speed from Bilibili video playback rate.
 *   - When a likely danmaku clock/renderer receives a scalar speed in (1, 4],
 *     clamp it to 1.0. 0/pause and <=1.0 values are preserved.
 *
 * Why this is targeted instead of global:
 *   - Open-source BarrageRenderer-style engines are CADisplayLink driven and
 *     expose a scalar -setSpeed: on BarrageRenderer/BarrageClock.
 *   - We only hook classes whose names look danmaku/barrage-related (plus the
 *     exact BarrageRenderer/BarrageClock names), and only a verified
 *     void setSpeed:(float/double) signature.
 *   - Values that look like pixel velocities (e.g. 100, 300) are never changed.
 *
 * If Bilibili uses a different clock API, the log dumps likely runtime methods
 * so the next build can target the exact class/selector instead of guessing.
 */

@interface GTDPassWindow : UIWindow @end
@implementation GTDPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static NSString *gLogPath = nil;
static dispatch_queue_t gLogQueue;
static NSMutableSet<NSString *> *gSeenLinks = nil;
static NSHashTable *gCandidateProxies = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gSpeedOrigIMPs = nil;
static NSMutableSet<NSString *> *gInstalledSpeedHooks = nil;
static const void *kGTDMetaKey = &kGTDMetaKey;
static const void *kGTDProxyKey = &kGTDProxyKey;
static volatile uint64_t gSpeedCaps = 0;

static NSInteger GTDMaxScreenFPS(void) {
    UIScreen *s = UIScreen.mainScreen;
    if ([s respondsToSelector:@selector(maximumFramesPerSecond)]) return s.maximumFramesPerSecond;
    return 60;
}
static BOOL GTDIs120Hz(void) { return GTDMaxScreenFPS() >= 120; }

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
    dispatch_once(&onceToken, ^{ terms = @[@"danmaku", @"danmu", @"barrage", @"bullet"]; });
    return terms;
}

static BOOL GTDClassLooksLikeDanmaku(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls) ?: @"";
    if ([name isEqualToString:@"BarrageClock"] || [name isEqualToString:@"BarrageRenderer"]) return YES;
    return GTDContainsAny(name, GTDStrongTerms());
}

static BOOL GTDLooksLikeDanmaku(id target, SEL selector) {
    NSString *cls = target ? NSStringFromClass([target class]) : @"";
    NSString *sel = selector ? NSStringFromSelector(selector) : @"";
    return GTDContainsAny(cls, GTDStrongTerms()) || GTDContainsAny(sel, GTDStrongTerms()) ||
           [cls isEqualToString:@"BarrageClock"] || [cls isEqualToString:@"BarrageRenderer"];
}

@interface GTDLinkMeta : NSObject
@property(nonatomic, copy) NSString *targetClass;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, assign) BOOL candidate;
@property(nonatomic, assign) NSInteger lastRequestedFPS;
@end
@implementation GTDLinkMeta @end

@interface GTDDisplayLinkProxy : NSObject
@property(nonatomic, strong) id originalTarget;
@property(nonatomic, assign) SEL originalSelector;
@property(nonatomic, weak) CADisplayLink *link;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) volatile uint64_t frameCount;
@property(nonatomic, assign) uint64_t lastCount;
@property(nonatomic, assign) CFTimeInterval lastTime;
@property(nonatomic, assign) double smoothedFPS;
- (void)gt_fire:(CADisplayLink *)link;
- (uint64_t)gt_atomicFrameCount;
@end

@implementation GTDDisplayLinkProxy
- (void)gt_fire:(CADisplayLink *)link {
    __sync_fetch_and_add(&_frameCount, 1);
    id t = self.originalTarget;
    SEL s = self.originalSelector;
    if (!t || !s || ![t respondsToSelector:s]) return;
    ((void(*)(id, SEL, id))objc_msgSend)(t, s, link);
}

- (uint64_t)gt_atomicFrameCount {
    return __sync_fetch_and_add(&_frameCount, 0);
}
@end

typedef CADisplayLink *(*GTDCreateDLIMP)(id, SEL, id, SEL);
typedef void (*GTDSetFPSIMP)(id, SEL, NSInteger);
typedef void (*GTDSetIntervalIMP)(id, SEL, NSInteger);
typedef void (*GTDSetScalarIMP)(id, SEL, CGFloat);

static GTDCreateDLIMP origCreateDL = NULL;
static GTDSetFPSIMP origSetPreferredFPS = NULL;
static GTDSetIntervalIMP origSetFrameInterval = NULL;

static NSString *GTDHookKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static IMP GTDOriginalScalarIMPForObject(id obj, SEL sel) {
    if (!obj || !sel) return NULL;
    Class cls = object_getClass(obj);
    // object_getClass(instance) returns its class; walk superclasses because
    // the hooked implementation may live on a parent class.
    while (cls) {
        NSString *key = GTDHookKey(cls, sel);
        NSNumber *v = nil;
        @synchronized (gSpeedOrigIMPs) { v = gSpeedOrigIMPs[key]; }
        if (v) return (IMP)(uintptr_t)[v unsignedLongLongValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void GTDHookedSetScalar(id self, SEL _cmd, CGFloat requested) {
    CGFloat adjusted = requested;
    // Playback-rate-like values only. Do NOT touch likely pixel velocities.
    if (requested > 1.001 && requested <= 4.001) {
        adjusted = 1.0;
        __sync_fetch_and_add(&gSpeedCaps, 1);
        static CFTimeInterval lastLog = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastLog > 0.25) {
            lastLog = now;
            GTDLog(@"SPEED CAP class=%@ sel=%@ %.3f -> %.3f",
                   NSStringFromClass([self class]), NSStringFromSelector(_cmd),
                   (double)requested, (double)adjusted);
        }
    }
    IMP orig = GTDOriginalScalarIMPForObject(self, _cmd);
    if (orig) ((GTDSetScalarIMP)orig)(self, _cmd, adjusted);
}

static BOOL GTDClassImplementsSelectorDirectly(Class cls, SEL sel, Method *outMethod) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    Method mFound = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            mFound = methods[i];
            break;
        }
    }
    free(methods);
    if (outMethod) *outMethod = mFound;
    return found;
}

static BOOL GTDScalarSetterSignatureIsSafe(Method m) {
    if (!m || method_getNumberOfArguments(m) != 3) return NO;
    char ret[16] = {0};
    char arg[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    method_getArgumentType(m, 2, arg, sizeof(arg));
    if (ret[0] != 'v') return NO;
    // This package only targets arm64/old-ABI arm64e, where CGFloat is double.
    // Do not hook float setters with a double-signature trampoline: that would
    // be an ABI mismatch and could crash.
    return arg[0] == 'd';
}

static void GTDInstallSpeedHookOnClass(Class cls, SEL sel) {
    if (!cls || !sel || !GTDClassLooksLikeDanmaku(cls)) return;
    Method m = NULL;
    if (!GTDClassImplementsSelectorDirectly(cls, sel, &m)) return;
    if (!GTDScalarSetterSignatureIsSafe(m)) return;

    NSString *key = GTDHookKey(cls, sel);
    @synchronized (gInstalledSpeedHooks) {
        if ([gInstalledSpeedHooks containsObject:key]) return;
        [gInstalledSpeedHooks addObject:key];
    }

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)GTDHookedSetScalar, &orig);
    if (orig) {
        @synchronized (gSpeedOrigIMPs) {
            gSpeedOrigIMPs[key] = @((unsigned long long)(uintptr_t)orig);
        }
        GTDLog(@"SPEED HOOK OK class=%@ selector=%@ encoding=%s",
               NSStringFromClass(cls), NSStringFromSelector(sel), method_getTypeEncoding(m));
    } else {
        GTDLog(@"SPEED HOOK FAIL class=%@ selector=%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    }
}

static void GTDDumpInterestingMethodsForClass(Class cls) {
    if (!cls || !GTDClassLooksLikeDanmaku(cls)) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSArray<NSString *> *terms = @[@"speed", @"rate", @"time", @"clock", @"update", @"tick", @"display", @"render", @"move"];
    for (unsigned int i = 0; i < count; i++) {
        NSString *s = NSStringFromSelector(method_getName(methods[i]));
        if (GTDContainsAny(s, terms)) [hits addObject:[NSString stringWithFormat:@"%@ <%s>", s, method_getTypeEncoding(methods[i])]];
    }
    free(methods);
    if (hits.count) GTDLog(@"CLASS METHODS %@ => %@", NSStringFromClass(cls), [hits componentsJoinedByString:@", "]);
}

static void GTDScanAndHookDanmakuSpeed(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0 || count > 100000) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    SEL setSpeed = @selector(setSpeed:);
    SEL setRate = NSSelectorFromString(@"setRate:");
    SEL setPlaybackRate = NSSelectorFromString(@"setPlaybackRate:");
    SEL setTimeScale = NSSelectorFromString(@"setTimeScale:");

    NSMutableArray<NSString *> *classNames = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!GTDClassLooksLikeDanmaku(cls)) continue;
        [classNames addObject:NSStringFromClass(cls) ?: @"?"];
        GTDInstallSpeedHookOnClass(cls, setSpeed);
        GTDInstallSpeedHookOnClass(cls, setRate);
        GTDInstallSpeedHookOnClass(cls, setPlaybackRate);
        GTDInstallSpeedHookOnClass(cls, setTimeScale);
        GTDDumpInterestingMethodsForClass(cls);
    }
    free(classes);
    [classNames sortUsingSelector:@selector(compare:)];
    GTDLog(@"RUNTIME danmaku classes (%lu): %@", (unsigned long)classNames.count, [classNames componentsJoinedByString:@", "]);
}

static void GTDAddCandidateProxy(GTDDisplayLinkProxy *proxy) {
    if (!proxy) return;
    void (^block)(void) = ^{
        if (!gCandidateProxies) gCandidateProxies = [NSHashTable weakObjectsHashTable];
        [gCandidateProxies addObject:proxy];
    };
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block);
}

static void GTDLogDisplayLinkOnce(id target, SEL selector, BOOL candidate) {
    NSString *cls = target ? NSStringFromClass([target class]) : @"nil";
    NSString *sel = selector ? NSStringFromSelector(selector) : @"nil";
    NSString *key = [NSString stringWithFormat:@"%@::%@", cls, sel];
    @synchronized (gSeenLinks) {
        if ([gSeenLinks containsObject:key]) return;
        [gSeenLinks addObject:key];
    }
    GTDLog(@"DL CREATE target=%@ selector=%@ candidate=%d", cls, sel, candidate);
}

static CADisplayLink *hookCreateDisplayLink(id clsObj, SEL _cmd, id target, SEL selector) {
    BOOL candidate = GTDLooksLikeDanmaku(target, selector);
    GTDLogDisplayLinkOnce(target, selector, candidate);
    if (!origCreateDL) return nil;

    if (!candidate) {
        CADisplayLink *link = origCreateDL(clsObj, _cmd, target, selector);
        if (link) {
            GTDLinkMeta *meta = [GTDLinkMeta new];
            meta.targetClass = target ? NSStringFromClass([target class]) : @"nil";
            meta.selectorName = selector ? NSStringFromSelector(selector) : @"nil";
            meta.candidate = NO;
            meta.lastRequestedFPS = 0;
            objc_setAssociatedObject(link, kGTDMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return link;
    }

    GTDDisplayLinkProxy *proxy = [GTDDisplayLinkProxy new];
    proxy.originalTarget = target;
    proxy.originalSelector = selector;
    proxy.name = [NSString stringWithFormat:@"%@::%@",
                  target ? NSStringFromClass([target class]) : @"nil",
                  selector ? NSStringFromSelector(selector) : @"nil"];

    CADisplayLink *link = origCreateDL(clsObj, _cmd, proxy, @selector(gt_fire:));
    if (!link) return nil;
    proxy.link = link;
    proxy.lastTime = CACurrentMediaTime();

    GTDLinkMeta *meta = [GTDLinkMeta new];
    meta.targetClass = target ? NSStringFromClass([target class]) : @"nil";
    meta.selectorName = selector ? NSStringFromSelector(selector) : @"nil";
    meta.candidate = YES;
    meta.lastRequestedFPS = 120;
    objc_setAssociatedObject(link, kGTDMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(link, kGTDProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GTDAddCandidateProxy(proxy);

    // If the display-link target itself owns a speed scalar, install the hook immediately.
    if (target) {
        GTDInstallSpeedHookOnClass([target class], @selector(setSpeed:));
        GTDInstallSpeedHookOnClass([target class], NSSelectorFromString(@"setRate:"));
        GTDInstallSpeedHookOnClass([target class], NSSelectorFromString(@"setPlaybackRate:"));
        GTDInstallSpeedHookOnClass([target class], NSSelectorFromString(@"setTimeScale:"));
    }

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

    GTDLog(@"DMK MATCH %@ forcedFPS=%ld", proxy.name, (long)(GTDIs120Hz() ? 120 : GTDMaxScreenFPS()));
    return link;
}

static void hookSetPreferredFPS(id self, SEL _cmd, NSInteger fps) {
    NSInteger adjusted = fps;
    GTDLinkMeta *meta = objc_getAssociatedObject(self, kGTDMetaKey);
    if (meta) {
        if (meta.lastRequestedFPS != fps) {
            meta.lastRequestedFPS = fps;
            GTDLog(@"DL FPS target=%@ selector=%@ candidate=%d request=%ld",
                   meta.targetClass, meta.selectorName, meta.candidate, (long)fps);
        }
        if (meta.candidate && GTDIs120Hz() && fps > 0 && fps < 120) adjusted = 120;
    }
    if (origSetPreferredFPS) origSetPreferredFPS(self, _cmd, adjusted);
}

static void hookSetFrameInterval(id self, SEL _cmd, NSInteger interval) {
    NSInteger adjusted = interval;
    GTDLinkMeta *meta = objc_getAssociatedObject(self, kGTDMetaKey);
    if (meta && meta.candidate && GTDIs120Hz() && interval > 1) adjusted = 1;
    if (origSetFrameInterval) origSetFrameInterval(self, _cmd, adjusted);
}

static void GTDInstallDisplayLinkHooks(void) {
    Class dl = [CADisplayLink class];
    Class meta = object_getClass(dl);
    Method createM = class_getClassMethod(dl, @selector(displayLinkWithTarget:selector:));
    if (createM && meta) MSHookMessageEx(meta, @selector(displayLinkWithTarget:selector:), (IMP)hookCreateDisplayLink, (IMP *)&origCreateDL);

    Method fpsM = class_getInstanceMethod(dl, @selector(setPreferredFramesPerSecond:));
    if (fpsM) MSHookMessageEx(dl, @selector(setPreferredFramesPerSecond:), (IMP)hookSetPreferredFPS, (IMP *)&origSetPreferredFPS);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Method intM = class_getInstanceMethod(dl, @selector(setFrameInterval:));
    if (intM) MSHookMessageEx(dl, @selector(setFrameInterval:), (IMP)hookSetFrameInterval, (IMP *)&origSetFrameInterval);
#pragma clang diagnostic pop

    GTDLog(@"HOOK displayLink create=%d fps=%d interval=%d", origCreateDL != NULL, origSetPreferredFPS != NULL, origSetFrameInterval != NULL);
}

@interface GTDOverlayController : NSObject
@property(nonatomic, strong) GTDPassWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
+ (instancetype)shared;
- (void)start;
@end

@implementation GTDOverlayController
+ (instancetype)shared {
    static GTDOverlayController *obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ obj = [GTDOverlayController new]; });
    return obj;
}

- (UIWindowScene *)foregroundWindowScene API_AVAILABLE(ios(13.0)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive)
            return (UIWindowScene *)scene;
    }
    return nil;
}

- (CGRect)statusBarFrame {
    CGRect f = CGRectZero;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.window.windowScene ?: [self foregroundWindowScene];
        if (scene.statusBarManager) f = scene.statusBarManager.statusBarFrame;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CGRectIsEmpty(f)) f = UIApplication.sharedApplication.statusBarFrame;
#pragma clang diagnostic pop
    if (CGRectIsEmpty(f) || CGRectGetHeight(f) < 1.0) f = CGRectMake(0, 0, CGRectGetWidth(UIScreen.mainScreen.bounds), 20.0);
    return f;
}

- (void)layoutOverlay {
    if (!self.window || !self.label) return;
    CGRect b = UIScreen.mainScreen.bounds;
    self.window.frame = b;
    CGRect sf = [self statusBarFrame];
    CGFloat h = MIN(19.0, MAX(18.0, CGRectGetHeight(sf)));
    CGSize wanted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    CGFloat w = MIN(MAX(1.0, ceil(wanted.width + 10.0)), 160.0);
    CGFloat cx = CGRectGetWidth(b) * 0.40;
    CGFloat cy = CGRectGetMinY(sf) + MAX(18.0, CGRectGetHeight(sf)) * 0.5;
    CGFloat x = MAX(2.0, MIN(round(cx - w * 0.5), CGRectGetWidth(b) - w - 2.0));
    CGFloat y = MAX(0.0, round(cy - h * 0.5));
    self.label.frame = CGRectIntegral(CGRectMake(x, y, w, h));
}

- (void)buildOverlay {
    if (self.window) return;
    GTDPassWindow *w = [[GTDPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 997.0;
    w.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self foregroundWindowScene];
        if (scene) w.windowScene = scene;
    }
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    w.rootViewController = root;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.18];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 5.0;
    label.layer.masksToBounds = YES;
    label.userInteractionEnabled = NO;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)])
        label.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    else label.font = [UIFont boldSystemFontOfSize:10.5];
    label.text = @"DMK -- 1x";
    [root.view addSubview:label];
    self.window = w;
    self.label = label;
    [self layoutOverlay];
    w.hidden = NO;
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    NSArray *proxies = gCandidateProxies ? gCandidateProxies.allObjects : @[];
    CFTimeInterval now = CACurrentMediaTime();
    double best = 0.0;
    NSString *bestName = nil;

    for (GTDDisplayLinkProxy *p in proxies) {
        uint64_t count = [p gt_atomicFrameCount];
        if (p.lastTime > 0.0 && now > p.lastTime && count >= p.lastCount) {
            double dt = now - p.lastTime;
            uint64_t delta = count - p.lastCount;
            if (dt > 0.10) {
                if (delta > 0) {
                    double raw = (double)delta / dt;
                    p.smoothedFPS = p.smoothedFPS <= 0.0 ? raw : p.smoothedFPS * 0.35 + raw * 0.65;
                } else p.smoothedFPS = 0.0;
            }
        }
        p.lastTime = now;
        p.lastCount = count;
        if (p.smoothedFPS > best) { best = p.smoothedFPS; bestName = p.name; }
    }

    if (proxies.count == 0) self.label.text = @"DMK -- 1x";
    else self.label.text = [NSString stringWithFormat:@"DMK %.0f/%ld 1x", best, (long)GTDMaxScreenFPS()];
    [self layoutOverlay];

    static int div = 0;
    if ((++div % 2) == 0)
        GTDLog(@"DMK FPS=%.3f candidates=%lu best=%@ speedCaps=%llu", best, (unsigned long)proxies.count, bestName ?: @"nil", (unsigned long long)gSpeedCaps);
}

- (void)start {
    if (self.timer) return;
    [self buildOverlay];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

static void GTDScheduleSpeedScans(void) {
    NSArray<NSNumber *> *delays = @[@0.2, @2.0, @5.0, @10.0, @20.0];
    for (NSNumber *n in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTDScanAndHookDanmakuSpeed();
        });
    }
}

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;

        gSeenLinks = [NSMutableSet set];
        gCandidateProxies = [NSHashTable weakObjectsHashTable];
        gSpeedOrigIMPs = [NSMutableDictionary dictionary];
        gInstalledSpeedHooks = [NSMutableSet set];
        gLogQueue = dispatch_queue_create("com.chatgpt.bilidanmaku120.log", DISPATCH_QUEUE_SERIAL);
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [docs stringByAppendingPathComponent:@"BiliDanmaku120.log"];

        GTDLog(@"BiliDanmaku120 0.2.0 START maxScreen=%ld home=%@ log=%@", (long)GTDMaxScreenFPS(), NSHomeDirectory(), gLogPath);
        GTDInstallDisplayLinkHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTDOverlayController shared] start];
            GTDScheduleSpeedScans();
        });
    }
}
