#include "record_observer.h"
#include "bus_fault.h"
#include "record_hot.h"
/* SDHC/SDXC SPI, fixed 512-byte blocks. Normal transfers have an 8 ms CS
 * occupancy deadline. Write programming busy is polled with CS released
 * between polls, allowing the single bus task to service control traffic.
 * CMD13 and CTRL_SYNC are real card operations, not unconditional success.
 */
#include "score_hal.h"
#include "sd_spi.h"
#include "sd_lease.h"
#include "sd_proof.h"
#include <stdio.h>
#include "record_timing.h"
#include "record_trace.h"
#include "sd_wait_diag.h"
#include <string.h>
#ifdef S9_RUNTIME
#define disk_initialize sd_bus_initialize
#define disk_status sd_bus_status
#define disk_read sd_bus_read
#define disk_write sd_bus_write
#define disk_ioctl sd_bus_ioctl
#endif
static DSTATUS status=STA_NOINIT;
static uint32_t sectors,frequency=400000;
/* proof_hz 0: normal recording uses 40 MHz once High Speed is active,
 * otherwise 20 MHz. recbench still selects an exact rate. */
static uint32_t proof_hz,proof_crc_requested=1,proof_card_crc;
static sd_proof_state proof;
static struct {int32_t check_result,switch_result;uint32_t supported,active;} speed;
static uint32_t record_hz(void){return proof_hz?proof_hz:speed.active?40000000u:20000000u;}
volatile uint32_t sd_proof_feed_crc,sd_proof_feed_count,sd_proof_feed_enabled;
/* Normal capture keeps card CRC; byte-for-byte CPU/FIFO diagnostics are opt-in. */
volatile uint32_t sd_proof_observe;
unsigned sd_data_dma=1;

const uint16_t sd_proof_crc_nibble[16]={0,0x1021,0x2042,0x3063,0x4084,0x50a5,0x60c6,0x70e7,0x8108,0x9129,0xa14a,0xb16b,0xc18c,0xd1ad,0xe1ce,0xf1ef};

static unsigned recording_mode;
static unsigned strict_record_guard=1;
static uint32_t reservation_us=8000;
RECORD_HOT uint32_t sd_reservation_us(void){return reservation_us;}
static uint64_t selected_since,lease_since;
static unsigned selected,transfer_failed,io_phase;
RECORD_HOT int sd_shorten_reservation(unsigned us){
 if(selected||!us||us>reservation_us)return -1;
 reservation_us=us;return 0;
}
static unsigned resume_policy=16;
static unsigned batch_lease;
/* Card busy has no bounded duration. A native CMD25 with an accepted block
 * may outlive its lease only to reach ready and STOP: the lease schedules
 * work, the card busy limit decides failure. */
#define SD_BATCH_BUSY_MAX_US 250000u
static unsigned batch_overrun;
static uint64_t batch_since;
static uint32_t local_write_lease_us=SD_LOCAL_LEASE_US;
int sd_lease_config(unsigned us){
 if(selected||batch_lease||(us!=2000u&&us!=3000u&&us!=4000u&&us!=6000u&&us!=8000u))return -1;
 local_write_lease_us=us;return 0;
}
int sd_data_config(unsigned enabled){
 if(enabled>1||selected||batch_lease)return -1;
 sd_data_dma=enabled;return 0;
}
static struct {uint32_t batches,stops,max_cs,short_batches,singles,overruns,max_overrun;} resume_stats;
int sd_resume_config(unsigned policy){
 if(selected||batch_lease||(policy!=8&&policy!=12&&policy!=16))return -1;
 resume_policy=policy;memset(&resume_stats,0,sizeof resume_stats);return 0;
}
int sd_proof_config(uint32_t hz,unsigned card_crc,unsigned observe){
 if((!RECORD_FIFO_PROOF&&observe)||selected||(hz!=20000000u&&hz!=40000000u)||card_crc>1||observe>1)return -1;
 if(hz==40000000u&&(status||!speed.active))return -1;
 proof_hz=hz;proof_crc_requested=card_crc;sd_proof_observe=observe;strict_record_guard=0;memset(&proof,0,sizeof proof);return 0;
}
void sd_speed_report(void){
 printf("SD_SPEED check=%ld switch=%ld supported=%lu active=%lu\r\n",(long)speed.check_result,(long)speed.switch_result,(unsigned long)speed.supported,(unsigned long)speed.active);
}
const sd_proof_state *sd_proof_get(void){return &proof;}
void sd_proof_report(void){
 if(!RECORD_FIFO_PROOF)puts("SD_PROOF_CAP fifo_observer=0");
 printf("SD_PROOF hz=%lu crc_requested=%lu crc_active=%lu observe=%lu blocks=%lu source=%lu feed=%lu rejects=%lu\r\n",(unsigned long)proof_hz,(unsigned long)proof_crc_requested,(unsigned long)proof_card_crc,(unsigned long)sd_proof_observe,(unsigned long)proof.blocks,(unsigned long)proof.source_changes,(unsigned long)proof.feed_changes,(unsigned long)proof.rejects);
 printf("SD_PROOF_FIRST reason=%lu sector=%lu index=%lu before=%lu feed=%lu after=%lu response=%lu count=%lu\r\n",(unsigned long)proof.frozen,(unsigned long)proof.sector,(unsigned long)proof.index,(unsigned long)proof.before,(unsigned long)proof.feed,(unsigned long)proof.after,(unsigned long)proof.response,(unsigned long)proof.count);
 printf("SD_BATCH policy=%u batches=%lu stops=%lu max_us=%lu short=%lu singles=%lu overruns=%lu max_overrun_us=%lu\r\n",resume_policy,(unsigned long)resume_stats.batches,(unsigned long)resume_stats.stops,(unsigned long)resume_stats.max_cs,(unsigned long)resume_stats.short_batches,(unsigned long)resume_stats.singles,(unsigned long)resume_stats.overruns,(unsigned long)resume_stats.max_overrun);

}

