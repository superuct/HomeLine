#import <WebRTC/RTCAudioDevice.h>
#import "HLLocalCallRecorder.h"

NS_ASSUME_NONNULL_BEGIN

@interface HLWebRTCAudioDevice : NSObject <RTCAudioDevice>
@property(class, nonatomic, readonly) HLWebRTCAudioDevice *shared;
@property(nonatomic, readonly) HLLocalCallRecorder *callRecorder;
- (void)setCallAudioActive:(BOOL)active;
- (void)setCallMicrophoneMuted:(BOOL)muted;
- (void)setCallHeld:(BOOL)held;
#if DEBUG
- (void)setFixtureMicrophoneEnabled:(BOOL)enabled;
#endif
@end

NS_ASSUME_NONNULL_END
