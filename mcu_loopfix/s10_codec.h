#ifndef S10_CODEC_H
#define S10_CODEC_H
#include <stddef.h>
#include <stdint.h>
#include "oi_codec_sbc.h"

#define S10_SBC_MAX_FRAME 524u
#define S10_SBC_MAX_PAIRS 128u
enum {
    S10_CODEC_OK = 0, S10_CODEC_ARGUMENT = -1, S10_CODEC_STALE = -2,
    S10_CODEC_FORMAT = -3, S10_CODEC_LENGTH = -4,
    S10_CODEC_DECODE = -5, S10_CODEC_CAPACITY = -6
};
typedef struct {
    OI_CODEC_SBC_DECODER_CONTEXT context;
    OI_UINT32 workspace[CODEC_DATA_WORDS(2, SBC_CODEC_FAST_FILTER_BUFFERS)];
    uint64_t epoch;
    uint64_t pairs;
    uint32_t sample_rate;
    uint32_t frames;
    uint32_t rejected;
    uint32_t stale;
    int32_t last_oi_status;
    uint8_t format;
    uint8_t active;
    uint8_t have_format;
} s10_codec;
/* This is a complete-SBC-frame boundary, NOT an A2DP media callback ABI.
 * No RTP stripping, A2DP reassembly or buffer-lifetime inference occurs here. */
int s10_codec_start(s10_codec *state, uint64_t epoch, uint32_t rate);
void s10_codec_stop(s10_codec *state);
int s10_codec_frame(s10_codec *state, uint64_t epoch,
                     const uint8_t *frame, size_t length,
                     int16_t *stereo, size_t capacity_pairs,
                     size_t *produced_pairs);
#endif