static unsigned multi_block_enabled;
static int write_window;
static sd_first_failure sd_context,sd_first_error;
void sd_set_multi_block(int enabled){multi_block_enabled=enabled>=2&&enabled<=3?(unsigned)enabled:enabled!=0;}
const sd_first_failure *sd_get_first_failure(void){return &sd_first_error;}
void sd_clear_first_failure(void){memset(&sd_context,0,sizeof sd_context);memset(&sd_first_error,0,sizeof sd_first_error);}
static void freeze_io_failure(void){if(!sd_first_error.frozen){sd_context.phase=io_phase;sd_context.transfer_failed=transfer_failed;sd_first_error=sd_context;sd_first_error.frozen=1;}}
static sd_service_fn service;
static void *service_context;
static sd_diagnostics diag;
static sd_admission_fn admission;
static sd_retired_fn retired;
static void *admission_context;
static unsigned admission_denied;
void sd_set_admission(sd_admission_fn before,sd_retired_fn after,void *context){admission=before;retired=after;admission_context=context;}
void sd_set_service(sd_service_fn f,void *context){service=f;service_context=context;}
const sd_diagnostics *sd_get_diagnostics(void){return &diag;}
int sd_set_recording_mode(int enabled){if(selected)return -1;recording_mode=enabled!=0;if(!status)frequency=recording_mode?record_hz():20000000;return 0;}
RECORD_HOT __attribute__((optimize("Os"))) int sd_set_recording_guard(int strict){if(selected)return -1;strict_record_guard=strict!=0;if(strict_record_guard){write_window=0;if(reservation_us>SD_MIXED_LEASE_US)reservation_us=SD_MIXED_LEASE_US;}return 0;}
RECORD_HOT __attribute__((optimize("Os"))) static __attribute__((noinline)) uint32_t selected_limit(void){return batch_overrun?SD_BATCH_BUSY_MAX_US:write_window?reservation_us:(recording_mode&&!status&&strict_record_guard?reservation_us-2u:8000u);}
/* Native CMD24 only schedules against its grant: an overrun (task or IRQ
 * preemption) is counted in release(), and the grant ends after this block
 * because the ready probe and the next CMD24 both need remaining grant.
 * It fails only when the card stays busy past the SD write busy bound;
 * stalled SPI/DMA transfers still fail through their own progress limits. */
