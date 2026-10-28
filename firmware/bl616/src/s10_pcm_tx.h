#ifndef S10_PCM_TX_H
#define S10_PCM_TX_H
#include <stddef.h>
#include <stdint.h>

#define S10_TX_CAPACITY 4096u
/* FPGA receive bank: 512 stereo pairs (r3e). Fewer, larger DATA transactions. */
#define S10_TX_PACKET_PAIRS 512u
#define S10_TX_WIRE_BYTES (36u+4u*S10_TX_PACKET_PAIRS)
#define S10_TX_BANK_BYTES 2112u
#define S10_TX_RETRY_US 20000u
enum { S10_TX_OK=0, S10_TX_ARGUMENT=-1, S10_TX_BUSY=-2,
       S10_TX_STALE=-3, S10_TX_PROTOCOL=-4, S10_TX_EXHAUSTED=-5 };
enum { S10_TX_CLOSED=0, S10_TX_OPENING=1, S10_TX_PLAY=2, S10_TX_CLOSING=3 };
typedef struct {
    uint16_t steady_trigger,sd_trigger,mcu_target,mcu_bias_divisor,mcu_bias_limit;
    uint32_t query_period_us;
} s10_tx_service_config;
typedef struct {
    /* Dedicated complete cache lines for non-coherent block-DMA ownership. */
    uint8_t tx[S10_TX_BANK_BYTES] __attribute__((aligned(32)));
    uint8_t rx[S10_TX_BANK_BYTES] __attribute__((aligned(32)));
    uint64_t origin,last_sent_us;
    uint32_t sequence;
    uint16_t pairs,length;
    uint8_t state,sent;
} s10_tx_bank;
typedef struct {
    int16_t pcm[S10_TX_CAPACITY][2];
    s10_tx_bank bank[2];
    uint8_t control_tx[64] __attribute__((aligned(32)));
    uint8_t control_rx[64] __attribute__((aligned(32)));
    uint64_t epoch,last_epoch,generation,ticket,next_ticket;
    uint64_t source_head,started_us,last_status_us,telemetry_us;
    uint64_t ingressed,committed,discarded,transfers,failures,retries;
    uint64_t stale_completions,bad_status,source_rejections;
    uint64_t unexpected_stream_ends;
    uint64_t unexpected_generation_changes,telemetry_source_head,queries,urgent_queries;
    uint32_t next_sequence,last_ack,stream_generation;
    uint16_t head,count,reserved,credit,stream_buffered,stream_pending;
    uint8_t state,track,dma_active,dma_slot,dma_op,telemetry_valid,stream_state;
    uint8_t have_stream_generation,sd_request,force_refill,data_after_status,record_feedback,record_burst;
    /* The FPGA endpoint keeps its stream epoch across BL616-only resets, while
     * local epochs restart at 1. Wire epoch = epoch + wire_offset; a stale
     * remote stream is stopped by its own epoch before START is retried. */
    uint64_t wire_offset,stale_epoch;
    uint32_t stale_recoveries;
    uint8_t stale_stop,recover_tries;
    /* DATA is held until the MCU reservoir reaches service.mcu_target pairs
     * (start, and again after an FPGA underrun FADE/DRAIN), instead of
     * ending the stream on the first phone packet gap. */
    uint8_t primed;
    uint32_t reprimes;
    /* Diagnostics, cleared by the 2 s status line: longest DATA-to-DATA gap,
     * lowest FPGA buffered report while playing, DATA transactions started. */
    uint64_t last_data_us;
    uint32_t gap_max_us,data_count;
    uint16_t buffered_min;
    s10_tx_service_config service;
} s10_pcm_tx;
typedef struct {
    const uint8_t *tx;
    uint8_t *rx;
    uint64_t ticket,epoch,generation;
    uint16_t length,pairs;
    uint8_t operation;
} s10_tx_job;

/* All functions run in the sole bus-task context. The producer must marshal
 * enqueue calls to that owner; this module does not claim thread-safe/ISR use.
 * No HAL/Profile API is called. A job remains DMA-owned until complete() is
 * called AFTER both DMA channels stopped referencing its TX/RX buffers. */
void s10_pcm_tx_init(s10_pcm_tx *s);
/* Boot configuration only, while CLOSED. Defaults target a mean near 512
 * with 128-pair / 548-byte / 4-MHz transfers, not a pre-send waterlevel 512. */
int s10_pcm_tx_service_configure(s10_pcm_tx *s,const s10_tx_service_config *cfg);
void s10_pcm_tx_sd_request(s10_pcm_tx *s,int requested);
void s10_pcm_tx_refill(s10_pcm_tx *s);
int s10_pcm_tx_open(s10_pcm_tx *s,uint64_t epoch,int track);
/* epoch must strictly increase during this application's lifetime. */
int s10_pcm_tx_enqueue(s10_pcm_tx *s,uint64_t epoch,const int16_t *lr,size_t pairs);
int s10_pcm_tx_stop(s10_pcm_tx *s,uint64_t epoch);
int s10_pcm_tx_status_next(s10_pcm_tx *s,uint64_t now_us,s10_tx_job *job);
int s10_pcm_tx_next(s10_pcm_tx *s,uint64_t now_us,s10_tx_job *job);
int s10_pcm_tx_complete(s10_pcm_tx *s,uint64_t ticket,int success,uint64_t now_us);
size_t s10_pcm_tx_unsent(const s10_pcm_tx *s);
int s10_pcm_tx_conserved(const s10_pcm_tx *s);
uint32_t s10_pcm_crc32(const uint8_t *bytes,size_t length);
#endif
