#ifndef S11_SERVICE_H
#define S11_SERVICE_H
#include "s11_protocol.h"
/* Native PCM plus24kB/s events/service reserve:96k=408kB/s,128k=536kB/s.
 * The actual SD card and RTOS service curve require board qualification. */
#include "audio_timebase.h"
/*128k:10MHz FPGA /20MHz SD, bounded software model=86.456ms/100ms.
 * Keep SD30ms cap; all traffic still accounted.90ms is an admission ceiling,
 * not measured WCET. No change to96k/48k or any audio deadline. */
#define S11_TOTAL_BUS_BUDGET_US (INSTRUMENT_AUDIO_HZ==128000u?90000u:80000u)
#define S11_FILE_SERVICE_BYTES_PER_SECOND (INSTRUMENT_AUDIO_HZ*4u+24000u)
typedef struct {
 uint64_t recording_id,received_pcm,received_cells,stored_pcm,stored_cells,duplicate_blocks,wire_transactions,service_violations,wire_waits;
 uint64_t first_frame,last_frame,missing_frame,last_poll_us;
 uint32_t command_sequence,last_command,ack_sequence,block_sequence;
 uint16_t pcm_buffered,event_buffered;
 uint8_t mask,wire_state,ack_kind,command,active,error,ack_pending;
} s11_service_stats;
void s11_service_init(void);
int s11_service_start(uint64_t id,unsigned mask);
int s11_service_can_start(uint64_t id,unsigned mask);
int s11_service_stop(uint64_t id);
/* Includes an ordered STOP queued behind an unconfirmed START. */
uint32_t s11_service_command_target(void);
int s11_service_active(void);
/* Exclusive event-only RAM sink; never enters storage/FatFs. */
int s11_service_ram_start(uint64_t id);
int s11_service_ram_owned(void);
uint64_t s11_service_next_id(void);
unsigned s11_service_ram_pop(uint8_t *cells,unsigned max_cells);
int s11_service_ram_caught_up(void);
int s11_service_ram_release(void);
const s11_service_stats *s11_service_statistics(void);
void s11_service_request(uint8_t packet[S11_WIRE_BYTES],const uint8_t *legacy_media,unsigned legacy_length);
unsigned s11_service_request_mode(uint8_t packet[S11_WIRE_BYTES],const uint8_t *legacy_media,unsigned legacy_length,unsigned reverse_capacity);
int s11_service_response(const uint8_t packet[S11_WIRE_BYTES]);
int s11_service_response_bytes(const uint8_t *packet,unsigned length);
int s11_service_file_step(int media_active);
void s11_service_fail(int reason,uint64_t missing_frame);
void s11_service_info(uint8_t info[72]);
/* Actual wire accounting: SD-only2ms occupancy/30ms rolling100ms; total
 * planned/actual line-time no more than80%. Conservative millisecond buckets
 * include a complete overlapping bucket; no boundary under-count. */
int s11_service_sd_reserve(uint64_t now,int stock,uint32_t limit);
int s11_service_sd_begin(uint64_t now_us,int media_stock_ready);
int s11_service_sd_end(uint64_t now_us,uint64_t occupied_us);
void s11_service_wire(uint64_t now_us,uint32_t selected_us,int sd);
/* Sole bus owner calls before a non-SD transaction. Denial is a bounded
 * scheduling wait; it never discards a reserved media job or an ACK. No
 * other transaction may start before the quoted one is completed. */
int s11_service_wire_begin(uint64_t now_us,uint32_t selected_upper_us);
int s11_service_card_progress(uint64_t now_us,uint32_t completed_bytes,uint32_t pending_bytes);
#endif