#define SD_NATIVE_FAIL_US 250000u
RECORD_HOT static uint32_t failure_limit(void){
 if(write_window&&!batch_lease)return SD_NATIVE_FAIL_US;
 return selected_limit();
}
RECORD_HOT __attribute__((optimize("Os"))) static uint32_t selected_elapsed(void){return (uint32_t)(hal_time_us()-(batch_lease?batch_since:(write_window||(recording_mode&&!status&&strict_record_guard)?lease_since:selected_since)));}
static const uint16_t crc16_table[256] RECORD_CONST={
 0x0000,0x1021,0x2042,0x3063,0x4084,0x50a5,0x60c6,0x70e7,
 0x8108,0x9129,0xa14a,0xb16b,0xc18c,0xd1ad,0xe1ce,0xf1ef,
 0x1231,0x0210,0x3273,0x2252,0x52b5,0x4294,0x72f7,0x62d6,
 0x9339,0x8318,0xb37b,0xa35a,0xd3bd,0xc39c,0xf3ff,0xe3de,
 0x2462,0x3443,0x0420,0x1401,0x64e6,0x74c7,0x44a4,0x5485,
 0xa56a,0xb54b,0x8528,0x9509,0xe5ee,0xf5cf,0xc5ac,0xd58d,
 0x3653,0x2672,0x1611,0x0630,0x76d7,0x66f6,0x5695,0x46b4,
 0xb75b,0xa77a,0x9719,0x8738,0xf7df,0xe7fe,0xd79d,0xc7bc,
 0x48c4,0x58e5,0x6886,0x78a7,0x0840,0x1861,0x2802,0x3823,
 0xc9cc,0xd9ed,0xe98e,0xf9af,0x8948,0x9969,0xa90a,0xb92b,
 0x5af5,0x4ad4,0x7ab7,0x6a96,0x1a71,0x0a50,0x3a33,0x2a12,
 0xdbfd,0xcbdc,0xfbbf,0xeb9e,0x9b79,0x8b58,0xbb3b,0xab1a,
 0x6ca6,0x7c87,0x4ce4,0x5cc5,0x2c22,0x3c03,0x0c60,0x1c41,
 0xedae,0xfd8f,0xcdec,0xddcd,0xad2a,0xbd0b,0x8d68,0x9d49,
 0x7e97,0x6eb6,0x5ed5,0x4ef4,0x3e13,0x2e32,0x1e51,0x0e70,
 0xff9f,0xefbe,0xdfdd,0xcffc,0xbf1b,0xaf3a,0x9f59,0x8f78,
 0x9188,0x81a9,0xb1ca,0xa1eb,0xd10c,0xc12d,0xf14e,0xe16f,
 0x1080,0x00a1,0x30c2,0x20e3,0x5004,0x4025,0x7046,0x6067,
 0x83b9,0x9398,0xa3fb,0xb3da,0xc33d,0xd31c,0xe37f,0xf35e,
 0x02b1,0x1290,0x22f3,0x32d2,0x4235,0x5214,0x6277,0x7256,
 0xb5ea,0xa5cb,0x95a8,0x8589,0xf56e,0xe54f,0xd52c,0xc50d,
 0x34e2,0x24c3,0x14a0,0x0481,0x7466,0x6447,0x5424,0x4405,
 0xa7db,0xb7fa,0x8799,0x97b8,0xe75f,0xf77e,0xc71d,0xd73c,
 0x26d3,0x36f2,0x0691,0x16b0,0x6657,0x7676,0x4615,0x5634,
 0xd94c,0xc96d,0xf90e,0xe92f,0x99c8,0x89e9,0xb98a,0xa9ab,
 0x5844,0x4865,0x7806,0x6827,0x18c0,0x08e1,0x3882,0x28a3,
 0xcb7d,0xdb5c,0xeb3f,0xfb1e,0x8bf9,0x9bd8,0xabbb,0xbb9a,
 0x4a75,0x5a54,0x6a37,0x7a16,0x0af1,0x1ad0,0x2ab3,0x3a92,
 0xfd2e,0xed0f,0xdd6c,0xcd4d,0xbdaa,0xad8b,0x9de8,0x8dc9,
 0x7c26,0x6c07,0x5c64,0x4c45,0x3ca2,0x2c83,0x1ce0,0x0cc1,
 0xef1f,0xff3e,0xcf5d,0xdf7c,0xaf9b,0xbfba,0x8fd9,0x9ff8,
 0x6e17,0x7e36,0x4e55,0x5e74,0x2e93,0x3eb2,0x0ed1,0x1ef0,
};
void sd_fault_context(uint32_t *command,uint32_t *phase,uint32_t *index){*command=sd_context.command;*phase=io_phase;*index=sd_context.index;}
RECORD_HOT static uint16_t crc16(const uint8_t *b,unsigned n){uint16_t c=0;while(n--)c=(uint16_t)((c<<8)^crc16_table[((c>>8)^*b++)&255u]);return c;}
RECORD_HOT static __attribute__((noinline)) int failed(void){
 if(hal_io_failed()||hal_cancelled()){transfer_failed=1;return 1;}
 if((selected||batch_lease)&&selected_elapsed()>failure_limit()){
  if(!transfer_failed){diag.deadline_errors++;diag.last_timeout_phase=io_phase;diag.last_timeout_us=selected_elapsed();diag.last_limit_us=failure_limit();}
  transfer_failed=1;
 }
 return transfer_failed;
}
RECORD_HOT static uint8_t exchange(uint8_t value){
 if(failed())return 255;
 /* Do not start a byte whose wire time already exceeds the remaining budget. */
 if(selected&&selected_elapsed()+(8000000u+frequency-1)/frequency>failure_limit()){
  diag.deadline_errors++;diag.last_timeout_phase=io_phase;diag.last_timeout_us=selected_elapsed();diag.last_limit_us=failure_limit();transfer_failed=1;return 255;
 }
 if(sd_wait_active)sd_wait_before();
 uint8_t r=hal_exchange(value);
 if(sd_wait_active)sd_wait_after(r);
 failed();return r;
}
RECORD_HOT static int exchange_block(const uint8_t *tx,uint8_t *rx,unsigned bytes){
 if(failed())return -1;
 uint64_t began=hal_time_us();
 int r=hal_exchange_block(tx,rx,bytes);
 uint32_t elapsed=(uint32_t)(hal_time_us()-began);
 record_trace_measure(0,elapsed);
 if(elapsed>diag.max_bulk_us)diag.max_bulk_us=elapsed;
 if(r)transfer_failed=1;
 return failed()?-1:0;
}
RECORD_HOT static void release(void){
 if(bus_fault_active())return;
 unsigned was_selected=selected;
 uint64_t duration=was_selected?hal_time_us()-selected_since:0;
 if(was_selected&&write_window&&duration>resume_stats.max_cs)resume_stats.max_cs=(uint32_t)duration;
 if(was_selected&&duration>diag.max_selected_us)diag.max_selected_us=(uint32_t)duration;
 if(was_selected&&write_window&&!batch_lease){uint32_t used=(uint32_t)(hal_time_us()-lease_since);if(used>reservation_us){resume_stats.overruns++;if(used>resume_stats.max_overrun)resume_stats.max_overrun=used;}}
 /* With admission enabled a prior service window may own FPGA DMA.
  * An already-released SD interval must not deassert that unrelated CS. */
 if(was_selected||!admission){
  if(hal_io_failed())transfer_failed=1;
  if(hal_select(BUS_NONE)||bus_fault_active()){transfer_failed=1;return;}
  hal_exchange(255);if(hal_io_failed())transfer_failed=1;if(bus_fault_active())return;
  selected=0;
 }
 if(was_selected&&retired&&!batch_lease){uint64_t began=hal_time_us();uint32_t used=(uint32_t)(recording_mode&&!status?hal_time_us()-lease_since:duration);record_phase_add(RP_SD_LEASE,used);retired(admission_context,used);record_trace_measure(6,(uint32_t)(hal_time_us()-began));}
}
RECORD_HOT __attribute__((optimize("Os"))) static int admit_card(void){
 if(!admission)return 0;
 uint64_t began=hal_time_us();int r=admission(admission_context);
 record_phase_add(RP_ADMIT,(uint32_t)(hal_time_us()-began));
 if(r)admission_denied=1;
 return r;
}
/* A logical grant spans all preparation commands, DATA and STOP. Physical
 * CS still toggles between commands. No other target is serviced here. */
