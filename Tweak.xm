#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>

/*
 * BiliDanmaku120 0.3.2 DanmakuClockProbe
 *
 * Device findings so far:
 *   - VID stays healthy when this tweak does NOT hook global CADisplayLink.
 *   - BFCCRONRenderViewV2::mainOnDisplayLink: fires at ~120 Hz.
 *   - BFCCommentFrameRateBooster::_displayLinkTick exists but did not provide a
 *     reliable visible counter in the previous build.
 *   - 2x/3x playback still makes scrolling comments move faster.
 *
 * 0.3.2 is intentionally read-only with respect to motion:
 *   1) Keep one exact callback counter for the on-screen DMK diagnostic.
 *   2) Remove the ineffective CALayer.speed mutation from 0.3.1.
 *   3) Hook BFCCRONRenderViewV2::_updateSyncForTimeStep: READ-ONLY and sample
 *      its double argument. This tells us whether media-time deltas scale with
 *      playback rate without risking video timing.
 *   4) Enumerate newly loaded Objective-C classes whose names look related to
 *      danmaku/barrage/comment/subtitle and dump only timing/motion methods,
 *      properties and ivars. No broad method hooks are installed.
 *
 * The next build should use the exact active class/clock discovered here to
 * split "when a comment appears" (media time) from "how fast it crosses the
 * screen" (wall time).
 */

@interface GTDPassWindow : UIWindow @end
@implementation GTDPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static NSString *gLogPath = nil;
static dispatch_queue_t gLogQueue;
static const unsigned long long gMaxLogBytes = 256ULL * 1024ULL;
static NSMutableSet<NSString *> *gDumpedClasses = nil;
static NSMutableSet<NSString *> *gCandidateClasses = nil;
static volatile uint64_t gDmkTickCount = 0;
static BOOL gTickHooked = NO;
static NSString *gTickSource = nil;

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

static BOOL GTDMethodOneDoubleArg(Method m) {
    if (!m || method_getNumberOfArguments(m) != 3 || !GTDMethodReturnsVoid(m)) return NO;
    char arg[32] = {0};
    method_getArgumentType(m, 2, arg, sizeof(arg));
    return arg[0] == 'd';
}

#pragma mark - Structural dump

static void GTDDumpClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls || className.length == 0) return;
    @synchronized (gDumpedClasses) {
        if ([gDumpedClasses containsObject:className]) return;
        [gDumpedClasses addObject:className];
    }

    NSArray<NSString *> *terms = @[
        @"speed", @"rate", @"time", @"clock", @"tick", @"display", @"render",
        @"comment", @"danmaku", @"danmu", @"barrage", @"bullet", @"subtitle",
        @"duration", @"progress", @"position", @"frame", @"move", @"offset",
        @"animation", @"track", @"lane", @"start", @"end", @"sync", @"step"
    ];

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

static BOOL GTDIsCandidateClassName(NSString *name) {
    if (name.length == 0) return NO;
    NSArray<NSString *> *terms = @[@"danmaku", @"danmu", @"barrage", @"bullet", @"subtitle", @"comment", @"marquee"];
    return GTDNameContainsAny(name, terms);
}

static void GTDScanCandidateClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0 || count > 200000) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    int got = objc_getClassList(classes, count);
    NSMutableArray<NSString *> *newNames = [NSMutableArray array];
    for (int i = 0; i < got; i++) {
        const char *n = class_getName(classes[i]);
        if (!n) continue;
        NSString *name = [NSString stringWithUTF8String:n];
        if (!GTDIsCandidateClassName(name)) continue;
        BOOL isNew = NO;
        @synchronized (gCandidateClasses) {
            if (![gCandidateClasses containsObject:name]) {
                [gCandidateClasses addObject:name];
                isNew = YES;
            }
        }
        if (isNew) [newNames addObject:name];
    }
    free(classes);

    if (newNames.count > 0) {
        [newNames sortUsingSelector:@selector(compare:)];
        GTDLog(@"CANDIDATE NEW count=%lu names=%@", (unsigned long)newNames.count, [newNames componentsJoinedByString:@", "]);
        NSUInteger limit = MIN((NSUInteger)80, newNames.count);
        for (NSUInteger i = 0; i < limit; i++) GTDDumpClass([newNames objectAtIndex:i]);
    }
}

#pragma mark - Exact callback counter

