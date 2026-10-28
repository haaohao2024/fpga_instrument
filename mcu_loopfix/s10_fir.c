#include "s10_fir.h"
#include <string.h>

void s10_fir_reset(s10_fir *s)
{
    memset(s, 0, sizeof(*s));
    s->newest = S10_FIR_HISTORY - 1u;
    s->need_input = 1u;
}

int16_t s10_fir_round_sat(int64_t accumulator, uint32_t *count)
{
    /* The accumulator is bounded below 2^53 by the 96 full products. */
    const int64_t half = INT64_C(1) << (S10_FIR_Q - 1u);
    int64_t value = accumulator < 0 ? -((-accumulator + half) >> S10_FIR_Q)
                                    : (accumulator + half) >> S10_FIR_Q;
    if (value > 32767) { if (count) ++*count; return 32767; }
    if (value < -32768) { if (count) ++*count; return -32768; }
    return (int16_t)value;
}

static void input_pair(s10_fir *s, int16_t l, int16_t r)
{
    s->newest = (uint16_t)((s->newest + 1u) & (S10_FIR_HISTORY - 1u));
    s->history[s->newest][0] = l;
    s->history[s->newest][1] = r;
    s->need_input = 0u;
}

/* 4-point Catmull-Rom between history[newest-2] and history[newest-1].
 * Replaces the 96-tap polyphase FIR on the board: measured BL616 decode +
 * resample throughput was ~11% of real time (flash-resident table/code), so
 * the A2DP ingress overflowed. No table; a dozen multiplies per channel. */
static int16_t cubic(int32_t x0, int32_t x1, int32_t x2, int32_t x3, int32_t t, uint32_t *count)
{
    /* t in Q11: every product stays below 2^31 for full-scale int16 input. */
    int32_t a = -x0 + 3 * x1 - 3 * x2 + x3;
    int32_t b = 2 * x0 - 5 * x1 + 4 * x2 - x3;
    int32_t c = x2 - x0;
    int32_t y = ((((a * t) >> 11) + b) * t) >> 11;
    y = (((y + c) * t) >> 11) + 2 * x1;
    y = (y + 1) >> 1;
    if (y > 32767) { if (count) ++*count; return 32767; }
    if (y < -32768) { if (count) ++*count; return -32768; }
    return (int16_t)y;
}

static void output_pair(s10_fir *s, int16_t *out)
{
    const unsigned m = S10_FIR_HISTORY - 1u;
    const int16_t *x0 = s->history[(s->newest + S10_FIR_HISTORY - 3u) & m];
    const int16_t *x1 = s->history[(s->newest + S10_FIR_HISTORY - 2u) & m];
    const int16_t *x2 = s->history[(s->newest + S10_FIR_HISTORY - 1u) & m];
    const int16_t *x3 = s->history[s->newest];
    int32_t t = (int32_t)(((uint32_t)s->phase * 819u) >> 6); /* phase*2048/160, no division */
    out[0] = cubic(x0[0], x1[0], x2[0], x3[0], t, &s->saturation_count);
    out[1] = cubic(x0[1], x1[1], x2[1], x3[1], t, &s->saturation_count);
    ++s->output_pairs;
    s->phase = (uint16_t)(s->phase + 147u);
    s->need_input = s->phase >= S10_FIR_PHASES;
    if (s->need_input) s->phase = (uint16_t)(s->phase - S10_FIR_PHASES);
}

size_t s10_fir_process(s10_fir *s, const int16_t *in, size_t count,
                       int16_t *out, size_t capacity, size_t *consumed)
{
    size_t taken = 0, made = 0;
    if (consumed) *consumed = 0;
    if (!s || !out || (count && !in) || s->draining) return 0;
    while (made < capacity) {
        if (s->need_input) {
            if (taken == count) break;
            input_pair(s, in[2u*taken], in[2u*taken + 1u]);
            ++taken;
            ++s->input_pairs;
        }
        output_pair(s, out + 2u*made);
        ++made;
    }
    if (consumed) *consumed = taken;
    return made;
}

size_t s10_fir_drain(s10_fir *s, int16_t *out, size_t capacity)
{
    size_t made = 0;
    if (!s || !out) return 0;
    if (!s->input_pairs) { s->draining = 1u; return 0; }
    if (!s->draining) { s->draining = 1u; s->tail_remaining = S10_FIR_TAPS - 1u; }
    while (made < capacity) {
        if (s->need_input) {
            if (!s->tail_remaining) break;
            input_pair(s, 0, 0);
            --s->tail_remaining;
        }
        output_pair(s, out + 2u*made);
        ++made;
    }
    return made;
}
