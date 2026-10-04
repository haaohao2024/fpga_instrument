#ifndef SD_SPI_H
#define SD_SPI_H
#include "ff.h"
#include "diskio.h"
typedef void (*sd_service_fn)(void *context);
/* Called only by the sole bus owner, with all CS released. The callback may
 * service FPGA traffic but must not recursively enter any SD operation. */
void sd_set_service(sd_service_fn service,void *context);
/* Sole bus owner changes the approved normal operating profile only with
 * all chip selects released. Initialization remains400kHz. */
int sd_set_recording_mode(int enabled);
/* Current bounded lease, set before admission; includes release clocks. */
uint32_t sd_reservation_us(void);
/* Unique bus owner only. prepare runs before SD selection and must retire any non-SD DMA before grant; it may service
 * control/PCM while waiting for admission; nonzero refuses selection.
 * retired observes the end of each REAL selected interval, not an RPC.
 * NULL hooks preserve the existing SD driver contract. */
typedef int (*sd_admission_fn)(void *context);
typedef void (*sd_retired_fn)(void *context,uint64_t selected_us);
void sd_set_admission(sd_admission_fn prepare,sd_retired_fn retired,void *context);
typedef struct {
    uint32_t reads,writes,syncs,io_errors,deadline_errors,service_windows;
    uint32_t max_selected_us;
} sd_diagnostics;
const sd_diagnostics *sd_get_diagnostics(void);
#ifdef S9_RUNTIME
DSTATUS sd_bus_initialize(BYTE drive);
DSTATUS sd_bus_status(BYTE drive);
DRESULT sd_bus_read(BYTE drive,BYTE *buffer,LBA_t sector,UINT count);
DRESULT sd_bus_write(BYTE drive,const BYTE *buffer,LBA_t sector,UINT count);
DRESULT sd_bus_ioctl(BYTE drive,BYTE command,void *buffer);
#endif
#endif