static void (*gOrigTickNoArg)(id, SEL) = NULL;
static void (*gOrigTickOneObj)(id, SEL, id) = NULL;

static void GTDTickNoArgHook(id self, SEL _cmd) {
    __sync_fetch_and_add(&gDmkTickCount, 1);
    if (gOrigTickNoArg) gOrigTickNoArg(self, _cmd);
}

static void GTDTickOneObjHook(id self, SEL _cmd, id sender) {
    __sync_fetch_and_add(&gDmkTickCount, 1);
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
    if (GTDTryHookTickCandidate(@"BFCCRONRenderViewV2", @"mainOnDisplayLink:")) return;
    if (GTDTryHookTickCandidate(@"BFCCRONRenderViewV2", @"onDisplayLink:")) return;
    if (GTDTryHookTickCandidate(@"BFCCommentFrameRateBooster", @"_displayLinkTick")) return;
    (void)GTDTryHookTickCandidate(@"BFCDisplayLink", @"displayLinkDidRefresh:");
}

#pragma mark - Read-only CRON time-step probe

static BOOL gStepHooked = NO;
static void (*gOrigUpdateSyncForTimeStep)(id, SEL, double) = NULL;
static volatile uint64_t gStepCalls = 0;
static double gLastStepLogged = 0.0;
static CFTimeInterval gLastStepLogTime = 0.0;

static void GTDUpdateSyncForTimeStepHook(id self, SEL _cmd, double step) {
    uint64_t n = __sync_add_and_fetch(&gStepCalls, 1);
    CFTimeInterval now = CACurrentMediaTime();
    if ((n <= 8) || (now - gLastStepLogTime >= 1.0 && fabs(step - gLastStepLogged) >= 0.001)) {
        gLastStepLogTime = now;
        gLastStepLogged = step;
        GTDLog(@"STEP sample class=%@ value=%.6f call=%llu", NSStringFromClass([self class]), step, (unsigned long long)n);
    }
    if (gOrigUpdateSyncForTimeStep) gOrigUpdateSyncForTimeStep(self, _cmd, step);
}

static void GTDTryInstallStepProbe(void) {
    if (gStepHooked) return;
    Class cls = NSClassFromString(@"BFCCRONRenderViewV2");
    SEL sel = NSSelectorFromString(@"_updateSyncForTimeStep:");
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) return;
    NSString *enc = GTDMethodEncoding(m);
    GTDLog(@"STEP candidate BFCCRONRenderViewV2::_updateSyncForTimeStep: encoding=%@ argc=%u", enc, method_getNumberOfArguments(m));
    if (!GTDMethodOneDoubleArg(m)) {
        GTDLog(@"STEP skip unsupported ABI encoding=%@", enc);
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)GTDUpdateSyncForTimeStepHook, &orig);
    if (orig) {
        gOrigUpdateSyncForTimeStep = (void(*)(id,SEL,double))orig;
        gStepHooked = YES;
        GTDLog(@"STEP hook OK readOnly=YES");
    }
}

static void GTDProbe(void) {
    GTDDumpClass(@"BFCDisplayLink");
    GTDDumpClass(@"BFCCRONRenderViewV2");
    GTDDumpClass(@"BFCCommentFrameRateBooster");
    GTDTryInstallTickHook();
    GTDTryInstallStepProbe();
    GTDScanCandidateClasses();
}

#pragma mark - Overlay

@interface GTDOverlay : NSObject
@property(nonatomic, strong) GTDPassWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) uint64_t lastCount;
@property(nonatomic, assign) CFTimeInterval lastTime;
@property(nonatomic, assign) double smoothFPS;
@property(nonatomic, assign) NSUInteger probeTick;
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
    self.probeTick += 1;
    if (self.probeTick <= 20 || (self.probeTick % 10) == 0) GTDProbe();

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
        gCandidateClasses = [NSMutableSet set];
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [docs stringByAppendingPathComponent:@"BiliDanmaku120.log"];
        GTDLog(@"BiliDanmaku120 0.3.2 START maxScreen=%ld globalCADisplayLinkHook=NO motionMutation=NO", (long)GTDMaxScreenFPS());

        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTDOverlay shared] start];
            const double delays[] = {0.2, 1.0, 2.0, 4.0, 8.0, 15.0, 30.0};
            for (unsigned int i = 0; i < sizeof(delays)/sizeof(delays[0]); i++) {
                double d = delays[i];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GTDProbe(); });
            }
        });
    }
}
