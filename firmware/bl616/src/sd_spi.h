#ifndef SD_SPI_H
#define SD_SPI_H
#include "ff.h"
#include "sd_lease.h"
#include "diskio.h"
void sd_fault_context(uint32_t *command,uint32_t *phase,uint32_t *index);
typedef void (*sd_service_fn)(void *context);
/* Called only by the sole bus owner, with all CS released. The callback may
 * service FPGA traffic but must not recursively enter any SD operation. */
void sd_set_service(sd_service_fn service,void *context);
/* Sole bus owner changes the approved normal operating profile only with
 * all chip selects released. Initialization remains400kHz. */
int sd_set_recording_mode(int enabled);
int sd_set_recording_guard(int strict);
/* Current bounded lease, set before admission; includes release clocks. */
uint32_t sd_reservation_us(void);
/* Admission may only shorten the current unselected transaction. */
int sd_shorten_reservation(unsigned us);
int sd_lease_config(unsigned us);
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
    uint32_t last_timeout_phase,last_timeout_us,last_limit_us,max_setup_us,max_bulk_us;
} sd_diagnostics;
const sd_diagnostics *sd_get_diagnostics(void);
/* Quiescent diagnostic policy; single-block is the production default.
 * Changing this flag performs no hardware operation. */
void sd_set_multi_block(int enabled);
void sd_speed_report(void);
extern unsigned sd_data_dma;
int sd_data_config(unsigned enabled);
typedef struct {
    uint32_t command,r1,phase,sector,count,index,response,r2,transfer_failed;
    uint32_t observed_crc,expected_crc,frozen;
} sd_first_failure;
const sd_first_failure *sd_get_first_failure(void);
void sd_clear_first_failure(void);
#ifdef S9_RUNTIME
DSTATUS sd_bus_initialize(BYTE drive);
DSTATUS sd_bus_status(BYTE drive);
DRESULT sd_bus_read(BYTE drive,BYTE *buffer,LBA_t sector,UINT count);
DRESULT sd_bus_write(BYTE drive,const BYTE *buffer,LBA_t sector,UINT count);
DRESULT sd_bus_ioctl(BYTE drive,BYTE command,void *buffer);
#endif
#endif
