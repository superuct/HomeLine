#import "HLWebRTCAudioDevice.h"
#import "HLReceiveSpeechFilter.h"
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>

enum { HLOutputBus = 0, HLInputBus = 1, HLMaxFrames = 8192 };

@interface HLWebRTCAudioDevice () {
@public
    AudioUnit _unit;
    double _sampleRate;
    HLReceiveSpeechFilter _receiveSpeechFilter;
    int16_t _input[HLMaxFrames];
    RTCAudioDeviceGetPlayoutDataBlock _playout;
    RTCAudioDeviceDeliverRecordedDataBlock _deliver;
    _Atomic bool _playing;
    _Atomic bool _recording;
    _Atomic bool _muted;
    _Atomic bool _held;
#if DEBUG
    _Atomic bool _fixtureMicrophone;
    UInt32 _fixtureFrame;
#endif
@private
    _Atomic bool _callAudioActive;
    _Atomic bool _interrupted;
    BOOL _playoutInitialized;
    BOOL _recordingInitialized;
}
@property(atomic, strong, nullable) id<RTCAudioDeviceDelegate> audioDelegate;
@end

static OSStatus HLRenderPlayout(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                UInt32 bus, UInt32 count, AudioBufferList *buffers) {
    HLWebRTCAudioDevice *device = (__bridge HLWebRTCAudioDevice *)context;
    if (atomic_load(&device->_playing)) {
        OSStatus result = device->_playout(flags, time, bus, count, buffers);
        if (!result && !atomic_load(&device->_held) && buffers->mNumberBuffers == 1 && buffers->mBuffers[0].mData &&
            buffers->mBuffers[0].mDataByteSize >= count * sizeof(int16_t)) {
            if (!(*flags & kAudioUnitRenderAction_OutputIsSilence)) {
                HLCaptureCallAudio(device.callRecorder, NO, buffers->mBuffers[0].mData, count, device->_sampleRate, time);
                HLReceiveSpeechFilterApply(&device->_receiveSpeechFilter, buffers->mBuffers[0].mData, count);
            } else {
                HLReceiveSpeechFilterReset(&device->_receiveSpeechFilter);
            }
            return noErr;
        }
    }
    *flags |= kAudioUnitRenderAction_OutputIsSilence;
    HLReceiveSpeechFilterReset(&device->_receiveSpeechFilter);
    for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) {
        if (buffers->mBuffers[i].mData) memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
    }
    return noErr;
}

static OSStatus HLRenderMicrophone(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                   UInt32 bus, UInt32 count, AudioBufferList *buffers) {
    HLWebRTCAudioDevice *device = (__bridge HLWebRTCAudioDevice *)context;
    if (!atomic_load(&device->_recording) || count > HLMaxFrames) return noErr;
    AudioBufferList input = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 1, .mDataByteSize = count * sizeof(int16_t), .mData = device->_input }} };
    OSStatus result = AudioUnitRender(device->_unit, flags, time, bus, count, &input);
    if (result) return result;
    int16_t *samples = input.mBuffers[0].mData;
    if (!samples || input.mBuffers[0].mDataByteSize < count * sizeof(int16_t)) return noErr;
    if (atomic_load(&device->_muted) || atomic_load(&device->_held)) {
        memset(samples, 0, count * sizeof(int16_t));
    }
#if DEBUG
    else if (atomic_load(&device->_fixtureMicrophone)) {
        for (UInt32 i = 0; i < count; i++) {
            samples[i] = 4000 * sin(2 * M_PI * 710 * device->_fixtureFrame++ / device->_sampleRate);
        }
    }
#endif
    HLCaptureCallAudio(device.callRecorder, YES, samples, count, device->_sampleRate, time);
    return device->_deliver(flags, time, bus, count, &input, NULL, nil);
}

@implementation HLWebRTCAudioDevice

