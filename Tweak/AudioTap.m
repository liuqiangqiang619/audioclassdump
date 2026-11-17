// TLAudioTap — 把天乐送来的 PCM 写进抖音采集到的麦克风数据里
// 原理：dyld __interpose 拦截 AudioUnitRender（抖音拉麦克风数据的唯一入口），
//       在返回前用我们收到的 PCM 覆盖 ioData 缓冲。
// 数据源：本机监听 9803，接收 16 字节头（>IIIBBH: len,seq,pts,type,flags,rsv）+ PCM(s16le/48k/2ch)
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>

#define TL_LOAD_PORT 9803
#define TL_RING_SAMPLES (48000 * 2 * 3)   // 3 秒立体声

static AudioStreamBasicDescription g_fmt;
static BOOL g_haveFmt = NO;

static int16_t g_ring[TL_RING_SAMPLES];
static size_t g_ringW = 0, g_ringR = 0, g_ringN = 0;
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;

static uint64_t g_renderCnt = 0, g_paintCnt = 0, g_rxBytes = 0, g_rxFrames = 0;
static uint64_t g_dropSamples = 0, g_underSamples = 0;
static uint64_t g_lastRxMs = 0;

static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                             AudioUnitElement, const void *, UInt32);
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static uint64_t nowMs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + ts.tv_nsec / 1000000ull;
}

static void ringPush(const int16_t *p, size_t n) {
    pthread_mutex_lock(&g_mtx);
    for (size_t i = 0; i < n; i++) {
        g_ring[g_ringW] = p[i];
        g_ringW = (g_ringW + 1) % TL_RING_SAMPLES;
        if (g_ringN < TL_RING_SAMPLES) g_ringN++;
        else g_ringR = (g_ringR + 1) % TL_RING_SAMPLES;   // 覆盖最旧
    }
    pthread_mutex_unlock(&g_mtx);
}

static size_t ringPop(int16_t *out, size_t need) {
    size_t got = 0;
    pthread_mutex_lock(&g_mtx);
    while (got < need && g_ringN > 0) {
        out[got++] = g_ring[g_ringR];
        g_ringR = (g_ringR + 1) % TL_RING_SAMPLES;
        g_ringN--;
    }
    pthread_mutex_unlock(&g_mtx);
    return got;
}

// ---------- 网络接收 ----------
static BOOL readFull(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = recv(fd, (char *)buf + off, n - off, 0);
        if (r <= 0) return NO;
        off += (size_t)r;
    }
    return YES;
}

static void *listenThread(void *arg) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { NSLog(@"[TAP] socket failed"); return NULL; }
    int on = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_port = htons(TL_LOAD_PORT); a.sin_addr.s_addr = INADDR_ANY;
    if (bind(srv, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(srv, 4) != 0) {
        NSLog(@"[TAP] bind/listen %d failed errno=%d", TL_LOAD_PORT, errno);
        close(srv); return NULL;
    }
    NSLog(@"[TAP] pcm listen %d", TL_LOAD_PORT);
    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) { usleep(200000); continue; }
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on)); on = 1;
        NSLog(@"[TAP] pcm connected");
        uint8_t hdr[16];
        while (readFull(c, hdr, 16)) {
            uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                           ((uint32_t)hdr[2] << 8) | (uint32_t)hdr[3];
            if (len == 0 || len > 65536) break;
            uint8_t *buf = malloc(len);
            if (!buf) break;
            if (!readFull(c, buf, len)) { free(buf); break; }
            ringPush((const int16_t *)buf, len / 2);
            g_rxBytes += len; g_rxFrames += len / 4;
            g_lastRxMs = nowMs();
            free(buf);
        }
        NSLog(@"[TAP] pcm disconnected bytes=%llu", g_rxBytes);
        close(c); on = 1;
    }
    return NULL;
}

