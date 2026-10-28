#include "record_hot.h"
/* Diagnostic-only read-only S11 query sweep. No START/STOP/ACK, SD access,
 * recorder-service mutation or CRC repair. Dedicated bus task runs this
 * before the production DMA object is bound; all jobs must retire first. */
#include "wire_probe.h"
#include "s11_service.h"
#include "s10_spi_dma.h"
#include "score_hal.h"
#include "s9_protocol.h"
#include "bflb_clock.h"
#include "bflb_spi.h"
#include "hardware/spi_reg.h"
#include "hardware/dma_reg.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "fpga_spi_waveform.h"
unsigned fpga_spi_waveform_asymmetric=2;
static unsigned ready_probe_attempts;
static uint32_t ready_wait_us;
static int ready_result;
static s10_spi_dma probe;
static uint8_t tx_backing[608] __attribute__((aligned(32)));
#define wire_probe_tx (*(uint8_t (*)[608])RECORD_DMA_PTR(tx_backing))
static uint8_t rx_backing[608] __attribute__((aligned(32)));
#define wire_probe_rx (*(uint8_t (*)[608])RECORD_DMA_PTR(rx_backing))
static unsigned ready,good_count;
static int failure;
static int in_range(const void *base,size_t cap,const void *p,size_t n){uintptr_t a=(uintptr_t)base,b=(uintptr_t)p;return b>=a&&b-a<=cap&&n<=cap-(b-a);}
static int ram(void *u,const void *p,size_t n){(void)u;return in_range(wire_probe_tx,sizeof wire_probe_tx,p,n)||in_range(wire_probe_rx,sizeof wire_probe_rx,p,n)||in_range(probe.tx_lli,sizeof probe.tx_lli,p,n)||in_range(probe.rx_lli,sizeof probe.rx_lli,p,n);}
static uint64_t now(void *u){(void)u;return hal_time_us();}
static int owner(void *u){(void)u;return hal_bus_owner();}
static int select_bus(void *u,int target){(void)u;return hal_select(target);}
static void query(void){memset(wire_probe_tx,0,sizeof wire_probe_tx);memcpy(wire_probe_tx,"S11P",4);wire_probe_tx[4]=S11_RECORD_VERSION;s9_put16(wire_probe_tx+52,512);s9_put32(wire_probe_tx+60,s9_crc32(wire_probe_tx,60));s9_put32(wire_probe_tx+576,s9_crc32(wire_probe_tx,576));}
static int response_good(void){return !memcmp(wire_probe_rx,"S7ST",4)&&wire_probe_rx[4]==S11_RECORD_VERSION&&s9_get32(wire_probe_rx+60)==s9_crc32(wire_probe_rx,60)&&s9_get32(wire_probe_rx+576)==s9_crc32(wire_probe_rx,576);}
static int wait_fpga_ready(void){
 uint64_t began=hal_time_us();
 do{
  ready_probe_attempts++;hal_frequency(5000000u);
  if(hal_select(BUS_FPGA))return -1;
  for(unsigned byte=0;byte<580;byte++)wire_probe_rx[byte]=hal_exchange(wire_probe_tx[byte]);
  int bad=hal_io_failed();if(hal_select(BUS_NONE))return -1;bad|=hal_io_failed();if(bad)return -1;
  int good=!memcmp(wire_probe_rx,"S7ST",4)&&wire_probe_rx[4]==S11_RECORD_VERSION&&
   s9_get32(wire_probe_rx+60)==s9_crc32(wire_probe_rx,60)&&s9_get32(wire_probe_rx+576)==s9_crc32(wire_probe_rx,576);
  ready_wait_us=(uint32_t)(hal_time_us()-began);
  if(good)return 0;
  hal_startup_pause();
 }while(hal_time_us()-began<10000000u);
 ready_wait_us=(uint32_t)(hal_time_us()-began);return -1;
}
int wire_probe_run(void){
 s10_dma_binding binding={0,now,owner,select_bus,ram};
 RECORD_DMA_PREPARE(tx_backing);RECORD_DMA_PREPARE(rx_backing);
 if(hal_media_dma_bind(&probe,&binding)){failure=-101;goto done;}
 query();ready_result=wait_fpga_ready();if(ready_result){failure=-108;goto done;}
 for(uint64_t token=1;token<=32;token++){
  int rc=s10_spi_dma_begin(&probe,token,BUS_FPGA,20000000u,wire_probe_tx,sizeof wire_probe_tx,wire_probe_rx,sizeof wire_probe_rx,580,10000);
  if(rc!=S10_DMA_PENDING){failure=-200+rc;goto done;}
  uint64_t start=hal_time_us();
  while(!s10_spi_dma_is_retired(&probe,token)){
   rc=s10_spi_dma_poll(&probe,token);
   if(hal_time_us()-start>20000){failure=-104;goto done;}
   hal_delay_us(1);
  }
  if(rc!=S10_DMA_DONE||s10_spi_dma_release(&probe,token)){failure=-105;goto done;}
  good_count+=response_good();hal_delay_us(10);
 }
 if(good_count!=32||hal_bus_owner()!=BUS_NONE)failure=-107;
 hal_frequency(FPGA_SPI_HZ);
done:if(!failure)s11_service_wire_qualified(S11_RECORD_VERSION);
 __atomic_store_n(&ready,1,__ATOMIC_RELEASE);return failure;
}
void wire_probe_report(void){
 if(!__atomic_load_n(&ready,__ATOMIC_ACQUIRE))return;
 printf("READY128 attempts=%u wait_us=%lu result=%d\r\n",ready_probe_attempts,(unsigned long)ready_wait_us,ready_result);
 printf("SWEEP128R failure=%d good=%u count=32\r\n",failure,good_count);
 printf("DMA_STATUS err=%08lx raw=%08lx tx=%08lx rx=%08lx\r\n",(unsigned long)getreg32(0x2000c000u+DMA_INTERRORSTATUS_OFFSET),(unsigned long)getreg32(0x2000c000u+DMA_RAWINTERRORSTATUS_OFFSET),(unsigned long)getreg32(0x2000c110u),(unsigned long)getreg32(0x2000c210u));
}
