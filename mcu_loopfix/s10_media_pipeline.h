#ifndef S10_MEDIA_PIPELINE_H
#define S10_MEDIA_PIPELINE_H
#include <stddef.h>
#include <stdint.h>
#include "s10_codec.h"
#include "s10_fir.h"
#include "s10_pcm_tx.h"

#define S10_MEDIA_PCM_SLOTS 2u
#define S10_MEDIA_PCM_PAIRS 160u
#define S10_MEDIA_SDU_LIMIT 1024u
enum { S10_MEDIA_CLOSED=0, S10_MEDIA_OPENING=1,
       S10_MEDIA_PLAY=2, S10_MEDIA_CLOSING=3 };
enum { S10_MEDIA_OK=0, S10_MEDIA_BUSY=-1, S10_MEDIA_ARGUMENT=-2,
       S10_MEDIA_STALE=-3, S10_MEDIA_FORMAT=-4, S10_MEDIA_SEQUENCE=-5,
       S10_MEDIA_DECODE=-6, S10_MEDIA_SOURCE=-7, S10_MEDIA_TRANSPORT=-8,
       S10_MEDIA_EXHAUSTED=-9 };

typedef struct {
    const uint8_t *bytes;
    uint64_t epoch, ticket;
    uint16_t length;
} s10_media_sdu;
typedef struct {
    void *user;
    /* The same short lock protects the Profile pool and pipeline lifecycle.
     * Source functions below run with that lock already held; no recursion.
     * Codec/FIR, SPI, FatFs and waits must never execute under this lock. */
    void (*lock)(void *user);
    void (*unlock)(void *user);
    int (*active)(void *user, uint64_t epoch);
    /* Positive means success/true, zero means unavailable/false, negative is
     * a source fault. claim must not recycle any outstanding claimed slot. */
    int (*claim)(void *user, s10_media_sdu *sdu);
    int (*valid)(void *user, uint64_t ticket, uint64_t epoch);
    int (*release)(void *user, uint64_t ticket, uint64_t epoch);
} s10_media_binding;
typedef struct {
    int16_t samples[S10_MEDIA_PCM_PAIRS][2];
    uint64_t epoch, generation;
    uint16_t pairs;
    uint8_t ready;
} s10_media_pcm_slot;
typedef struct {
    s10_media_binding binding;
    s10_codec codec;
    s10_fir fir;
    s10_media_pcm_slot pcm[S10_MEDIA_PCM_SLOTS];
    uint8_t frame[S10_SBC_MAX_FRAME];
    int16_t decoded[S10_SBC_MAX_PAIRS][2];
    int16_t normalized[S10_MEDIA_PCM_PAIRS][2];
    s10_media_sdu claimed;
    uint64_t epoch, last_epoch, generation, worker_generation;
    uint64_t claimed_sdus, released_sdus, decoded_pairs, normalized_pairs;
    uint64_t published_pairs, bus_pairs, discarded_pairs, stale_results;
    uint32_t rate, frames, errors, stops;
    uint32_t resyncs; /* realigned after missing packets */
    uint32_t ssrc, expected_timestamp, fragment_timestamp;
    uint16_t expected_sequence, packet_offset, frame_bytes, fragment_bytes;
    uint16_t decoded_count, decoded_offset, normal_count;
    int32_t last_error;
    uint8_t state, initialized, worker_clean, bus_opened, bus_stop_sent;
    uint8_t have_claim, pcm_head, pcm_count, have_rtp, payload_type;
    uint8_t frames_remaining, fragmented, fragment_remaining, frame_ready;
} s10_media_pipeline;

/* This worker receives COMPLETE basic-media L2CAP SDUs from the one Profile
 * pool, not a guessed SDK SBC hook. RTP remains present. The borrowed source
 * pointer is immutable until matching release(), including after retirement.
 * One worker owns worker_step(); the sole bus task owns bus_step(). All other
 * entry points are bounded callback/task operations using binding.lock. */
/* Playback gain from the phone's AVRCP absolute volume (0..127, 127 = unity). */
extern volatile uint8_t s10_media_volume;
int s10_media_init(s10_media_pipeline *p, const s10_media_binding *binding);
/* Invoke only for a proven accepted media start, with its original identity.
 * rate=0 means UNKNOWN, not 48 kHz: wait for the first COMPLETE public SBC
 * frame, then establish 44100/48000 through its header and actual Codec.
 * 16/32 kHz or a later rate change stops this source; never just relabel it.
 * A new epoch is permitted only after worker cleanup AND old TX CLOSED. */
int s10_media_start(s10_media_pipeline *p,uint64_t epoch,uint32_t rate);
int s10_media_stop(s10_media_pipeline *p,uint64_t epoch,int reason);
int s10_media_worker_step(s10_media_pipeline *p);
/* Does no HAL/SPI operation. TX remains exclusively owned by this caller.
 * Existing TX DMA must be retired/released before TX complete() is invoked. */
int s10_media_bus_step(s10_media_pipeline *p,s10_pcm_tx *tx);
int s10_media_state(s10_media_pipeline *p,uint64_t *epoch,int *error);
int s10_media_conserved(s10_media_pipeline *p);
#endif
