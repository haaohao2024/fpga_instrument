#include "record_trace.h"
#include "record_hot.h"
#include "hardware/spi_reg.h"
#include "hardware/dma_reg.h"
#include "hardware/gpio_reg.h"
enum {OT_PAD_INPUT=GLB_REG_GPIO_0_I};
#include "bflb_core.h"
#include "FreeRTOS.h"
#include "task.h"
#include <stdio.h>
#if defined(__riscv)
volatile order_trace_row order_trace_rows[96] __attribute__((section(".wifi_ram.record_trace"),aligned(32)));
static inline uint32_t cycles(void){uint32_t n;__asm__ volatile("rdcycle %0":"=r"(n));return n;}
#else
volatile order_trace_row order_trace_rows[96];
extern uint32_t order_trace_host_cycles(void);
static inline uint32_t cycles(void){return order_trace_host_cycles();}
#endif
_Static_assert(sizeof order_trace_rows==2304,"Reuse fixed2304B trace region");
volatile uint32_t order_trace_mode,order_trace_count,order_trace_frozen,order_trace_reason;
static uint32_t spi_base,tx_base,rx_base,gpio_base,current_id,current_owner,write_index,irq_id,irq_flushed;
static volatile uint32_t irq_cycle[2],irq_valid[2];
static uint32_t capture_peak,capture_gap,capture_last,capture_received;
void record_capture_metric(uint32_t received,uint32_t buffered){
 if(buffered>capture_peak)capture_peak=buffered;
 if(received!=capture_received){uint32_t c=cycles(),gap=c-capture_last;if(capture_received&&gap>capture_gap)capture_gap=gap;capture_last=c;capture_received=received;}
}
static struct {uint64_t us;uint32_t calls,max_us;} phase[RP_COUNT];
static uint64_t card_since,card_overlap;
static unsigned card_pending;
void record_phase_add(unsigned k,uint32_t us){phase[k].us+=us;phase[k].calls++;if(us>phase[k].max_us)phase[k].max_us=us;}
void record_phase_card_begin(uint64_t now){card_since=now;card_pending=1;}
void record_phase_card_end(uint64_t now){record_phase_add(RP_STOP_WINDOW,(uint32_t)(now-card_since));card_pending=0;}
void record_phase_fpga(uint64_t begin,uint64_t end){
 record_phase_add(RP_FPGA,(uint32_t)(end-begin));
 if(card_pending&&end>card_since){if(begin<card_since)begin=card_since;card_overlap+=end-begin;}
}
static void push(uint32_t stamp,unsigned event,unsigned detail,uint32_t a,uint32_t b,uint32_t id,unsigned pads){
 uint32_t n=order_trace_count;
 order_trace_rows[write_index]=(order_trace_row){stamp,n,id,event|(current_owner<<8)|(pads<<10)|(detail<<16),a,b};
 if(++write_index==96)write_index=0;
 order_trace_count=n+1;
}
static void flush_irq(void){
 for(unsigned i=0;i<2;i++)if(irq_valid[i]&&!(irq_flushed&(1u<<i))){push(irq_cycle[i],i?OT_RX_IRQ:OT_TX_IRQ,0,0,0,irq_id,0);irq_flushed|=1u<<i;}
}
void order_trace_bind(uint32_t s,uint32_t t,uint32_t r,uint32_t g){spi_base=s;tx_base=t;rx_base=r;gpio_base=g;}
void record_trace_reset(void){order_trace_count=order_trace_frozen=order_trace_reason=write_index=irq_flushed=0;irq_valid[0]=irq_valid[1]=0;current_owner=0;capture_peak=capture_gap=capture_last=capture_received=0;for(unsigned i=0;i<RP_COUNT;i++)phase[i].us=phase[i].calls=phase[i].max_us=0;card_pending=0;card_overlap=0;}
void order_trace_config(unsigned mode){order_trace_mode=0;record_trace_reset();order_trace_mode=mode;}
RECORD_HOT void order_trace_take(unsigned event,unsigned detail){
 if(!order_trace_mode||order_trace_frozen)return;
 flush_irq();uint32_t stamp=cycles(),a=UINT32_MAX,b=UINT32_MAX,pads=0;
 if(order_trace_mode==2){
  if(event==OT_CFG_BEGIN||event==OT_CFG_DONE){a=getreg32(spi_base+SPI_CONFIG_OFFSET);b=getreg32(spi_base+SPI_PRD_0_OFFSET);}
  else{
   a=getreg32(spi_base+SPI_FIFO_CONFIG_1_OFFSET)|((getreg32(spi_base+SPI_BUS_BUSY_OFFSET)&1u)<<31);
   uint32_t tx=getreg32(tx_base+DMA_CxCONFIG_OFFSET),rx=getreg32(rx_base+DMA_CxCONFIG_OFFSET);
   b=(tx&DMA_E?1u:0u)|(tx&DMA_A?2u:0u)|(rx&DMA_E?4u:0u)|(rx&DMA_A?8u:0u)|((getreg32(spi_base+SPI_FIFO_CONFIG_0_OFFSET)&255u)<<8);
  }
  for(unsigned i=0;i<3;i++)if(getreg32(gpio_base+GLB_GPIO_CFG0_OFFSET+((10u+i)<<2))&OT_PAD_INPUT)pads|=1u<<i;
 }
 push(stamp,event,detail,a,b,current_id,pads);
}
RECORD_HOT void order_trace_select(unsigned event,unsigned previous,unsigned target){
 if(!order_trace_mode||order_trace_frozen)return;
 current_owner=event==OT_SWITCH?previous:event==OT_HIGH?0:target;
 if(event==OT_LOW)current_id++;
 order_trace_take(event,target);
}
RECORD_HOT void order_trace_data(unsigned event,uint32_t a,uint32_t b){
 if(!order_trace_mode||order_trace_frozen)return;
 flush_irq();push(cycles(),event,0,a,b,current_id,0);
}
RECORD_HOT void order_trace_arm(uint32_t token){
 if(!order_trace_mode||order_trace_frozen)return;
 order_trace_data(OT_DMA_ARM,token,0);irq_valid[0]=irq_valid[1]=0;irq_flushed=0;irq_id=current_id;
}
void order_trace_irq(unsigned rx){if(order_trace_mode&&!order_trace_frozen){irq_cycle[rx]=cycles();irq_valid[rx]=1;}}
RECORD_HOT void order_trace_freeze(unsigned reason){
 if(!order_trace_mode||order_trace_frozen)return;
 order_trace_take(OT_FREEZE,reason);order_trace_reason=reason;order_trace_frozen=1;
}
void order_trace_dump(void){
 if(order_trace_mode&&!order_trace_frozen)order_trace_frozen=2;
 printf("REC_FLOW pcm_peak=%lu gap_cycles=%lu\r\n",(unsigned long)capture_peak,(unsigned long)capture_gap);
 uint32_t n=order_trace_count,used=n<96?n:96,start=n<96?0:write_index;
 printf("ORDER_BEGIN v=1 mode=%lu frozen=%lu reason=%lu count=%lu used=%lu\r\n",(unsigned long)order_trace_mode,(unsigned long)order_trace_frozen,(unsigned long)order_trace_reason,(unsigned long)n,(unsigned long)used);
 for(uint32_t i=0;i<used;i++){
  const volatile order_trace_row *p=&order_trace_rows[(start+i)%96];
  printf("O %08lx %lu %lu %08lx %08lx %08lx\r\n",(unsigned long)p->cycle,(unsigned long)p->sequence,(unsigned long)p->transaction,(unsigned long)p->event_flags,(unsigned long)p->spi,(unsigned long)p->dma);
  if((i&3u)==3u)vTaskDelay(pdMS_TO_TICKS(5));
 }
 printf("ORDER_END\r\n");
 for(unsigned k=0;k<RP_COUNT;k++)printf("RP32 %u %lu %lu %lu %lu\r\n",k,(unsigned long)phase[k].calls,(unsigned long)(phase[k].us>>32),(unsigned long)phase[k].us,(unsigned long)phase[k].max_us);
 printf("RP32_OVERLAP %lu %lu\r\n",(unsigned long)(card_overlap>>32),(unsigned long)card_overlap);
}
