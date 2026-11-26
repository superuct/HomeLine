#pragma once

#include <math.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    float lowRate;
    float presenceStartRate;
    float presenceEndRate;
    float low;
    float presenceStart;
    float presenceEnd;
} HLReceiveSpeechFilter;

static inline void HLReceiveSpeechFilterReset(HLReceiveSpeechFilter *filter) {
    filter->low = 0;
    filter->presenceStart = 0;
    filter->presenceEnd = 0;
}

static inline HLReceiveSpeechFilter HLReceiveSpeechFilterAtRate(double sampleRate) {
    const float radiansPerHz = 6.2831853f / (float)sampleRate;
    return (HLReceiveSpeechFilter){
        .lowRate = 1.0f - expf(-420.0f * radiansPerHz),
        .presenceStartRate = 1.0f - expf(-950.0f * radiansPerHz),
        .presenceEndRate = 1.0f - expf(-3300.0f * radiansPerHz),
    };
}

static inline void HLReceiveSpeechFilterApply(HLReceiveSpeechFilter *filter, int16_t *samples, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        const float input = samples[i];
        filter->low += filter->lowRate * (input - filter->low);
        filter->presenceStart += filter->presenceStartRate * (input - filter->presenceStart);
        filter->presenceEnd += filter->presenceEndRate * (input - filter->presenceEnd);
        // Reduce low-frequency masking and emphasize consonants in telephone-band speech.
        float output = 0.93f * input - 0.37f * filter->low
                     + 0.61f * (filter->presenceEnd - filter->presenceStart);
        const float magnitude = fabsf(output);
        if (magnitude > 28000.0f) {
            const float limited = fminf(32767.0f, 28000.0f + 0.25f * (magnitude - 28000.0f));
            output = copysignf(limited, output);
        }
        samples[i] = (int16_t)output;
    }
}