RECORD_HOT __attribute__((optimize("Os"))) static int begin_batch_lease(void){
 reservation_us=local_write_lease_us;admission_denied=transfer_failed=0;batch_overrun=0;
 if(admit_card())return -1;
 batch_since=hal_time_us();batch_lease=1;return 0;
}
/* Native only, after at least one accepted block: keep the open CMD25 until
 * ready and STOP instead of abandoning it mid-stream. The CS is still not
 * released before STOP, so no other target sees a half-open CMD25. */
RECORD_HOT static void extend_batch(void){
 if(batch_overrun||!batch_lease||!write_window)return;
 batch_overrun=1;hal_io_deadline(batch_since+SD_BATCH_BUSY_MAX_US);
}
RECORD_HOT __attribute__((optimize("Os"))) static int end_batch_lease(void){
 unsigned overrun=batch_overrun;batch_overrun=0;
 if(bus_fault_active())return -1;
 if(!batch_lease)return 0;
 uint32_t us=(uint32_t)(hal_time_us()-batch_since);batch_lease=0;
 if(us>resume_stats.max_cs)resume_stats.max_cs=us;
 record_phase_add(RP_SD_LEASE,us);
 if(retired)retired(admission_context,us);
 if(!recording_mode||us<=reservation_us)return 0;
 if(!overrun&&!write_window)return -1;
 /* Reported, not fatal: FPGA PCM overflow still reports any real loss. */
 resume_stats.overruns++;if(us>resume_stats.max_overrun)resume_stats.max_overrun=us;
 return 0;
}
RECORD_HOT static int select_card(uint32_t lease){
 if(!batch_lease)reservation_us=recording_mode&&!status?lease:8000u;
 transfer_failed=0;admission_denied=0;
 if(!batch_lease&&admit_card())return -1;
 /* Admission callbacks may configure SPI for FPGA traffic. Restore SD speed
  * only after a grant, while every shared CS is high. */
 lease_since=batch_lease?batch_since:hal_time_us();hal_frequency(frequency);
 selected_since=hal_time_us();
 if(hal_select(BUS_SD)){transfer_failed=1;return -1;}selected=1;hal_io_deadline((batch_lease?batch_since:lease_since)+failure_limit());uint32_t setup=(uint32_t)(hal_time_us()-lease_since);if(setup>diag.max_setup_us)diag.max_setup_us=setup;record_timing(4,setup,io_phase,reservation_us);return 0;
}
RECORD_HOT static void service_window(void){
 release();diag.service_windows++;
 if(service){uint64_t began=hal_time_us();service(service_context);record_trace_measure(7,(uint32_t)(hal_time_us()-began));}
 /* The callback may have changed SPI speed while serving control. */
 if(!admission)hal_frequency(frequency);
}
RECORD_HOT static int wait_ready(unsigned extend){
 sd_wait_begin(2,sd_context.command,sd_context.sector+sd_context.index);
 do{if(extend&&!batch_overrun&&selected_elapsed()+200u>=selected_limit())extend_batch();if(failed())break;if(exchange(255)==255&&!failed()){order_trace_take(OT_SD_READY,1);sd_wait_end(1);return 0;}}while(!failed());
 sd_wait_end(-1);return -1;
}
static uint8_t command_crc(const uint8_t *p){
 uint8_t c=0;for(unsigned i=0;i<5;i++)for(unsigned b=0;b<8;b++){
  unsigned bit=((p[i]>>(7-b))&1u)^((c>>6)&1u);c=(uint8_t)((c<<1)&127u);if(bit)c^=9u;
 }return (uint8_t)((c<<1)|1u);
}
RECORD_HOT static int command(uint8_t cmd,uint32_t arg){
 order_trace_data(OT_SD_COMMAND,cmd,arg);
 sd_context.command=cmd;sd_context.r1=UINT32_MAX;sd_context.r2=0;
 io_phase=cmd==13?5:1;
 /* Native CMD24 burst: a card that reached ready while still selected
  * takes the next CMD24 inside the same admitted grant. Busy beyond the
  * grant is still released and polled by programming_done(). */
 if(!(cmd==24&&write_window&&selected&&!batch_lease&&selected_elapsed()+700u<=selected_limit())){
  release();
  unsigned lease=cmd==13?SD_MIXED_LEASE_US:(cmd==24&&write_window?local_write_lease_us:2000u);
  if(select_card(lease))return -1;
 }
 if(wait_ready(0))return -1;
 uint64_t wire_began=hal_time_us();
 uint8_t b[6]={0x40|cmd,arg>>24,arg>>16,arg>>8,arg,(cmd==0)?0x95:(cmd==8)?0x87:1};
 b[5]=command_crc(b);
 for(unsigned i=0;i<6;i++)exchange(b[i]);
 for(unsigned i=0;i<16&&!failed();i++){uint8_t r=exchange(255);if(!(r&128)){sd_context.r1=r;record_phase_add(RP_COMMAND,(uint32_t)(hal_time_us()-wire_began));return r;}}
 return -1;
}
static int proof_apply(void){
 if(proof_crc_requested==proof_card_crc)return 0;
 int r=command(59,proof_crc_requested);release();
 if(r){if(!proof.frozen)proof.frozen=8;return -1;}
 proof_card_crc=proof_crc_requested;return 0;
}
RECORD_HOT static int read_block(uint8_t *b,unsigned n){
 io_phase=2;uint8_t token=255;
 do{if(failed())return -1;token=exchange(255);if(token==0xfe)break;if(token!=255)return -1;}while(!failed());
 if(token!=0xfe||failed())return -1;
 if(exchange_block(0,b,n))return -1;
 uint16_t crc=(uint16_t)exchange(255)<<8;crc|=exchange(255);
 sd_context.observed_crc=crc;sd_context.expected_crc=crc16(b,n);
 return !failed()&&crc==sd_context.expected_crc?0:-1;
}
/* Runs only during SD initialization, with sole bus ownership and no file
 * transaction. Both comparison rates subsequently use this same HS mode. */
