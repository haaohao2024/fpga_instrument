#include "bounded_spi_io.h"
#include "bflb_spi.h"
#include "bus_fault.h"
#include "score_hal.h"
#include "record_hot.h"
#include "hardware/spi_reg.h"
#define BOUNDED_START_SLACK_US 1000u
static int deadline(unsigned reason,unsigned phase,uint64_t start,uint64_t limit){
 if(bus_fault_active())return 1;
 if(hal_time_us()>=limit){bus_fault_capture(reason,phase,start,limit,0,0);return 1;}return 0;
}
static int idle_reason(struct bflb_device_s *s,uint64_t limit,unsigned reason,unsigned phase){
 uint64_t start=hal_time_us();
 if(bus_fault_active())return -1;
 /* A completed physical fence is safe even if task scheduling was late.
  * The caller's occupancy/transaction deadline still reports any overrun. */
 while(getreg32(s->reg_base+SPI_BUS_BUSY_OFFSET)||((getreg32(s->reg_base+SPI_FIFO_CONFIG_1_OFFSET)&SPI_TX_FIFO_CNT_MASK)>>SPI_TX_FIFO_CNT_SHIFT)<SPI_FIFO_BYTE_NUM_MAX)
  if(deadline(reason,phase,start,limit))return -1;
 return 0;
}
RECORD_HOT int bounded_spi_idle(struct bflb_device_s *s,uint64_t limit){return idle_reason(s,limit,BUS_FAULT_PIO_BLOCK,4);}
RECORD_HOT int bounded_spi_byte(struct bflb_device_s *s,uint8_t tx,uint64_t limit,uint8_t *rx){
 uint64_t start=hal_time_us(),drain=0;uint32_t b=s->reg_base;
 if(bus_fault_active())return -1;
 /* The caller computed limit before this call. Preemption in between (BLE
  * controller/USB run at priority 6) must not fail a byte that has not even
  * started; SD keeps its logical budget in sd_spi.c. Progress is bounded
  * from the actual start instead. */
 if(limit<start+BOUNDED_START_SLACK_US)limit=start+BOUNDED_START_SLACK_US;
 putreg32(tx,b+SPI_FIFO_WDATA_OFFSET);
 for(;;){
  if(bus_fault_active())return -1;
  /* The received byte proves all 8 clocks are done. No per-byte idle wait:
   * in continuous-frame mode BUS_BUSY lingers ~20us after each byte, which
   * made every command/poll byte cost 20us of CPU. CS, rate and DMA changes
   * keep their own full idle fence. A late (preempted) byte still counts. */
  if(getreg32(b+SPI_FIFO_CONFIG_1_OFFSET)&SPI_RX_FIFO_CNT_MASK){*rx=(uint8_t)getreg32(b+SPI_FIFO_RDATA_OFFSET);return 0;}
  uint64_t now=hal_time_us();
  if(now>=limit&&!drain)drain=now+1000u;
  if(drain&&now>=drain){bus_fault_capture(BUS_FAULT_PIO_BYTE,1,start,drain,0,0);return -1;}
 }
}
RECORD_HOT int bounded_spi_block(struct bflb_device_s *s,const uint8_t *tx,uint8_t *rx,unsigned n,uint64_t limit){
 uint64_t start=hal_time_us(),drain=0;uint32_t b=s->reg_base;unsigned sent=0,received=0;
 if(bus_fault_active())return -1;
 if(!n)return idle_reason(s,limit,BUS_FAULT_PIO_BLOCK,0);
 /* Same as for single bytes: bound progress from the actual start. */
 if(limit<start+BOUNDED_START_SLACK_US)limit=start+BOUNDED_START_SLACK_US;
 /* Once started, a block fails only on 1 ms without progress: preemption by
  * a higher-priority task must not fail bytes the FIFO already moved. The
  * caller's occupancy deadline still bounds the whole transaction. */
 uint64_t stall=limit;
 /* HAL always configures 8-bit frames. Never clear a live FIFO. */
 while(getreg32(b+SPI_BUS_BUSY_OFFSET)||((getreg32(b+SPI_FIFO_CONFIG_1_OFFSET)&SPI_TX_FIFO_CNT_MASK)>>SPI_TX_FIFO_CNT_SHIFT)<SPI_FIFO_BYTE_NUM_MAX)
  if(deadline(BUS_FAULT_PIO_BLOCK,1,start,limit))return -1;
 uint32_t f=getreg32(b+SPI_FIFO_CONFIG_0_OFFSET);putreg32(f|SPI_TX_FIFO_CLR|SPI_RX_FIFO_CLR,b+SPI_FIFO_CONFIG_0_OFFSET);
 unsigned free=(getreg32(b+SPI_FIFO_CONFIG_1_OFFSET)&SPI_TX_FIFO_CNT_MASK)>>SPI_TX_FIFO_CNT_SHIFT;
 if(free>n)free=n;
 for(unsigned i=0;i<free;i++){uint64_t now=hal_time_us();if(now>=limit){drain=now+1000u;break;}putreg32(tx?tx[sent]:255u,b+SPI_FIFO_WDATA_OFFSET);sent++;}
 if(!sent)return -1;
 while(received<n){
  if(bus_fault_active())return -1;
  unsigned count=(getreg32(b+SPI_FIFO_CONFIG_1_OFFSET)&SPI_RX_FIFO_CNT_MASK)>>SPI_RX_FIFO_CNT_SHIFT;
  if(!count){
   uint64_t now=hal_time_us();if(now>=stall&&!drain)drain=now+1000u;
   if(drain&&now>=drain){bus_fault_capture(BUS_FAULT_PIO_BLOCK,2,start,drain,0,0);return -1;}
  }else{uint64_t now=hal_time_us();if(stall<now+1000u)stall=now+1000u;}
  if(count>n-received)count=n-received;
  while(count--){
   uint8_t v=(uint8_t)getreg32(b+SPI_FIFO_RDATA_OFFSET);if(rx)rx[received]=v;received++;
   if(sent<n&&!drain){putreg32(tx?tx[sent]:255u,b+SPI_FIFO_WDATA_OFFSET);sent++;}
  }
  /* All queued bytes are back, but the budget expired before the remaining
   * bytes were queued. Retire the physical prefix and fail the transaction;
   * do not extend it or declare a healthy controller quarantined. */
  if(received==sent&&sent<n){(void)idle_reason(s,drain?drain:hal_time_us()+1000u,BUS_FAULT_PIO_BLOCK,3);return -1;}
 }
 int r=idle_reason(s,drain?drain:hal_time_us()+1000u,BUS_FAULT_PIO_BLOCK,3);
 return r||drain?-1:0;
}
