// TLAudioProbe — 只读探针：找出抖音把 PCM 送进 RTC 的那个方法，并打印参数。
// 不改数据、不改 delegate、不碰 AVCaptureSession，只 hook 这几个"送帧"方法做计数与打印。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSMutableDictionary<NSString *, NSNumber *> *g_hits;
static BOOL g_dumped = NO;

static IMP OrigFor(id self, SEL cmd) {
    Method m = class_getInstanceMethod(object_getClass(self), cmd);
    return m ? method_getImplementation(m) : NULL;
}

static void LogOnce(NSString *key, NSString *line) {
    @synchronized (g_hits) {
        NSNumber *n = g_hits[key];
        if (n == nil) {
            g_hits[key] = @1;
            NSLog(@"[TLP] %@", line);
        } else {
            g_hits[key] = @(n.integerValue + 1);
        }
    }
}

/* -pushExternalAudioFrame: */
static void probe_pushExternalAudioFrame(id self, SEL _cmd, id arg) {
    IMP o = OrigFor(self, _cmd);
    LogOnce([NSString stringWithFormat:@"ext:%@", NSStringFromClass([self class])],
            [NSString stringWithFormat:@"pushExternalAudioFrame cls=%@ argClass=%@",
             NSStringFromClass([self class]), NSStringFromClass([arg class])]);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
}

/* -pushExternalAudioFrame:dataSize:pcmType:sampleRate:channelNumber:ptsMs: */
static void probe_pushExternalAudioFrameFull(id self, SEL _cmd, void *data, NSUInteger size,
                                             int pcmType, int rate, int ch, long long pts) {
    IMP o = OrigFor(self, _cmd);
    LogOnce([NSString stringWithFormat:@"extfull:%@", NSStringFromClass([self class])],
            [NSString stringWithFormat:@"pushExternalAudioFrameFull cls=%@ size=%lu rate=%d ch=%d pcmType=%d",
             NSStringFromClass([self class]), (unsigned long)size, rate, ch, pcmType]);
    if (o) ((void (*)(id, SEL, void *, NSUInteger, int, int, int, long long))o)(self, _cmd, data, size, pcmType, rate, ch, pts);
}

/* -pushAudioBuffer:inNumberFrames:bytesPerSample:audioChannelCount:sampleRate:timestampUs: */
static void probe_pushAudioBuffer(id self, SEL _cmd, void *buf, unsigned frames, unsigned bps,
                                  unsigned ch, double rate, unsigned long long ts) {
    IMP o = OrigFor(self, _cmd);
    LogOnce([NSString stringWithFormat:@"buf:%@", NSStringFromClass([self class])],
            [NSString stringWithFormat:@"pushAudioBuffer cls=%@ frames=%u bps=%u ch=%u rate=%.0f",
             NSStringFromClass([self class]), frames, bps, ch, rate]);
    if (o) ((void (*)(id, SEL, void *, unsigned, unsigned, unsigned, double, unsigned long long))o)(self, _cmd, buf, frames, bps, ch, rate, ts);
}

/* -setAudioSourceType: */
static void probe_setAudioSourceType(id self, SEL _cmd, long type) {
    IMP o = OrigFor(self, _cmd);
    LogOnce([NSString stringWithFormat:@"src:%@:%ld", NSStringFromClass([self class]), type],
            [NSString stringWithFormat:@"setAudioSourceType cls=%@ type=%ld", NSStringFromClass([self class]), type]);
    if (o) ((void (*)(id, SEL, long))o)(self, _cmd, type);
}

static void HookSel(SEL sel, IMP repl, const char *name) {
    int hooked = 0;
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) {
        Class c = all[i];
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        /* 只 hook 真正实现它的那个类 */
        Class sup = class_getSuperclass(c);
        if (sup) {
            Method ms = class_getInstanceMethod(sup, sel);
            if (ms && method_getImplementation(ms) == method_getImplementation(m)) continue;
        }
        method_setImplementation(m, repl);
        hooked++;
    }
    free(all);
    NSLog(@"[TLP] hooked %s on %d class(es)", name, hooked);
}

static void InstallProbes(void) {
    if (g_dumped) return;
    g_dumped = YES;
    g_hits = [NSMutableDictionary dictionary];
    HookSel(@selector(pushExternalAudioFrame:), (IMP)probe_pushExternalAudioFrame, "pushExternalAudioFrame:");
    HookSel(NSSelectorFromString(@"pushExternalAudioFrame:dataSize:pcmType:sampleRate:channelNumber:ptsMs:"),
            (IMP)probe_pushExternalAudioFrameFull, "pushExternalAudioFrame:dataSize:...");
    HookSel(NSSelectorFromString(@"pushAudioBuffer:inNumberFrames:bytesPerSample:audioChannelCount:sampleRate:timestampUs:"),
            (IMP)probe_pushAudioBuffer, "pushAudioBuffer:inNumberFrames:...");
    HookSel(@selector(setAudioSourceType:), (IMP)probe_setAudioSourceType, "setAudioSourceType:");
    NSLog(@"[TLP] probes installed");
}

__attribute__((constructor))
static void TLPInit(void) {
    @autoreleasepool {
        NSLog(@"[TLP] probe dylib loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { InstallProbes(); } @catch (NSException *e) { NSLog(@"[TLP] ex %@", e); }
        });
        /* 每 10 秒汇总一次调用次数 */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (1) {
                sleep(10);
                @synchronized (g_hits) {
                    if (g_hits.count == 0) continue;
                    NSMutableArray *parts = [NSMutableArray array];
                    for (NSString *k in g_hits) [parts addObject:[NSString stringWithFormat:@"%@=%d", k, g_hits[k].intValue]];
                    NSLog(@"[TLP] stats %@", [parts componentsJoinedByString:@" "]);
                }
            }
        });
    }
}
