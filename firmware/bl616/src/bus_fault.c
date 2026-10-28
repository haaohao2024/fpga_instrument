#include "bus_fault.h"
#include "score_hal.h"
#include "sd_spi.h"
#include "s11_service.h"
#include "bflb_core.h"
#include "hardware/spi_reg.h"
#include "hardware/dma_reg.h"
#include "hardware/gpio_reg.h"
#include <stdio.h>
static uint32_t spi_base,tx_base,rx_base,gpio_base;
static unsigned latched,reported;
static bus_fault_snapshot first;
static bus_fault_snapshot pre_abort;
static unsigned pre_valid;
void bus_fault_bind(uint32_t spi,uint32_t tx,uint32_t rx,uint32_t gpio){
 if(bus_fault_active())return;
 spi_base=spi;tx_base=tx;rx_base=rx;gpio_base=gpio;
}
int bus_fault_active(void){return __atomic_load_n(&latched,__ATOMIC_ACQUIRE)!=0;}
static void registers(bus_fault_snapshot *p){
 p->spi_busy=getreg32(spi_base+SPI_BUS_BUSY_OFFSET);p->fifo0=getreg32(spi_base+SPI_FIFO_CONFIG_0_OFFSET);p->fifo1=getreg32(spi_base+SPI_FIFO_CONFIG_1_OFFSET);
 p->config=getreg32(spi_base+SPI_CONFIG_OFFSET);p->prd0=getreg32(spi_base+SPI_PRD_0_OFFSET);p->prd1=getreg32(spi_base+SPI_PRD_1_OFFSET);
 p->tx=getreg32(tx_base+DMA_CxCONFIG_OFFSET);p->rx=getreg32(rx_base+DMA_CxCONFIG_OFFSET);
 p->raw_error=getreg32(0x2000c000u+DMA_RAWINTERRORSTATUS_OFFSET);p->error=getreg32(0x2000c000u+DMA_INTERRORSTATUS_OFFSET);
 for(unsigned i=0;i<3;i++)if(getreg32(gpio_base+GLB_GPIO_CFG0_OFFSET+((10u+i)<<2))&GLB_REG_GPIO_0_I)p->cs_pads|=1u<<i;
 p->owner=(uint32_t)hal_bus_owner();sd_fault_context(&p->sd_command,&p->sd_phase,&p->sd_index);
}
void bus_fault_clear_abort(void){if(!bus_fault_active())__atomic_store_n(&pre_valid,0,__ATOMIC_RELEASE);}
void bus_fault_note_abort(unsigned reason,unsigned phase,uint64_t started,uint64_t token,unsigned state){
 if(bus_fault_active()||__atomic_load_n(&pre_valid,__ATOMIC_ACQUIRE))return;
 pre_abort=(bus_fault_snapshot){0};pre_abort.now=hal_time_us();pre_abort.reason=reason;pre_abort.phase=phase;pre_abort.started=started;pre_abort.token=token;pre_abort.dma_state=state;
 registers(&pre_abort);__atomic_store_n(&pre_valid,1,__ATOMIC_RELEASE);
}
const bus_fault_snapshot *bus_fault_pre_abort(void){return bus_fault_get()&&(first.reason==BUS_FAULT_DMA_DRAIN||first.reason==BUS_FAULT_DMA_RX_RESIDUE)&&__atomic_load_n(&pre_valid,__ATOMIC_ACQUIRE)?&pre_abort:0;}
void bus_fault_capture(unsigned reason,unsigned phase,uint64_t started,uint64_t deadline,uint64_t token,unsigned state){
 unsigned expected=0;
 if(!__atomic_compare_exchange_n(&latched,&expected,1,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE))return;
 first.now=hal_time_us();first.reason=reason;first.phase=phase;first.started=started;first.deadline=deadline;first.token=token;first.dma_state=state;
 registers(&first);
 __atomic_store_n(&latched,2,__ATOMIC_RELEASE);
}
const bus_fault_snapshot *bus_fault_get(void){return __atomic_load_n(&latched,__ATOMIC_ACQUIRE)==2?&first:0;}
void bus_fault_report(void){
 const bus_fault_snapshot *p=bus_fault_get();if(!p){puts("BUS_FAULT active=0");return;}
 printf("BUS_FAULT active=1 reason=%lu phase=%lu state=%lu owner=%ld pads=%lx sd_cmd=%lu sd_phase=%lu sd_index=%lu\r\n",(unsigned long)p->reason,(unsigned long)p->phase,(unsigned long)p->dma_state,(long)(int32_t)p->owner,(unsigned long)p->cs_pads,(unsigned long)p->sd_command,(unsigned long)p->sd_phase,(unsigned long)p->sd_index);
 printf("BUS_FAULT_TIME now=%lu:%lu start=%lu:%lu deadline=%lu:%lu token=%lu:%lu\r\n",(unsigned long)(p->now>>32),(unsigned long)p->now,(unsigned long)(p->started>>32),(unsigned long)p->started,(unsigned long)(p->deadline>>32),(unsigned long)p->deadline,(unsigned long)(p->token>>32),(unsigned long)p->token);
 printf("BUS_FAULT_REG busy=%08lx fifo0=%08lx fifo1=%08lx tx=%08lx rx=%08lx rawerr=%08lx err=%08lx config=%08lx prd0=%08lx prd1=%08lx\r\n",(unsigned long)p->spi_busy,(unsigned long)p->fifo0,(unsigned long)p->fifo1,(unsigned long)p->tx,(unsigned long)p->rx,(unsigned long)p->raw_error,(unsigned long)p->error,(unsigned long)p->config,(unsigned long)p->prd0,(unsigned long)p->prd1);
 const bus_fault_snapshot *pre=bus_fault_pre_abort();
 if(pre)printf("BUS_FAULT_PRE valid=1 reason=%ld phase=%lu state=%lu time=%lu:%lu token=%lu:%lu busy=%08lx fifo0=%08lx fifo1=%08lx tx=%08lx rx=%08lx rawerr=%08lx err=%08lx\r\n",(long)(int32_t)pre->reason,(unsigned long)pre->phase,(unsigned long)pre->dma_state,(unsigned long)(pre->now>>32),(unsigned long)pre->now,(unsigned long)(pre->token>>32),(unsigned long)pre->token,(unsigned long)pre->spi_busy,(unsigned long)pre->fifo0,(unsigned long)pre->fifo1,(unsigned long)pre->tx,(unsigned long)pre->rx,(unsigned long)pre->raw_error,(unsigned long)pre->error);
 else puts("BUS_FAULT_PRE valid=0");
 if(pre)printf("BUS_FAULT_PRE_CFG config=%08lx prd0=%08lx prd1=%08lx\r\n",(unsigned long)pre->config,(unsigned long)pre->prd0,(unsigned long)pre->prd1);
 const s11_service_stats *rec=s11_service_statistics();
 printf("BUS_FAULT_REC active=%u error=%u wire=%u cmd=%u ack=%u remote_stop_unconfirmed=%u\r\n",rec->active,rec->error,rec->wire_state,rec->command,rec->ack_pending,rec->remote_stop_unconfirmed);
}
void bus_fault_pump(void){if(bus_fault_get()&&!reported){reported=1;bus_fault_report();}}