// ---------- 写入采集缓冲 ----------
static void paint(AudioBufferList *io, UInt32 inFrames) {
    if (!io || io->mNumberBuffers == 0 || inFrames == 0) return;
    UInt32 ch = g_haveFmt && g_fmt.mChannelsPerFrame ? g_fmt.mChannelsPerFrame : 2;
    if (ch > 2) ch = 2;
    BOOL isFloat = g_haveFmt ? ((g_fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0) : YES;
    BOOL nonInt  = g_haveFmt ? ((g_fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) : NO;

    static int16_t tmp[4096 * 2];
    UInt32 frames = inFrames > 4096 ? 4096 : inFrames;
    size_t need = (size_t)frames * ch;

    // ---- 抖动缓冲：把积压控制在 150ms，多了丢最旧的、少了补静音 ----
    {
        static const size_t TARGET = 48000 * 2 * 150 / 1000;          // 150ms（交错采样数）
        static const size_t HARD   = TARGET + 48000 * 2 * 200 / 1000; // 350ms 以上直接跳到目标
        if (g_ringN > HARD) {
            size_t drop = g_ringN - TARGET;
            drop -= drop % ch;
            g_ringR = (g_ringR + drop) % TL_RING_SAMPLES;
            g_ringN -= drop;
            g_dropSamples += drop;
        } else if (g_ringN > TARGET + 960) {
            size_t drop = g_ringN - TARGET;
            if (drop > 240) drop = 240;
            drop -= drop % ch;
            if (drop) {
                g_ringR = (g_ringR + drop) % TL_RING_SAMPLES;
                g_ringN -= drop;
                g_dropSamples += drop;
            }
        }
    }

    size_t got = ringPop(tmp, need);
    if (got < need) g_underSamples += (need - got);
    // 注意：没有数据时也继续往下走，用静音覆盖，绝不让真麦克风漏出去
    for (size_t i = got; i < need; i++) tmp[i] = 0;

    if (isFloat) {
        if (nonInt && io->mNumberBuffers >= ch) {
            for (UInt32 c = 0; c < ch; c++) {
                float *dst = (float *)io->mBuffers[c].mData;
                UInt32 cap = io->mBuffers[c].mDataByteSize / 4;
                for (UInt32 f = 0; f < frames && f < cap; f++) dst[f] = tmp[(size_t)f * ch + c] / 32768.0f;
            }
        } else {
            float *dst = (float *)io->mBuffers[0].mData;
            UInt32 cap = io->mBuffers[0].mDataByteSize / 4;
            size_t k = 0;
            for (UInt32 f = 0; f < frames; f++)
                for (UInt32 c = 0; c < ch; c++)
                    if (k < cap) dst[k++] = tmp[(size_t)f * ch + c] / 32768.0f;
        }
    } else {
        if (nonInt && io->mNumberBuffers >= ch) {
            for (UInt32 c = 0; c < ch; c++) {
                int16_t *dst = (int16_t *)io->mBuffers[c].mData;
                UInt32 cap = io->mBuffers[c].mDataByteSize / 2;
                for (UInt32 f = 0; f < frames && f < cap; f++) dst[f] = tmp[(size_t)f * ch + c];
            }
        } else {
            int16_t *dst = (int16_t *)io->mBuffers[0].mData;
            UInt32 cap = io->mBuffers[0].mDataByteSize / 2;
            size_t k = 0;
            for (UInt32 f = 0; f < frames; f++)
                for (UInt32 c = 0; c < ch; c++)
                    if (k < cap) dst[k++] = tmp[(size_t)f * ch + c];
        }
    }
    g_paintCnt++;
    if (g_paintCnt % 200 == 1) {
        NSLog(@"[TAP] painted #%llu frames=%u ch=%u float=%d nonint=%d ring=%zu drop=%llu under=%llu rx=%llu",
              g_paintCnt, (unsigned)frames, (unsigned)ch, (int)isFloat, (int)nonInt,
              g_ringN, g_dropSamples, g_underSamples, g_rxBytes);
    }
}

static OSStatus my_AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID pid, AudioUnitScope scope,
                                        AudioUnitElement elem, const void *data, UInt32 size) {
    if (pid == kAudioUnitProperty_StreamFormat && data && size >= sizeof(AudioStreamBasicDescription)) {
        memcpy(&g_fmt, data, sizeof(AudioStreamBasicDescription));
        g_haveFmt = YES;
    }
    return orig_AudioUnitSetProperty(unit, pid, scope, elem, data, size);
}

static OSStatus my_AudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                   const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                                   AudioBufferList *io) {
    OSStatus st = orig_AudioUnitRender(unit, flags, ts, bus, frames, io);
    g_renderCnt++;
    if (g_renderCnt == 1) {
        NSLog(@"[TAP] first render frames=%u bufs=%u sr=%.0f ch=%u fmt=%u flags=0x%x bpf=%u bpp=%u",
              (unsigned)frames, io ? io->mNumberBuffers : 0, g_fmt.mSampleRate,
              (unsigned)g_fmt.mChannelsPerFrame, (unsigned)g_fmt.mFormatID,
              (unsigned)g_fmt.mFormatFlags, (unsigned)g_fmt.mBytesPerFrame,
              (unsigned)g_fmt.mBytesPerPacket);
    }
    if (g_ringN > 0) paint(io, frames);
    return st;
}

__attribute__((used)) static struct { const void *replacement; const void *replacee; }
tl_interpose_setprop __attribute__((section("__DATA,__interpose"))) = {
    (const void *)my_AudioUnitSetProperty, (const void *)AudioUnitSetProperty };
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
tl_interpose_render __attribute__((section("__DATA,__interpose"))) = {
    (const void *)my_AudioUnitRender, (const void *)AudioUnitRender };

__attribute__((constructor))
static void TAPInit(void) {
    orig_AudioUnitSetProperty = (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                              AudioUnitElement, const void *, UInt32))AudioUnitSetProperty;
    orig_AudioUnitRender = (OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *,
                                         const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *))AudioUnitRender;
    NSLog(@"[TAP] loaded (pcm in %d)", TL_LOAD_PORT);
    pthread_t t;
    pthread_create(&t, NULL, listenThread, NULL);
}