static void configure_high_speed(void){
 uint8_t b[64];int r=command(6,0x00fffff1u);
 if(!r)r=read_block(b,64)?-1:0;
 release();speed.check_result=r;
 if(r)return;
 speed.supported=!!(b[13]&2u);if(!speed.supported)return;
 r=command(6,0x80fffff1u);if(!r)r=read_block(b,64)?-1:0;release();
 if(!r&&(b[16]&15u)!=1u)r=-2;
 speed.switch_result=r;speed.active=!r;
}

/* Programming may take much longer than 8 ms, but NEVER owns the bus while
 * waiting. Up to 500 ms overall is allowed; cancellation still takes effect. */
RECORD_HOT static int programming_done_impl(void){
 uint64_t start=hal_time_us();
 do{
  io_phase=4;if(hal_cancelled()||select_card(SD_MIXED_LEASE_US))return -1;
  sd_wait_begin(3,sd_context.command,sd_context.sector+sd_context.index);
  /* First byte supplies clocks after reselect; the second reads busy status. */
  exchange(255);uint8_t ready=exchange(255);int bad=failed();sd_wait_end(bad?-1:ready==255);release();
  if(bad)return -1;
  if(ready==255){order_trace_take(OT_SD_READY,2);return 0;}
  service_window();hal_delay_us(100);
 }while(hal_time_us()-start<500000);
 return -1;
}
RECORD_HOT static int programming_done(void){record_observer_phase(OBS_BUS,26);
 uint64_t began=hal_time_us();int result=programming_done_impl();
 record_trace_measure(1,(uint32_t)(hal_time_us()-began));return result;
}
/* Native capture only: probe busy while selected until the grant tail,
 * reserving200us. CMD24 then releases and polls; a CMD25 stream must
 * reach ready and STOP before any FPGA service. */
