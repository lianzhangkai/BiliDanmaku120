#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>

/*
 * BiliDanmaku120 0.3.1 ExactTickLayerProbe
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
static volatile uint64_t gDmkTickCount = 0;
static BOOL gTickHooked = NO;

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

#pragma mark - Exact BFC callback counter + safe CRON layer probe

// We hook ONE exact callback only, in priority order. This avoids double-counting
// when BFCCRONRenderViewV2 owns more than one CADisplayLink.
static NSString *gTickSource = nil;
static void (*gOrigTickNoArg)(id, SEL) = NULL;
static void (*gOrigTickOneObj)(id, SEL, id) = NULL;
static volatile uint64_t gLayerSpeedClampCount = 0;

static BOOL GTDMethodReturnsVoid(Method m) {
    if (!m) return NO;
    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == 'v';
}

static BOOL GTDMethodOneObjectArg(Method m) {
    if (!m || method_getNumberOfArguments(m) != 3 || !GTDMethodReturnsVoid(m)) return NO;
    char arg[64] = {0};
    method_getArgumentType(m, 2, arg, sizeof(arg));
    return arg[0] == '@';
}

static BOOL GTDMethodNoExplicitArg(Method m) {
    return m && method_getNumberOfArguments(m) == 2 && GTDMethodReturnsVoid(m);
}

static CALayer *GTDLayerForRenderObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[UIView class]]) return ((UIView *)obj).layer;
    SEL layerSel = NSSelectorFromString(@"layer");
    if ([obj respondsToSelector:layerSel]) {
        id layer = ((id(*)(id,SEL))objc_msgSend)(obj, layerSel);
        if ([layer isKindOfClass:[CALayer class]]) return (CALayer *)layer;
    }
    return nil;
}

static void GTDNormalizeCRONLayerSpeed(id self) {
    if (![NSStringFromClass([self class]) isEqualToString:@"BFCCRONRenderViewV2"]) return;
    CALayer *layer = GTDLayerForRenderObject(self);
    if (!layer) return;
    float speed = layer.speed;
    if (!(speed > 1.001f && speed <= 4.001f)) return;

    // Preserve the layer's local time while returning its animation clock to 1x.
    // If Bilibili drives comment motion manually from media time, this will have
    // no effect; it is intentionally limited to this exact comment render view.
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval localBefore = [layer convertTime:now fromLayer:nil];
    layer.speed = 1.0f;
    layer.timeOffset = 0.0;
    layer.beginTime = 0.0;
    CFTimeInterval localAfter = [layer convertTime:now fromLayer:nil];
    layer.beginTime = localAfter - localBefore;

    uint64_t n = __sync_add_and_fetch(&gLayerSpeedClampCount, 1);
    if (n <= 12) GTDLog(@"LAYER SPEED CAP class=BFCCRONRenderViewV2 %.3f -> 1.000", speed);
}

static void GTDTickNoArgHook(id self, SEL _cmd) {
    __sync_fetch_and_add(&gDmkTickCount, 1);
    GTDNormalizeCRONLayerSpeed(self);
    if (gOrigTickNoArg) gOrigTickNoArg(self, _cmd);
}

static void GTDTickOneObjHook(id self, SEL _cmd, id sender) {
    __sync_fetch_and_add(&gDmkTickCount, 1);
    GTDNormalizeCRONLayerSpeed(self);
    if (gOrigTickOneObj) gOrigTickOneObj(self, _cmd, sender);
}

static BOOL GTDTryHookTickCandidate(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    NSString *enc = GTDMethodEncoding(m);
    unsigned int argc = method_getNumberOfArguments(m);
    GTDLog(@"TICK candidate %@::%@ encoding=%@ argc=%u", className, selectorName, enc, argc);

    IMP orig = NULL;
    if (GTDMethodNoExplicitArg(m)) {
        MSHookMessageEx(cls, sel, (IMP)GTDTickNoArgHook, &orig);
        if (orig) {
            gOrigTickNoArg = (void(*)(id,SEL))orig;
            gTickSource = [NSString stringWithFormat:@"%@::%@", className, selectorName];
            gTickHooked = YES;
            GTDLog(@"TICK hook OK source=%@ mode=noarg", gTickSource);
            return YES;
        }
    } else if (GTDMethodOneObjectArg(m)) {
        MSHookMessageEx(cls, sel, (IMP)GTDTickOneObjHook, &orig);
        if (orig) {
            gOrigTickOneObj = (void(*)(id,SEL,id))orig;
            gTickSource = [NSString stringWithFormat:@"%@::%@", className, selectorName];
            gTickHooked = YES;
            GTDLog(@"TICK hook OK source=%@ mode=objectArg", gTickSource);
            return YES;
        }
    }

    GTDLog(@"TICK skip %@::%@ unsupported ABI encoding=%@", className, selectorName, enc);
    return NO;
}

static void GTDTryInstallTickHook(void) {
    if (gTickHooked) return;

    // Prefer the actual CRON render view callback, because it is the best proxy
    // for on-screen comment updates and also lets us inspect only its own layer.
    if (GTDTryHookTickCandidate(@"BFCCRONRenderViewV2", @"mainOnDisplayLink:")) return;
    if (GTDTryHookTickCandidate(@"BFCCRONRenderViewV2", @"onDisplayLink:")) return;
    if (GTDTryHookTickCandidate(@"BFCCommentFrameRateBooster", @"_displayLinkTick")) return;
    (void)GTDTryHookTickCandidate(@"BFCDisplayLink", @"displayLinkDidRefresh:");
}

#pragma mark - Exact class probe

// 0.3.0's generic speed/rate setter guesses did not affect this Bilibili build.
// 0.3.1 intentionally removes those hooks. We keep a one-time structural dump
// of the exact BFC classes so the next iteration can target the real media-time
// coupling instead of guessing more setter names.

static void GTDProbeExactClasses(void) {
    NSArray<NSString *> *classes = @[@"BFCDisplayLink", @"BFCCRONRenderViewV2", @"BFCCommentFrameRateBooster"];
    for (NSString *name in classes) GTDDumpExactClass(name);
    GTDTryInstallTickHook();
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
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [docs stringByAppendingPathComponent:@"BiliDanmaku120.log"];
        GTDLog(@"BiliDanmaku120 0.3.1 START maxScreen=%ld globalCADisplayLinkHook=NO", (long)GTDMaxScreenFPS());

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
