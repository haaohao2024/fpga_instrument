#ifndef S10_FIR_H
#define S10_FIR_H
#include <stddef.h>
#include <stdint.h>

#define S10_FIR_PHASES 160u
#define S10_FIR_TAPS 96u
#define S10_FIR_HISTORY 128u
#define S10_FIR_Q 30u

typedef struct {
    int16_t history[S10_FIR_HISTORY][2];
    uint16_t newest;
    uint16_t phase;
    uint8_t need_input;
    uint8_t tail_remaining;
    uint8_t draining;
    uint64_t input_pairs;
    uint64_t output_pairs;
    uint32_t saturation_count;
} s10_fir;

extern const int32_t s10_fir_coefficients[S10_FIR_PHASES][S10_FIR_TAPS];

/* 44.1 kHz -> 48 kHz only. Reset drops all old stream history. */
void s10_fir_reset(s10_fir *state);
/* consumed counts real input only; outputs may follow without new input. */
size_t s10_fir_process(s10_fir *state, const int16_t *stereo,
                       size_t input_pairs, int16_t *output,
                       size_t output_capacity, size_t *consumed);
/* Appends exactly 95 zero input pairs, including pending fractional output.
 * Call after all real input was consumed. Reset is required for a new stream. */
size_t s10_fir_drain(s10_fir *state, int16_t *output, size_t capacity);
/* Public integer boundary helper; half-LSB rounds away from zero. */
int16_t s10_fir_round_sat(int64_t accumulator, uint32_t *saturation_count);
#endif
