#include "s10_codec.h"
#include <string.h>

static int reset_decoder(s10_codec *s)
{
    /* OI Reset resets context/indices, but does not clear the supplied history. */
    memset(s->workspace, 0, sizeof(s->workspace));
    s->last_oi_status = OI_CODEC_SBC_DecoderReset(&s->context, s->workspace,
                       (OI_UINT32)sizeof(s->workspace), 2, 2, FALSE, FALSE);
    return s->last_oi_status == OI_OK ? S10_CODEC_OK : S10_CODEC_DECODE;
}

int s10_codec_start(s10_codec *s, uint64_t epoch, uint32_t rate)
{
    if (!s || !epoch || (rate != 44100u && rate != 48000u)) return S10_CODEC_ARGUMENT;
    memset(s, 0, sizeof(*s));
    s->epoch = epoch;
    s->sample_rate = rate;
    if (reset_decoder(s)) return S10_CODEC_DECODE;
    s->active = 1u;
    return S10_CODEC_OK;
}

void s10_codec_stop(s10_codec *s)
{
    if (s) { s->active = 0u; s->have_format = 0u; memset(s->workspace, 0, sizeof(s->workspace)); }
}

int s10_codec_frame(s10_codec *s, uint64_t epoch, const uint8_t *f, size_t len,
                     int16_t *stereo, size_t capacity, size_t *made)
{
    static const unsigned rates[4] = {16000u, 32000u, 44100u, 48000u};
    unsigned blocks, bands, channels, mode, pool, bits, expected, pairs;
    uint8_t format;
    const OI_BYTE *read;
    OI_UINT32 remaining, pcm_bytes;
    size_t i;
    int result;
    if (made) *made = 0;
    if (!s || !f || !stereo || !made) return S10_CODEC_ARGUMENT;
    if (!s->active || epoch != s->epoch) { ++s->stale; return S10_CODEC_STALE; }
    if (len < 4u || len > S10_SBC_MAX_FRAME || f[0] != 0x9cu) {
        ++s->rejected; return S10_CODEC_LENGTH;
    }
    blocks = 4u * (((f[1] >> 4) & 3u) + 1u);
    bands = (f[1] & 1u) ? 8u : 4u;
    mode = (f[1] >> 2) & 3u;
    channels = mode ? 2u : 1u;
    pool = f[2];
    if (rates[f[1] >> 6] != s->sample_rate || pool < 2u ||
        pool > 250u || pool > bands * (mode < 2u ? 16u : 32u)) {
        ++s->rejected; return S10_CODEC_FORMAT;
    }
    bits = blocks * pool * (mode < 2u ? channels : 1u);
    if (mode == 3u) bits += bands;
    expected = 4u + bands * channels / 2u + (bits + 7u) / 8u;
    if (len != expected) { ++s->rejected; return S10_CODEC_LENGTH; }
    pairs = blocks * bands;
    if (capacity < pairs) { ++s->rejected; return S10_CODEC_CAPACITY; }
    /* Mode/subband/frequency transitions reset the synthesis history. */
    format = f[1] & 0xcdu;
    if (s->have_format && format != s->format) {
        result = reset_decoder(s);
        if (result) { ++s->rejected; return result; }
    }
    read = f;
    remaining = (OI_UINT32)len;
    pcm_bytes = (OI_UINT32)(pairs * 2u * sizeof(int16_t));
    s->last_oi_status = OI_CODEC_SBC_DecodeFrame(&s->context, &read, &remaining,
                         (OI_INT16 *)stereo, &pcm_bytes);
    if (s->last_oi_status != OI_OK || remaining || read != f + len ||
        pcm_bytes != pairs * 2u * sizeof(int16_t)) {
        ++s->rejected; return S10_CODEC_DECODE;
    }
    if (channels == 1u) for (i = 0; i < pairs; ++i) stereo[2u*i + 1u] = stereo[2u*i];
    s->format = format;
    s->have_format = 1u;
    ++s->frames;
    s->pairs += pairs;
    *made = pairs;
    return S10_CODEC_OK;
}