+ (HLWebRTCAudioDevice *)shared {
    static HLWebRTCAudioDevice *device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = [HLWebRTCAudioDevice new]; });
    return device;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _callRecorder = [HLLocalCallRecorder new];
    _sampleRate = 48000;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    [notifications addObserver:self selector:@selector(interruptionChanged:) name:AVAudioSessionInterruptionNotification object:nil];
    [notifications addObserver:self selector:@selector(mediaServicesReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isInitialized { return self.audioDelegate != nil; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    if (self.audioDelegate) return YES;
    _playout = delegate.getPlayoutData;
    _deliver = delegate.deliverRecordedData;
    double rate = AVAudioSession.sharedInstance.sampleRate;
    if (rate >= 8000) _sampleRate = rate;
    self.audioDelegate = delegate;
    return YES;
}

- (BOOL)terminateDevice {
    [self stopUnit];
    atomic_store(&_playing, false);
    atomic_store(&_recording, false);
    _playoutInitialized = NO;
    _recordingInitialized = NO;
    self.audioDelegate = nil;
    _playout = nil;
    _deliver = nil;
    return YES;
}

- (double)deviceInputSampleRate { return _sampleRate; }
- (double)deviceOutputSampleRate { return _sampleRate; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return AVAudioSession.sharedInstance.inputLatency; }
- (NSTimeInterval)outputLatency { return AVAudioSession.sharedInstance.outputLatency; }
- (NSTimeInterval)inputIOBufferDuration { return AVAudioSession.sharedInstance.IOBufferDuration ?: .01; }
- (NSTimeInterval)outputIOBufferDuration { return self.inputIOBufferDuration; }

- (BOOL)isPlayoutInitialized { return _playoutInitialized; }
- (BOOL)isRecordingInitialized { return _recordingInitialized; }
- (BOOL)initializePlayout { _playoutInitialized = YES; return YES; }
- (BOOL)initializeRecording { _recordingInitialized = YES; return YES; }
- (BOOL)isPlaying { return atomic_load(&_playing); }
- (BOOL)isRecording { return atomic_load(&_recording); }

- (BOOL)startPlayout {
    atomic_store(&_playing, true);
    return [self updateUnitRestart:NO];
}
- (BOOL)startRecording {
    atomic_store(&_recording, true);
    return [self updateUnitRestart:NO];
}
- (BOOL)stopPlayout {
    atomic_store(&_playing, false);
    _playoutInitialized = NO;
    return [self updateUnitRestart:NO];
}
- (BOOL)stopRecording {
    atomic_store(&_recording, false);
    _recordingInitialized = NO;
    return [self updateUnitRestart:NO];
}

- (void)setCallAudioActive:(BOOL)active {
    if (active) atomic_store(&_interrupted, false);
    atomic_store(&_callAudioActive, active);
    [self updateOnAudioThreadRestart:NO];
}
- (void)setCallMicrophoneMuted:(BOOL)muted { atomic_store(&_muted, muted); }
- (void)setCallHeld:(BOOL)held { atomic_store(&_held, held); }
#if DEBUG
- (void)setFixtureMicrophoneEnabled:(BOOL)enabled { atomic_store(&_fixtureMicrophone, enabled); }
#endif

- (void)routeChanged:(NSNotification *)notification {
    NSUInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    [self updateOnAudioThreadRestart:reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable ||
                                     reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable];
}
- (void)interruptionChanged:(NSNotification *)notification {
    NSNumber *kind = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (!kind) return;
    atomic_store(&_interrupted, kind.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan);
    [self updateOnAudioThreadRestart:NO];
}
- (void)mediaServicesReset:(NSNotification *)notification {
    [self updateOnAudioThreadRestart:YES];
}

- (void)updateOnAudioThreadRestart:(BOOL)restart {
    id<RTCAudioDeviceDelegate> delegate = self.audioDelegate;
    if (!delegate) return;
    [delegate dispatchAsync:^{
        if (self.audioDelegate == delegate) [self updateUnitRestart:restart];
    }];
}

- (void)stopUnit {
    if (!_unit) return;
    AudioOutputUnitStop(_unit);
    AudioUnitUninitialize(_unit);
    AudioComponentInstanceDispose(_unit);
    _unit = NULL;
    [self.audioDelegate notifyAudioInputInterrupted];
    [self.audioDelegate notifyAudioOutputInterrupted];
}

- (BOOL)updateUnitRestart:(BOOL)restart {
    if (!atomic_load(&_callAudioActive) || atomic_load(&_interrupted) ||
        (!self.isPlaying && !self.isRecording)) {
        [self stopUnit];
        return YES;
    }
    double rate = AVAudioSession.sharedInstance.sampleRate;
    if (restart || (_unit && rate >= 8000 && rate != _sampleRate)) [self stopUnit];
    if (_unit) return YES;
    if (rate >= 8000) _sampleRate = rate;
    _receiveSpeechFilter = HLReceiveSpeechFilterAtRate(_sampleRate);
    [self.audioDelegate notifyAudioInputParametersChange];
    [self.audioDelegate notifyAudioOutputParametersChange];

    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_VoiceProcessingIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component) return NO;
    OSStatus status = AudioComponentInstanceNew(component, &_unit);
    if (status) {
        _unit = NULL;
        return NO;
    }

    UInt32 enabled = 1;
    AudioStreamBasicDescription format = {
        .mSampleRate = _sampleRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2, .mFramesPerPacket = 1, .mBytesPerFrame = 2,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 16,
    };
    AURenderCallbackStruct playout = { HLRenderPlayout, (__bridge void *)self };
    AURenderCallbackStruct microphone = { HLRenderMicrophone, (__bridge void *)self };
    if ((status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                       HLInputBus, &enabled, sizeof(enabled))) ||
        (status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                       HLOutputBus, &enabled, sizeof(enabled))) ||
        (status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                                       HLOutputBus, &format, sizeof(format))) ||
        (status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                       HLInputBus, &format, sizeof(format))) ||
        (status = AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                       HLOutputBus, &playout, sizeof(playout))) ||
        (status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                                       HLInputBus, &microphone, sizeof(microphone))) ||
        (status = AudioUnitInitialize(_unit)) || (status = AudioOutputUnitStart(_unit))) {
        NSLog(@"HomeLine audio I/O could not start (%d)", (int)status);
        [self stopUnit];
        return NO;
    }
    return YES;
}
@end
