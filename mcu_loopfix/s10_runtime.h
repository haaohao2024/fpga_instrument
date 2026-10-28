#ifndef S10_RUNTIME_H
#define S10_RUNTIME_H
#include "bus_fault.h"
#include <stdint.h>
int s10_runtime_prepare(void);
int s10_runtime_bluetooth_ready(void);
int s10_runtime_start_task(void);
int s10_runtime_bus_initialize(void);
/* Sole bus owner. Services one DMA job; nonzero means CS/DMA still owned.
 * Call before any polling SPI service or SD selection. */
int s10_runtime_bus_poll(void);
int s10_runtime_sd_exchange(const uint8_t *tx,unsigned bytes,uint32_t frequency);
int s10_runtime_bus_service(void);
int s10_runtime_sd_prepare(void *);
void s10_runtime_sd_retired(void *,uint64_t selected_us);
int s10_runtime_media_active(void);
int s10_runtime_media_available(void);
/* Shared short-lock service reservation. ACCEPTED AVDTP alone is not
 * project READY: maintenance can refuse project media admission as BUSY. */
int s10_runtime_media_claim(void);
void s10_runtime_media_release(void);
int s10_runtime_file_enter(void);
void s10_runtime_file_leave(void);
void s10_runtime_bus_wait(void);
void s10_runtime_snapshot(uint8_t reserved[12]);
/* Read-only media pipeline / PCM transport counters for the UART status line. */
int s10_runtime_media_diag(char *text,unsigned size);
/* Stage11 only: record preparation is maintenance and starts with media
 * CLOSED. The original transport configuration API owns the period change. */
int s10_runtime_record_prepare(void);
/* Mandatory after storage setup and START publication, including failure. */
void s10_runtime_record_prepared(void);
/* Sole file task: prepare -> actual file setup -> publish -> finish. */
int s10_runtime_record_start(uint64_t recording_id,unsigned mask);
#endif
