#ifndef S10_SD_ADMISSION_H
#define S10_SD_ADMISSION_H
#include "s10_pcm_tx.h"
#define S10_SD_WINDOW_US 100000u
#define S10_SD_BUDGET_US 16000u
#define S10_SD_MAX_US 8000u
#define S10_SD_HISTORY 64u
enum { S10_SD_OK=0,S10_SD_BUSY=-1,S10_SD_STOCK=-2,S10_SD_BUDGET=-3,S10_SD_CONTROL=-4,S10_SD_FAULT=-5 };
typedef struct {uint64_t start,end;} s10_sd_interval;
typedef struct {
    s10_sd_interval history[S10_SD_HISTORY];
    uint64_t epoch,started_us,finished_us,transactions,occupied_us;
    uint64_t denied_stock,denied_budget,denied_control,denied_busy;
    uint32_t worst_us,max_rolling_us,violations;
    uint8_t head,count,active,need_refill,fault;
} s10_sd_admission;
void s10_sd_admission_init(s10_sd_admission *s,uint64_t epoch);
/* snapshot comes from a CRC-checked flags=1 S10 status, its age includes the
 * complete SPI transfer. In-flight packet pairs are NOT unsent inventory. */
int s10_sd_admission_begin(s10_sd_admission *s,s10_pcm_tx *tx,uint64_t now_us,int control_pending);
int s10_sd_admission_end(s10_sd_admission *s,s10_pcm_tx *tx,uint64_t now_us);
int s10_sd_admission_pcm_started(s10_sd_admission *s,uint64_t now_us,unsigned pairs);
int s10_sd_admission_check(s10_sd_admission *s,uint64_t now_us);
uint32_t s10_sd_admission_rolling(const s10_sd_admission *s,uint64_t now_us);
#endif
