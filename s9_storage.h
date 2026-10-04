#ifndef S9_STORAGE_H
#define S9_STORAGE_H
#include <stdint.h>
/* Single file-task API. stop_confirmed is derived from the actual Stage7 STOP
 * response, never merely from sending STOP. Caller closes the score reader first. */
int s9_storage_recover(void); /* Startup, no open score/upload handles. */
int s9_storage_begin(const uint8_t owner[16],uint32_t bytes,uint32_t crc,int stop_confirmed);
int s9_storage_append(const uint8_t owner[16],uint32_t offset,const uint8_t *data,unsigned length);
int s9_storage_commit(const uint8_t owner[16]);
int s9_storage_cancel(const uint8_t owner[16]);
typedef int (*s9_storage_cancel_fn)(void *context);
typedef void (*s9_storage_progress_fn)(void *context,uint32_t bytes,unsigned phase);
void s9_storage_hooks(s9_storage_cancel_fn cancel,s9_storage_progress_fn progress,void *context);
typedef struct {uint32_t received,written,synced,checked,replaced;unsigned active;} s9_storage_stats;
const s9_storage_stats *s9_storage_statistics(void);
#endif
