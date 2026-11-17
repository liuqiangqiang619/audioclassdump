// TLAudioDump 鈥?鍙璇婃柇锛氭妸鎶栭煶閲屼笌闊抽鐩稿叧鐨勭被/閫夋嫨瀛愬鍑烘潵锛屼笉鍙戜换浣?hook銆?// 涓嶄細鏀瑰彉 App 琛屼负锛岃閿欎篃涓嶄細宕╋紙涓?hook 浠讳綍鏂规硶锛夈€?#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

#define TLDUMP_PORT 9806
static NSString *g_host = @"192.168.10.2";

static BOOL HasAny(NSString *s, NSArray<NSString *> *keys) {
    for (NSString *k in keys) { if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES; }
    return NO;
}

static NSArray<NSString *> *ClassKeys(void) {
    return @[@"audio", @"rtc", @"byte", @"velive", @"ttvideo", @"live", @"capture",
             @"mic", @"sound", @"pcm", @"media", @"codec", @"avf", @"record"];
}

static NSArray<NSString *> *SelKeys(void) {
    return @[@"audio", @"pcm", @"mic", @"capture", @"render", @"push", @"send",
             @"buffer", @"sample", @"frame", @"stream", @"codec", @"record", @"volume"];
}

static NSString *DumpClasses(void) {
    NSMutableString *out = [NSMutableString stringWithCapacity:1 << 20];
    [out appendFormat:@"# device %@  %@\n", [[UIDevice currentDevice] systemVersion], [[UIDevice currentDevice] model]];

    uint32_t n = 0;
    Class *all = objc_copyClassList(&n);
    [out appendFormat:@"# classes total %u\n", n];

    NSArray *ck = ClassKeys(), *sk = SelKeys();
    int emitted = 0;
    for (uint32_t i = 0; i < n && emitted < 3000; i++) {
        Class c = all[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        if (!HasAny(name, ck)) continue;

        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        unsigned mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned k = 0; k < mc; k++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[k]));
            if (HasAny(sel, sk)) [hits addObject:[@"  - " stringByAppendingString:sel]];
        }
        free(ms);

        Class meta = object_getClass(c);
        unsigned mcc = 0;
        Method *mcs = meta ? class_copyMethodList(meta, &mcc) : NULL;
        for (unsigned k = 0; k < mcc; k++) {
            NSString *sel = NSStringFromSelector(method_getName(mcs[k]));
            if (HasAny(sel, sk)) [hits addObject:[@"  + " stringByAppendingString:sel]];
        }
        free(mcs);

        if (hits.count == 0) continue;
        Class sup = class_getSuperclass(c);
        [out appendFormat:@"C %@ : %s (%lu)\n", name, sup ? class_getName(sup) : "-", (unsigned long)hits.count];
        for (NSString *h in hits) [out appendFormat:@"%@\n", h];
        emitted++;
    }
    free(all);
    [out appendFormat:@"# emitted classes %d\n", emitted];

    /* 鍔犺浇鐨勯暅鍍忥紝渚夸簬鐪嬫姈闊崇敤浜嗗摢浜?RTC 搴?*/
    uint32_t ic = _dyld_image_count();
    [out appendString:@"# images\n"];
    for (uint32_t i = 0; i < ic; i++) {
        const char *p = _dyld_get_image_name(i);
        if (p) [out appendFormat:@"I %s\n", p];
    }
    return out;
}

static BOOL SendAll(NSString *text) {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    const char *host = g_host.UTF8String;
    for (int attempt = 0; attempt < 3; attempt++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return NO;
        struct sockaddr_in a = {0};
        a.sin_family = AF_INET; a.sin_port = htons(TLDUMP_PORT);
        a.sin_addr.s_addr = inet_addr(host);
        if (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0) {
            char hdr[64];
            int hl = snprintf(hdr, sizeof(hdr), "LEN %lu\n", (unsigned long)d.length);
            send(s, hdr, hl, 0);
            const uint8_t *p = d.bytes;
            size_t left = d.length;
            while (left > 0) {
                ssize_t w = send(s, p, left, 0);
                if (w <= 0) break;
                p += w; left -= (size_t)w;
            }
            close(s);
            return left == 0;
        }
        close(s);
        usleep(500 * 1000);
    }
    return NO;
}

__attribute__((constructor))
static void TLDumpInit(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                NSString *txt = DumpClasses();
                NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tl_classes.txt"];
                [txt writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                BOOL ok = SendAll(txt);
                NSLog(@"[TLDUMP] classes written %lu bytes, sent=%d", (unsigned long)txt.length, ok);
            } @catch (NSException *e) {
                NSLog(@"[TLDUMP] exception %@", e);
            }
        });
    }
}
