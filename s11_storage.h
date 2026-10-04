#ifndef S11_STORAGE_H
#define S11_STORAGE_H
#include <stddef.h>
#include <stdint.h>
#include "s11_protocol.h"
enum {S11_STORE_IDLE=0,S11_STORE_CAPTURING=1,S11_STORE_DRAINING=2,S11_STORE_CLOSED=3,S11_STORE_VERIFY_PENDING=4,S11_STORE_SAVED=5,S11_STORE_INCOMPLETE=6,S11_STORE_ERROR=7};
typedef struct {
 uint64_t recording_id,first_frame,last_frame,missing_frame;
 uint32_t captured_pairs,pcm_bytes,event_units,event_pages,written_pcm,written_event;
 uint32_t verified_pcm,verified_event,pcm_crc,event_crc,pcm_file_crc,event_file_crc;
 uint8_t kinds,state;int error;
} s11_storage_stats;
/* Sole file-task APIs. No call is legal in a BLE callback or bus task.
 * Existing mounted FatFs volume is reused, allowing score and recording
 * handles to coexist. Prepare must run before media/recording admission. */
int s11_storage_prepare(uint64_t recording_id,unsigned kinds);
int s11_storage_pcm(uint64_t recording_id,uint64_t first_frame,const uint8_t *le_lr,unsigned pairs);
int s11_storage_events(uint64_t recording_id,const uint8_t *units,unsigned count);
int s11_storage_finish(uint64_t recording_id,int incomplete,uint64_t missing_frame,int media_active);
void s11_storage_failure(int reason);
int s11_storage_verify(void);
int s11_storage_download(uint64_t recording_id,unsigned kind,uint32_t offset,uint8_t *out,unsigned capacity,unsigned *read_count);
int s11_storage_export(uint64_t recording_id);
/* Retrieve immutable verified-file metadata, including older recordings.
 * Catalogue is persisted only after actual content reopen verification. */
int s11_storage_select(uint64_t recording_id);
const s11_storage_stats *s11_storage_statistics(void);
/* Scoped write permission for actual record file/metadata operations. It
 * does not admit upload, maintenance, initialization or another file owner. */
int s11_storage_write_authorized(void);
#endif
