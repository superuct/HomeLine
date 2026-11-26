#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HLLocalCallRecorder : NSObject
- (BOOL)startAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)finishWithError:(NSError **)error;
@end

// Audio callbacks pass interleaved mono PCM and the audio unit's host timestamp.
void HLCaptureCallAudio(HLLocalCallRecorder *recorder, BOOL microphone, const int16_t *samples,
                        UInt32 count, double rate, const AudioTimeStamp *timestamp);

NS_ASSUME_NONNULL_END
