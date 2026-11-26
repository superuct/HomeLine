#import "HLLocalCallRecorder.h"
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>

enum { HLFileRate = 16000, HLRingFrames = 32768, HLFlushFrames = 640, HLMixDelay = 1600 };

typedef struct {
    int64_t position;
    int16_t sample;
} HLRecordingFrame;

@interface HLLocalCallRecorder () {
@public
    _Atomic bool _capturing;
    os_unfair_lock _ringLock;
    HLRecordingFrame _microphone[HLRingFrames];
    HLRecordingFrame _playout[HLRingFrames];
    double _secondsPerTick;
    uint64_t _origin;
    int64_t _cursor;
    int64_t _latest;
@private
    dispatch_queue_t _writer;
    dispatch_source_t _timer;
    ExtAudioFileRef _file;
    NSURL *_url;
    OSStatus _failure;
    int64_t _written;
}
@end

static NSError *HLRecordingError(OSStatus status) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

@implementation HLLocalCallRecorder

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _ringLock = OS_UNFAIR_LOCK_INIT;
    _writer = dispatch_queue_create("org.example.homeline.call-recording", DISPATCH_QUEUE_SERIAL);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    _secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    return self;
}

- (BOOL)startAtURL:(NSURL *)url error:(NSError **)error {
    __block NSError *failure;
    dispatch_sync(_writer, ^{
        if (self->_file) {
            failure = HLRecordingError(kAudioFilePermissionsError);
            return;
        }
        AudioStreamBasicDescription format = {
            .mSampleRate = HLFileRate, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 2, .mFramesPerPacket = 1, .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1, .mBitsPerChannel = 16,
        };
        OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileWAVEType,
                                                    &format, NULL, 0, &self->_file);
        if (status) { failure = HLRecordingError(status); return; }
        NSError *protectionError;
        if (![[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUnlessOpen}
                                              ofItemAtPath:url.path error:&protectionError]) {
            ExtAudioFileDispose(self->_file);
            self->_file = NULL;
            [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
            failure = protectionError;
            return;
        }
        self->_url = url;
        self->_failure = noErr;
        self->_written = 0;
        os_unfair_lock_lock(&self->_ringLock);
        memset(self->_microphone, 0, sizeof(self->_microphone));
        memset(self->_playout, 0, sizeof(self->_playout));
        self->_cursor = 0;
        self->_latest = 0;
        self->_origin = mach_absolute_time();
        atomic_store(&self->_capturing, true);
        os_unfair_lock_unlock(&self->_ringLock);

        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_writer);
        dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC),
                                  40 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        __weak HLLocalCallRecorder *weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf flushFinishing:NO]; });
        dispatch_resume(self->_timer);
    });
    if (failure && error) *error = failure;
    return failure == nil;
}

- (void)flushFinishing:(BOOL)finishing {
    if (!_file || _failure) return;
    for (;;) {
        int16_t samples[HLFlushFrames];
        os_unfair_lock_lock(&_ringLock);
        int64_t end = _latest - (finishing ? 0 : HLMixDelay);
        // Keep recent audio if iOS suspended the writer for more than the ring's capacity.
        _cursor = MAX(_cursor, _latest - HLRingFrames);
        UInt32 count = (UInt32)MAX(0, MIN(HLFlushFrames, end - _cursor));
        for (UInt32 index = 0; index < count; index++, _cursor++) {
            size_t slot = _cursor % HLRingFrames;
            HLRecordingFrame left = _microphone[slot], right = _playout[slot];
            int32_t mic = left.position == _cursor + 1 ? left.sample : 0;
            int32_t remote = right.position == _cursor + 1 ? right.sample : 0;
            samples[index] = (int16_t)((mic + remote) / 2);
        }
        os_unfair_lock_unlock(&_ringLock);
        if (!count) return;
        AudioBufferList list = { .mNumberBuffers = 1,
            .mBuffers = {{ .mNumberChannels = 1, .mDataByteSize = count * sizeof(int16_t), .mData = samples }} };
        _failure = ExtAudioFileWrite(_file, count, &list);
        if (_failure) {
            atomic_store(&_capturing, false);
            return;
        }
        _written += count;
    }
}

- (BOOL)finishWithError:(NSError **)error {
    __block NSError *failure;
    dispatch_sync(_writer, ^{
        if (!self->_file) {
            failure = HLRecordingError(kAudioFileNotOpenError);
            return;
        }
        atomic_store(&self->_capturing, false);
        dispatch_source_cancel(self->_timer);
        self->_timer = nil;
        [self flushFinishing:YES];
        OSStatus status = ExtAudioFileDispose(self->_file);
        self->_file = NULL;
        if (self->_failure || status || !self->_written) {
            [[NSFileManager defaultManager] removeItemAtURL:self->_url error:NULL];
            failure = HLRecordingError(self->_failure ?: (status ?: kAudioFileInvalidFileError));
        }
        self->_url = nil;
    });
    if (failure && error) *error = failure;
    return failure == nil;
}

@end

void HLCaptureCallAudio(HLLocalCallRecorder *recorder, BOOL microphone, const int16_t *samples,
                        UInt32 count, double rate, const AudioTimeStamp *timestamp) {
    if (!atomic_load(&recorder->_capturing) || !count || rate <= 0 ||
        !os_unfair_lock_trylock(&recorder->_ringLock)) return;
    if (!atomic_load(&recorder->_capturing)) {
        os_unfair_lock_unlock(&recorder->_ringLock);
        return;
    }
    uint64_t tick = timestamp->mFlags & kAudioTimeStampHostTimeValid ? timestamp->mHostTime : mach_absolute_time();
    double start = (double)((int64_t)tick - (int64_t)recorder->_origin) * recorder->_secondsPerTick * (double)HLFileRate;
    double step = rate / (double)HLFileRate;
    int64_t first = MAX(recorder->_cursor, (int64_t)ceil(start));
    int64_t end = (int64_t)ceil(start + count / step);
    HLRecordingFrame *frames = microphone ? recorder->_microphone : recorder->_playout;
    for (int64_t position = first; position < end; position++) {
        double offset = (position - start) * step;
        UInt32 index = (UInt32)MAX(0, MIN(count - 1, offset));
        UInt32 next = MIN(count - 1, index + 1);
        int16_t sample = (int16_t)(samples[index] + (samples[next] - samples[index]) * (offset - index));
        frames[position % HLRingFrames] = (HLRecordingFrame){position + 1, sample};
    }
    if (first < end) recorder->_latest = MAX(recorder->_latest, end);
    os_unfair_lock_unlock(&recorder->_ringLock);
}
