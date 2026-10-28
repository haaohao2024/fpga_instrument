/* Diagnostic-only read-only S11 query sweep. No START/STOP/ACK, SD access,
 * recorder-service mutation or CRC repair. Dedicated bus task runs this
 * before the production DMA object is bound; all jobs must retire first. */
#include "wire_probe.h"
#include "s10_spi_dma.h"
#include "score_hal.h"
#include "s9_protocol.h"
#include "bflb_clock.h"
#include "bflb_spi.h"
#include "hardware/spi_reg.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static s10_spi_dma probe;
static uint8_t tx[608] __attribute__((aligned(32)));
static uint8_t rx[608] __attribute__((aligned(32)));
typedef struct {uint32_t hz,pio,attempted,good,magic_bad,header_bad,packet_bad,elapsed_us,clock_hz,prd0,config,first_magic;} result;
static result results[6];
static unsigned ready;
static int failure;
static int in_range(const void *base,size_t cap,const void *p,size_t n){uintptr_t a=(uintptr_t)base,b=(uintptr_t)p;return b>=a&&b-a<=cap&&n<=cap-(b-a);}
static int ram(void *u,const void *p,size_t n){(void)u;return in_range(tx,sizeof tx,p,n)||in_range(rx,sizeof rx,p,n)||in_range(probe.tx_lli,sizeof probe.tx_lli,p,n)||in_range(probe.rx_lli,sizeof probe.rx_lli,p,n);}
static uint64_t now(void *u){(void)u;return hal_time_us();}
static int owner(void *u){(void)u;return hal_bus_owner();}
static int select_bus(void *u,int target){(void)u;return hal_select(target);}
static void query(void){memset(tx,0,sizeof tx);memcpy(tx,"S11P",4);tx[4]=1;s9_put16(tx+52,512);s9_put32(tx+60,s9_crc32(tx,60));s9_put32(tx+576,s9_crc32(tx,576));}
static void inspect(result *r){
 unsigned m=memcmp(rx,"S7ST",4)!=0||rx[4]!=1;
 unsigned h=s9_get32(rx+60)!=s9_crc32(rx,60),p=s9_get32(rx+576)!=s9_crc32(rx,576);
 if((m||h||p)&&!r->magic_bad&&!r->header_bad&&!r->packet_bad)r->first_magic=s9_get32(rx);
 r->magic_bad+=m;r->header_bad+=h;r->packet_bad+=p;r->good+=!m&&!h&&!p;
}
int wire_probe_run(void){
 const uint32_t rates[6]={10000000,8000000,5000000,2000000,10000000,10000000};
 s10_dma_binding binding={0,now,owner,select_bus,ram};
 struct bflb_device_s *spi=bflb_device_get_by_name("spi0");
 if(!spi){failure=-100;goto finished;}
 if(hal_media_dma_bind(&probe,&binding)){failure=-101;goto finished;}
 query();uint64_t token=0;
 for(unsigned phase=0;phase<6;phase++){
  result *r=&results[phase];r->hz=rates[phase];r->pio=phase==5;
  unsigned count=phase==3||phase==5?64:128;
  uint64_t began=hal_time_us();
  for(unsigned i=0;i<count;i++){
   memset(rx,0,sizeof rx);r->attempted++;
   if(r->pio){
    hal_frequency(r->hz);if(hal_select(BUS_FPGA)){failure=-102;goto finished;}
    for(unsigned byte=0;byte<580;byte++)rx[byte]=hal_exchange(tx[byte]);
    if(hal_select(BUS_NONE)){failure=-103;goto finished;}
   }else{
    ++token;int rc=s10_spi_dma_begin(&probe,token,BUS_FPGA,r->hz,tx,sizeof tx,rx,sizeof rx,580,10000);
    if(rc!=S10_DMA_PENDING){failure=-200+rc;goto finished;}
    uint64_t start=hal_time_us();
    while(!s10_spi_dma_is_retired(&probe,token)){
     rc=s10_spi_dma_poll(&probe,token);
     if(hal_time_us()-start>20000){failure=-104;goto finished;}
     hal_delay_us(1);
    }
    if(rc!=S10_DMA_DONE){failure=-300+rc;goto finished;}
    if(s10_spi_dma_release(&probe,token)){failure=-105;goto finished;}
   }
   if(!i){r->clock_hz=bflb_clk_get_peripheral_clock(BFLB_DEVICE_TYPE_SPI,spi->idx);r->prd0=getreg32(spi->reg_base+SPI_PRD_0_OFFSET);r->config=getreg32(spi->reg_base+SPI_CONFIG_OFFSET);}
   inspect(r);hal_delay_us(10);
  }
  r->elapsed_us=(uint32_t)(hal_time_us()-began);
 }
 /* Complete retirement and owner checks precede the normal binding, which
  * installs the production IRQ contexts and restarts its token namespace. */
 if(probe.state!=S10_DMA_IDLE||hal_bus_owner()!=BUS_NONE){failure=-106;goto finished;}
 hal_frequency(FPGA_SPI_HZ);
finished:
 __atomic_store_n(&ready,1,__ATOMIC_RELEASE);return failure;
}
void wire_probe_report(void){
 if(!__atomic_load_n(&ready,__ATOMIC_ACQUIRE))return;
 printf("SWEEP128 done failure=%d normal_hz=%lu\r\n",failure,(unsigned long)FPGA_SPI_HZ);
 for(unsigned i=0;i<6;i++){
  const result *r=&results[i];
  printf("SWEEP128 phase=%u hz=%lu pio=%lu count=%lu good=%lu magic=%lu header=%lu packet=%lu us=%lu clk=%lu prd=%08lx cfg=%08lx first=%08lx\r\n",i,(unsigned long)r->hz,(unsigned long)r->pio,(unsigned long)r->attempted,(unsigned long)r->good,(unsigned long)r->magic_bad,(unsigned long)r->header_bad,(unsigned long)r->packet_bad,(unsigned long)r->elapsed_us,(unsigned long)r->clock_hz,(unsigned long)r->prd0,(unsigned long)r->config,(unsigned long)r->first_magic);
 }
}
