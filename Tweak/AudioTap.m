// TLAudioTap — 用 dyld __interpose 拦截 AudioUnit 的 C API（只记录，不改数据）
// 目的：确认抖音的麦克风采集是不是走 RemoteIO/AudioUnit，并拿到 render 回调与格式。
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

static uint64_t g_setPropCnt = 0;
static uint64_t g_renderCnt = 0;
static uint64_t g_initCnt = 0;
static AudioStreamBasicDescription g_lastFmt;
static BOOL g_haveFmt = NO;
static AURenderCallbackStruct g_lastCB;

static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                             AudioUnitElement, const void *, UInt32);
static OSStatus (*orig_AudioUnitInitialize)(AudioUnit);
static OSStatus (*orig_AudioOutputUnitStart)(AudioUnit);
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static OSStatus my_AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID pid, AudioUnitScope scope,
                                        AudioUnitElement elem, const void *data, UInt32 size) {
    g_setPropCnt++;
    if (pid == kAudioUnitProperty_StreamFormat && data && size >= sizeof(AudioStreamBasicDescription)) {
        memcpy(&g_lastFmt, data, sizeof(AudioStreamBasicDescription));
        g_haveFmt = YES;
        NSLog(@"[TAP] StreamFormat scope=%u elem=%u sr=%.0f ch=%u fmt=%u bits=%u bytesPerFrame=%u",
              (unsigned)scope, (unsigned)elem, g_lastFmt.mSampleRate,
              (unsigned)g_lastFmt.mChannelsPerFrame, (unsigned)g_lastFmt.mFormatID,
              (unsigned)g_lastFmt.mBitsPerChannel, (unsigned)g_lastFmt.mBytesPerFrame);
    }
    if (pid == kAudioUnitProperty_SetRenderCallback && data && size >= sizeof(AURenderCallbackStruct)) {
        memcpy(&g_lastCB, data, sizeof(AURenderCallbackStruct));
        NSLog(@"[TAP] SetRenderCallback unit=%p cb=%p ref=%p", unit, (void *)g_lastCB.inputProc, g_lastCB.inputProcRefCon);
    }
    return orig_AudioUnitSetProperty(unit, pid, scope, elem, data, size);
}

static OSStatus my_AudioUnitInitialize(AudioUnit unit) {
    g_initCnt++;
    NSLog(@"[TAP] AudioUnitInitialize unit=%p (n=%llu)", unit, g_initCnt);
    return orig_AudioUnitInitialize(unit);
}

static OSStatus my_AudioOutputUnitStart(AudioUnit unit) {
    NSLog(@"[TAP] AudioOutputUnitStart unit=%p", unit);
    return orig_AudioOutputUnitStart(unit);
}

static OSStatus my_AudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                   const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                                   AudioBufferList *io) {
    g_renderCnt++;
    if (g_renderCnt % 200 == 1) {
        NSLog(@"[TAP] render #%llu frames=%u bufs=%u fmt=%s sr=%.0f ch=%u",
              g_renderCnt, (unsigned)frames, io ? io->mNumberBuffers : 0,
              g_haveFmt ? "yes" : "no", g_lastFmt.mSampleRate, (unsigned)g_lastFmt.mChannelsPerFrame);
    }
    return orig_AudioUnitRender(unit, flags, ts, bus, frames, io);
}

__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interpose_setprop __attribute__((section("__DATA,__interpose"))) = {
    (const void *)my_AudioUnitSetProperty, (const void *)AudioUnitSetProperty };
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interpose_init __attribute__((section("__DATA,__interpose"))) = {
    (const void *)my_AudioUnitInitialize, (const void *)AudioUnitInitialize };
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interpose_start __attribute__((section("__DATA,__interpose"))) = {
    (const void *)my_AudioOutputUnitStart, (const void *)AudioOutputUnitStart };
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interpose_render __attribute__((section("__DATA,__interpose"))) = {
    (const void *)my_AudioUnitRender, (const void *)AudioUnitRender };

__attribute__((constructor))
static void TAPInit(void) {
    orig_AudioUnitSetProperty = (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                              AudioUnitElement, const void *, UInt32))AudioUnitSetProperty;
    orig_AudioUnitInitialize = (OSStatus (*)(AudioUnit))AudioUnitInitialize;
    orig_AudioOutputUnitStart = (OSStatus (*)(AudioUnit))AudioOutputUnitStart;
    orig_AudioUnitRender = (OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *))AudioUnitRender;
    NSLog(@"[TAP] interpose loaded");
}