#define SD_READY_GRANT_TAIL_US 200u
RECORD_HOT static int short_programming_ready(void){
 uint64_t began=hal_time_us();
 int result=0;
 sd_wait_begin(1,sd_context.command,sd_context.sector+sd_context.index);
 while(selected_elapsed()+SD_READY_GRANT_TAIL_US<selected_limit()){
  uint8_t ready=exchange(UINT8_MAX);
  if(failed()){
   result=-1;
   break;
  }
  if(ready==UINT8_MAX){
   result=1;
   break;
  }
 }
 order_trace_take(OT_SD_READY,result==1?3u:0u);
 sd_wait_end(result);
 record_trace_measure(RP_CARD_BUSY,(uint32_t)(hal_time_us()-began));
 return result;
}
RECORD_HOT static int card_status(void){
 if(command(13,0)!=0){release();return -1;}
 uint8_t r2=exchange(255);sd_context.r2=r2;int bad=failed();release();return (bad||r2)?-1:0;
}
static DRESULT io_error(void){if(bus_fault_active()){status=STA_NOINIT;diag.io_errors++;return RES_ERROR;}order_trace_freeze(2);release();end_batch_lease();
 /* No SD wire operation took place for an admission denial. Do not claim
  * card damage or invalidate an initialized card; the caller safely stops
  * the score source if its bounded service window could not be met. */
 if(admission_denied)return RES_NOTRDY;
 freeze_io_failure();
 diag.io_errors++;status=STA_NOINIT;return RES_ERROR;}
