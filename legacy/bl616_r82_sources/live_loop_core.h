#ifndef LIVE_LOOP_CORE_H
#define LIVE_LOOP_CORE_H
#include <stdint.h>
#include <stddef.h>
#define LL_LAYERS 4u
#define LL_LOCAL_KEYS 8u
#define LL_PHONE_KEYS 32u
#define LL_INPUTS 48u /* native owner slots; key counts remain8+32 */
#define LL_ARENA_EVENTS 4096u
#define LL_NONE UINT16_MAX
enum { LL_OK=0, LL_IGNORED=1, LL_E_STATE=-1, LL_E_CAPACITY=-2,
       LL_E_TIME=-3, LL_E_ID=-4, LL_E_ADMISSION=-5, LL_E_ARGUMENT=-6 };
enum { LL_EMPTY=0, LL_CAPTURE=1, LL_TAIL=2, LL_COMMITTED=3, LL_FAILED=4 };
/* Exactly 24 bytes: the 96 KiB arena is shared by every layer. */
typedef struct {
    uint64_t offset, original_token;
    uint32_t original_word;
    uint16_t next, gesture;
} ll_record;
typedef struct {
    uint64_t start, end, play_start, next_due, last_due;
    uint32_t count,cycle,phase_base;
    uint16_t first, last, cursor, revision, next_gesture;
    uint8_t state, timbre, held, scheduled,emitted;
    uint64_t pending_insert_due;
    uint32_t pending_insert_cycle;
    uint16_t pending_insert_record;
    uint8_t pending_insert_valid;
} ll_layer;
typedef struct {uint64_t token;uint16_t gesture;uint8_t layer,valid;} ll_owner;
typedef struct {
    uint32_t max_events_per_second, max_events_same_sample;
    uint32_t max_rows_per_second,max_length_samples;
    /* Count absolute targets in every circular [t-window+1,t] interval.
     * Zero disables an individual bound. The window must not exceed L. */
    uint32_t window_samples,max_window_events,max_window_groups,max_window_rows;
    /* A longer independent row window bounds sustained SPI bursts as well
     * as the shorter allocator-work window. */
    uint32_t wire_window_samples,max_wire_window_rows;
} ll_budget;
typedef struct {
    uint64_t due, token;
    uint32_t word;
    uint16_t record, revision;
    uint8_t layer,timbre;
} ll_delivery;
typedef struct {
    ll_record *records;
    uint32_t *phase_cache;uint64_t cache_length;
    uint64_t length,anchor,capture_watermark;
    ll_layer layer[LL_LAYERS];
    ll_owner owner[LL_INPUTS];
    ll_budget budget;
    uint16_t capacity,free_head,used,next_revision,last_failed_revision;
    uint8_t recording,running,capture_batch,pending_admission_layer,cursor_watch;
    uint16_t pending_admission_revision;
    int error;
} ll_core;
typedef struct {
    uint32_t records,events_per_second,peak_same_sample,rows_per_period,rows_per_second;
    uint32_t peak_window_events,peak_window_groups,peak_window_rows,peak_wire_window_rows;
} ll_analysis;
void ll_init(ll_core *,ll_record *,uint16_t capacity,ll_budget);
/* Optional 4B/record acceleration; the 24B arena and original offset64 stay
 * unchanged. Preparing a proposed first SEAL length mutates cache metadata
 * only, never layer state or the drained watermark. */
int ll_attach_phase_cache(ll_core *,uint32_t *cache,uint16_t capacity);
int ll_prepare_phase_cache(ll_core *,uint64_t length);
/* start is an effective FPGA sample number, supplied by the wire adapter.
 * Only one new layer may capture or finish existing held gestures at a time. */
int ll_begin(ll_core *,uint64_t start,uint8_t timbre,uint8_t *layer);
int ll_capture(ll_core *,uint64_t frame,uint64_t token,uint32_t original_word);
/* S11 actual-instance adapter supplies its native slot as owner_index.
 * This permits simultaneous native instances of one original source/key. */
int ll_capture_owner(ll_core *,unsigned owner_index,uint64_t frame,uint64_t token,uint32_t original_word);
/* One bounded CPU drain transaction: retain every event/order, then admit the
 * whole newly captured TAIL before any composer/peek may observe it. */
int ll_capture_batch_begin(ll_core *);
int ll_capture_batch_end(ll_core *);
/* While a PAGE awaits ACK, retain the earliest newly inserted TAIL record.
 * Commit merges it, or rejects the new layer if that target was closed. */
void ll_cursor_watch(ll_core *,int active);
int ll_commit_cursor(ll_core *,unsigned layer,const ll_layer *queued);
/* One-time SEAL refresh includes records captured after prefix projection. */
int ll_refresh_cursor(const ll_core *,unsigned layer,ll_layer *queued);
/* First stop defines length. Subsequent stops must be exactly one length.
 * A held gesture remains owned by this new layer through its real OFF;
 * no new ON is captured after stop. play_start is a separately acknowledged
 * FPGA scheduling boundary, never inferred from a phone/MCU wall clock.
 * Before close, ll_watermark must prove the sealed stream has been fully
 * ACK/drained through stop. Closing itself cannot manufacture that proof. */
int ll_close(ll_core *,uint64_t stop,uint64_t play_start);
/* Inclusive watermark from a fully drained, CRC/sequence-checked FPGA
 * capture stream. A current-time status alone is not a capture watermark. */
int ll_watermark(ll_core *,uint64_t through);
int ll_analyze(const ll_core *,ll_analysis *);
int ll_peek(ll_core *,uint64_t through,ll_delivery *);
int ll_pop(ll_core *,const ll_delivery *);
/* Caller cancels queued rows and sends the returned revision to the FPGA's
 * existing-slot cleanup scan before reporting completion to the App. */
int ll_undo(ll_core *,uint16_t *retired_revision);
void ll_stop(ll_core *);
int ll_resume(ll_core *,uint64_t play_start);
int ll_disconnect(ll_core *,uint16_t *retired_revision);
void ll_clear(ll_core *);
/* Poll more often than 2^31 audio samples. Unsigned subtraction handles
 * the FPGA sample32 rollover; a backwards/out-of-horizon value is rejected. */
int ll_extend_sample(uint64_t previous,uint32_t sample,uint64_t *extended);
#endif