DSTATUS disk_initialize(BYTE drive){
 if(drive)return STA_NOINIT;
 memset(&speed,0,sizeof speed);speed.check_result=speed.switch_result=-1;
 status=STA_NOINIT;sectors=0;frequency=400000;proof_card_crc=0;transfer_failed=0;selected=0;
 hal_frequency(frequency);release();for(int i=0;i<10;i++)hal_exchange(255);
 if(command(0,0)!=1)goto fail;
 service_window();
 if(command(8,0x1aa)!=1)goto fail;
 uint8_t r7[4];for(int i=0;i<4;i++)r7[i]=exchange(255);
 if(failed()||r7[2]!=1||r7[3]!=0xaa)goto fail;
 service_window();
 uint64_t start=hal_time_us();int r;
 do{
  if(command(55,0)!=1)goto fail;
  release();r=command(41,0x40000000);
  if(r<0||failed())goto fail;
  service_window();
 }while(r==1&&hal_time_us()-start<1000000);
 if(r!=0||command(58,0)!=0)goto fail;
 uint32_t ocr=0;for(int i=0;i<4;i++)ocr=(ocr<<8)|exchange(255);
 if(failed()||(ocr&0xc0000000)!=0xc0000000)goto fail;
 service_window();
 if(command(9,0)!=0)goto fail;
 uint8_t csd[16];if(read_block(csd,16)||csd[0]>>6!=1)goto fail;release();
 uint32_t size=((uint32_t)(csd[7]&63)<<16)|((uint32_t)csd[8]<<8)|csd[9];
 if(size==0x3fffff)goto fail;
 sectors=(size+1)*1024;
 frequency=20000000u;hal_frequency(frequency);configure_high_speed();sd_speed_report();
 if(proof_hz==40000000u&&!speed.active)goto fail;
 frequency=recording_mode?record_hz():20000000;hal_frequency(frequency);status=0;return status;
 fail:release();diag.io_errors++;return status;
}
DSTATUS disk_status(BYTE drive){return drive?STA_NOINIT:status;}
DRESULT disk_read(BYTE drive,BYTE *buffer,LBA_t sector,UINT count){
 if(drive||!buffer||!count)return RES_PARERR;
 if(status||hal_cancelled())return RES_NOTRDY;
 if(proof_apply())return io_error();
 if(sector>=sectors||count>sectors-sector)return RES_PARERR;
 for(UINT i=0;i<count;i++){
  /* A read lost only to its lease limit (preempted past ~2ms) leaves the card
   * intact; retry it once on a fresh lease instead of de-initializing the
   * card, which FatFs cannot remount while a link service is open. */
  for(unsigned attempt=0;;attempt++){
   if(command(17,(uint32_t)(sector+i))==0&&!read_block(buffer+512*i,512))break;
   if(attempt||bus_fault_active()||admission_denied)return io_error();
   release();uint64_t t=hal_time_us();while(hal_time_us()-t<1000u){} /* card finishes the block */
  }
  release();diag.reads++;service_window();
 }
 return RES_OK;
}
static DRESULT write_failure(int multi){
 if(bus_fault_active()){status=STA_NOINIT;diag.io_errors++;return RES_ERROR;}
 if(selected&&write_window){uint32_t us=selected_elapsed();if(us>resume_stats.max_cs)resume_stats.max_cs=us;}
 /* A failed write surfaces only as FR_DISK_ERR. Print the failing step once,
  * before cleanup clears the HAL flag; failures are rare, so no rate limit. */
 printf("SD_WRITE_FAIL cmd=%lu r1=%ld phase=%u sector=%lu index=%lu",
        (unsigned long)sd_context.command,(long)(int32_t)sd_context.r1,io_phase,
        (unsigned long)sd_context.sector,(unsigned long)sd_context.index);
 printf(" response=%ld crc=%04lx/%04lx xfer=%u hal=%d denied=%u elapsed_us=%lu\r\n",
        (long)(int32_t)sd_context.response,(unsigned long)sd_context.observed_crc,
        (unsigned long)sd_context.expected_crc,transfer_failed,hal_io_failed(),admission_denied,
        (unsigned long)selected_elapsed());
 order_trace_freeze(3);
 write_window=0;
 /* Preserve the failing byte/index before cleanup sends a stop token. */
 if(!admission_denied)freeze_io_failure();
 unsigned denied=admission_denied;
 release();end_batch_lease();
 if(multi){
  release();
  if(!select_card(SD_MIXED_LEASE_US)){exchange(0xfd);exchange(255);release();}
 }
 admission_denied=denied;return io_error();
}
RECORD_HOT static int finish_batch(unsigned *open){
 if(selected_elapsed()+100u>=selected_limit())extend_batch();
 order_trace_take(OT_STOP,1);exchange(0xfd);if(failed())return -1;*open=0;exchange(255);
 if(failed())return -1;
 record_phase_card_begin(hal_time_us());
 /* DATA is terminated. Card programming can overlap FPGA service. */
 release();int r=end_batch_lease();if(!r){service_window();r=programming_done();}
 record_phase_card_end(hal_time_us());
 if(r)return -1;
 resume_stats.stops++;order_trace_take(OT_STOP,2);return 0;
}
DRESULT disk_write(BYTE drive,const BYTE *buffer,LBA_t sector,UINT count){
 if(drive||!buffer||!count)return RES_PARERR;
 if(status||hal_cancelled())return RES_NOTRDY;
 if(proof_apply())return io_error();
 if(sector>=sectors||count>sectors-sector)return RES_PARERR;
 sd_context.sector=(uint32_t)sector;sd_context.count=count;sd_context.index=0;sd_context.response=UINT32_MAX;sd_context.observed_crc=sd_context.expected_crc=0;
 int multi=multi_block_enabled&&count>1;
 unsigned chunk=multi?4u:0u,batch_end=0,batch_start=0,batch_open=0;
 uint16_t batch_crc[4];
 /* Native CMD24 uses its configured DATA grant; subsequent card
  * busy probes each receive the existing2ms mixed-service grant. CMD25 baseline unchanged. */
 write_window=recording_mode&&!strict_record_guard&&(!multi||multi_block_enabled==3);
 /* Optional diagnostic policy: hint exactly this validated disk-write
  * range, never an arbitrary erase or any sector beyond the caller's data.
  * Normal single/multi policies are unchanged. Rejected hints stop this
  * trial before CMD25; the first R1 is retained by the existing error path. */
 for(UINT i=0;i<count;){
  sd_context.index=i;sd_context.response=UINT32_MAX;order_trace_data(OT_SD_BLOCK,(uint32_t)(sector+i),(count<<16)|i);
  const uint8_t *p=buffer+i*512;uint16_t crc;
  if(!chunk||i==batch_end){
   unsigned n=chunk?count-i:1u;if(n>4)n=4;
   for(unsigned j=0;j<n;j++){uint64_t began=hal_time_us();batch_crc[j]=crc16(p+j*512,512);record_trace_measure(3,(uint32_t)(hal_time_us()-began));}
  }
  if(chunk&&i==batch_end)batch_start=i;
  crc=batch_crc[chunk?i-batch_start:0];
  if(write_window&&selected&&failed())return write_failure(chunk?batch_open:multi);
  if(chunk&&i==batch_end){
   if(begin_batch_lease())return io_error();
   UINT n=count-i;if(n>chunk)n=chunk;batch_end=i+n;batch_start=i;
   if(command(55,0)!=0||command(23,n)!=0){write_window=0;return io_error();}
   if(command(25,(uint32_t)(sector+i))!=0)return write_failure(chunk?batch_open:multi);
   batch_open=1;resume_stats.batches++;
  }
  if(!multi){if(command(24,(uint32_t)(sector+i))!=0)return write_failure(chunk?batch_open:multi);}
  /* A short complete batch is normal progress, not a recording error.
   * Never restart the current logical sector until STOP+ready completes.
   * At least one sector must have completed; a zero-progress grant fails. */
  if(chunk&&selected_elapsed()+700u>reservation_us){
   if(i==batch_start||(!write_window&&selected_elapsed()+100u>reservation_us))return write_failure(batch_open);
   if(finish_batch(&batch_open))return write_failure(batch_open);
   resume_stats.short_batches++;batch_end=i;continue;
  }
  io_phase=3;exchange(255);exchange(multi?0xfc:0xfe);
  if(exchange_block(p,0,512))return write_failure(chunk?batch_open:multi);
  uint16_t after=(RECORD_FIFO_PROOF&&sd_proof_observe)?crc16(p,512):crc;unsigned source_changed=after!=crc;
  unsigned feed_changed=RECORD_FIFO_PROOF&&sd_proof_observe&&(sd_proof_feed_count!=512u||sd_proof_feed_crc!=crc);
  exchange(crc>>8);exchange(crc);uint8_t response=exchange(255);sd_context.response=response;order_trace_take(OT_SD_RESPONSE,response);
  if((response&31)!=5)order_trace_freeze(1);
  proof.blocks++;proof.source_changes+=source_changed;proof.feed_changes+=feed_changed;proof.rejects+=(response&31)!=5;
  if(!proof.frozen&&(source_changed||feed_changed||(response&31)!=5)){
   proof.frozen=source_changed?1u:feed_changed?2u:4u;proof.sector=(uint32_t)(sector+i);proof.index=i;
   proof.before=crc;proof.feed=sd_proof_feed_crc;proof.after=after;proof.response=response;proof.count=sd_proof_feed_count;
  }
  if(failed()||(response&31)!=5)return write_failure(chunk?batch_open:multi);
  exchange(255);if(failed())return write_failure(chunk?batch_open:multi);
  int ready=write_window?short_programming_ready():0;
  if(ready<0)return write_failure(chunk?batch_open:multi);
  if(!ready){
   if(chunk){if(wait_ready(write_window))return write_failure(chunk?batch_open:multi);}
   else {release();if(programming_done())return write_failure(chunk?batch_open:multi);}
  }
  diag.writes++;
  if(!multi)resume_stats.singles++;
  if(chunk&&i+1==batch_end){
   if(finish_batch(&batch_open))return write_failure(chunk?batch_open:multi);
  }else if(!write_window&&!chunk){release();service_window();}
  i++;
 }
 /* Native capture: every block already returned an accepted data response
  * and the finished file is re-read and CRC-verified, so the per-call
  * CMD13 is skipped; end the grant before returning to the bus task. */
 if(write_window){release();write_window=0;return RES_OK;}
 if(card_status())return io_error();

 return RES_OK;
}
DRESULT disk_ioctl(BYTE drive,BYTE cmd,void *buffer){
 if(drive||status||hal_cancelled())return RES_NOTRDY;
 if(proof_apply())return io_error();
 switch(cmd){
 case CTRL_SYNC:if(programming_done()||card_status())return io_error();diag.syncs++;return RES_OK;
 case GET_SECTOR_COUNT:if(!buffer)return RES_PARERR;*(LBA_t*)buffer=sectors;return RES_OK;
 case GET_SECTOR_SIZE:if(!buffer)return RES_PARERR;*(WORD*)buffer=512;return RES_OK;
 case GET_BLOCK_SIZE:if(!buffer)return RES_PARERR;*(DWORD*)buffer=128;return RES_OK;
 default:return RES_PARERR;
 }
}

