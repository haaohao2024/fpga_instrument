#include "bus_fault.h"
#include "record_trace.h"
#include "record_hot.h"
#include "record_profile.h"
#include "s10_spi_dma.h"
#include "score_hal.h"
#include "bflb_spi.h"
#include "shared_spi_rate.h"
#include "bflb_l1c.h"
#include "hardware/dma_reg.h"
#include <string.h>
#include "fixed_spi_io.h"

RECORD_HOT static int hardware_active(struct bflb_device_s *channel)
{
    /* SDK isbusy checks only E. The A bit also fences an in-flight DMA bus
     * access after disable and is required before reclaiming memory. */
    return (getreg32(channel->reg_base + DMA_CxCONFIG_OFFSET) & (DMA_E | DMA_A)) != 0;
}

RECORD_HOT static void tx_terminal(void *arg)
{
    s10_spi_dma *s=(s10_spi_dma *)arg;
    if (__atomic_load_n(&s->state,__ATOMIC_ACQUIRE)==S10_DMA_RUNNING) {
        s->tx_completed_us=(uint32_t)(s->binding.time_us(s->binding.user)-s->started_us);
        __atomic_store_n(&s->tx_terminal,1u,__ATOMIC_RELEASE);order_trace_irq(0);
        if (s->wakeup) s->wakeup(s->wakeup_user);
    }
}
RECORD_HOT static void rx_terminal(void *arg)
{
    s10_spi_dma *s=(s10_spi_dma *)arg;
    if (__atomic_load_n(&s->state,__ATOMIC_ACQUIRE)==S10_DMA_RUNNING) {
        s->rx_completed_us=(uint32_t)(s->binding.time_us(s->binding.user)-s->started_us);
        __atomic_store_n(&s->rx_terminal,1u,__ATOMIC_RELEASE);order_trace_irq(1);
        if (s->wakeup) s->wakeup(s->wakeup_user);
    }
}
RECORD_HOT static void fence(void) { __atomic_thread_fence(__ATOMIC_SEQ_CST); }

int s10_spi_dma_set_wakeup(s10_spi_dma *s,void (*callback)(void *),void *user)
{
    if (!s || !s->initialized) return S10_DMA_ARGUMENT;
    if (s->state!=S10_DMA_IDLE) return S10_DMA_BUSY;
    s->wakeup=callback; s->wakeup_user=user;
    return S10_DMA_PENDING;
}

int s10_spi_dma_bind(s10_spi_dma *s, struct bflb_device_s *spi,
                    struct bflb_device_s *tx, struct bflb_device_s *rx,
                    const s10_dma_binding *binding)
{
    struct bflb_dma_channel_config_s t={0},r={0};
    if (!s || !spi || !tx || !rx || spi->idx!=0 || tx->idx!=0 || rx->idx!=0 || tx==rx || !binding ||
        !binding->time_us || !binding->owner || !binding->select || !binding->dma_ram ||
        ((uintptr_t)s & 31u)) return S10_DMA_ARGUMENT;
    if ((s->initialized && s->state!=S10_DMA_IDLE) ||
        hardware_active(tx) || hardware_active(rx) || fixed_spi_busy(spi) ||
        binding->owner(binding->user)!=0) return S10_DMA_BUSY;
    memset(s,0,sizeof(*s));
    s->spi=spi; s->tx_channel=tx; s->rx_channel=rx; s->binding=*binding;
    t.direction=DMA_MEMORY_TO_PERIPH; t.src_req=DMA_REQUEST_NONE; t.dst_req=DMA_REQUEST_SPI0_TX;
    t.src_addr_inc=DMA_ADDR_INCREMENT_ENABLE; t.dst_addr_inc=DMA_ADDR_INCREMENT_DISABLE;
    t.src_burst_count=t.dst_burst_count=DMA_BURST_INCR1;
    t.src_width=t.dst_width=DMA_DATA_WIDTH_8BIT;
    r.direction=DMA_PERIPH_TO_MEMORY; r.src_req=DMA_REQUEST_SPI0_RX; r.dst_req=DMA_REQUEST_NONE;
    r.src_addr_inc=DMA_ADDR_INCREMENT_DISABLE; r.dst_addr_inc=DMA_ADDR_INCREMENT_ENABLE;
    r.src_burst_count=r.dst_burst_count=DMA_BURST_INCR1;
    r.src_width=r.dst_width=DMA_DATA_WIDTH_8BIT;
    bflb_dma_channel_init(tx,&t); bflb_dma_channel_init(rx,&r);
    bflb_dma_channel_irq_attach(tx,tx_terminal,s); bflb_dma_channel_irq_attach(rx,rx_terminal,s);
    struct bflb_spi_config_s initial={.freq=10000000u,.role=SPI_ROLE_MASTER,.mode=SPI_MODE0,
      .data_width=SPI_DATA_WIDTH_8BIT,.bit_order=SPI_BIT_MSB,.byte_order=SPI_BYTE_LSB};
    bflb_spi_init(spi,&initial);shared_spi_rate(spi,initial.freq);
    s->initialized=1u;
    return S10_DMA_PENDING;
}

RECORD_HOT static int memory_valid(s10_spi_dma *s,const void *tx,size_t tx_cap,
                         const void *rx,size_t rx_cap,size_t extent)
{
    uintptr_t a=(uintptr_t)tx,b=(uintptr_t)rx;
    if (!tx || !rx || (a & 31u) || (b & 31u) ||
        tx_cap<extent || rx_cap<extent || a>UINTPTR_MAX-extent || b>UINTPTR_MAX-extent)
        return 0;
    if (a<b+extent && b<a+extent) return 0;
    return s->binding.dma_ram(s->binding.user,tx,extent) &&
           s->binding.dma_ram(s->binding.user,rx,extent) &&
           s->binding.dma_ram(s->binding.user,s->tx_lli,sizeof(s->tx_lli)) &&
           s->binding.dma_ram(s->binding.user,s->rx_lli,sizeof(s->rx_lli));
}

RECORD_HOT static void dma_reload_single(struct bflb_device_s *dev,struct bflb_dma_channel_lli_pool_s *p,uint32_t src,uint32_t dst,unsigned n){
 p->src_addr=src;p->dst_addr=dst;p->nextlli=0;
 p->control.WORD=(getreg32(dev->reg_base+DMA_CxCONTROL_OFFSET)&~UINT32_C(0x80000fff))|n|UINT32_C(0x80000000);
 putreg32(p->src_addr,dev->reg_base+DMA_CxSRCADDR_OFFSET);
 putreg32(p->dst_addr,dev->reg_base+DMA_CxDSTADDR_OFFSET);
 putreg32(0,dev->reg_base+DMA_CxLLI_OFFSET);
 putreg32(p->control.WORD,dev->reg_base+DMA_CxCONTROL_OFFSET);
 /* CxLLI=0: hardware uses the four channel registers,not this software shadow. */
}
static void abort_transfer(s10_spi_dma *s,int reason);
RECORD_HOT static int begin_dma(s10_spi_dma *s,uint64_t token,int target,uint32_t frequency,
                     const void *tx,size_t tx_capacity,void *rx,size_t rx_capacity,
                     size_t bytes,uint32_t timeout_us)
{
    
    if(bus_fault_active())return S10_DMA_QUARANTINED;
    size_t extent=(bytes+31u) & ~(size_t)31u;
    int keep=frequency==0;
    if (!s || !s->initialized || (!keep&&(!token || token<=s->last_token)) ||
        target<1 || target>3 || !bytes || bytes>S10_DMA_MAX_BYTES || !timeout_us ||
        (!keep && frequency!=400000u && frequency!=2000000u && frequency!=4000000u && frequency!=5000000u && frequency!=8000000u && frequency!=10000000u && frequency!=20000000u)) return S10_DMA_ARGUMENT;
    if (s->state!=S10_DMA_IDLE || hardware_active(s->tx_channel) ||
        hardware_active(s->rx_channel) || fixed_spi_busy(s->spi)) return S10_DMA_BUSY;
    if (s->binding.owner(s->binding.user)!=(keep?target:0)) return S10_DMA_OWNER;
    if (!memory_valid(s,tx,tx_capacity,rx,rx_capacity,extent)) return S10_DMA_ARGUMENT;
    
    bus_fault_clear_abort();
    if(!keep){
    order_trace_take(OT_CFG_BEGIN,0);
    shared_spi_rate(s->spi,frequency);
    /* Only the FPGA DMA path uses extended LOW at 20MHz. SD20MHz keeps
     * its symmetric timing installed by hal_frequency/shared_spi_rate. */
    if(frequency==20000000u)fpga_spi_apply_waveform(s->spi,frequency);
    order_trace_take(OT_CFG_DONE,0);
    }
    /* SD PIO just retired its token. Its FIFOs are already drained; do not
     * rewrite SPI_CONFIG or touch the selected transaction's framing. */
    if(!keep)fixed_spi_prepare(s->spi);
    fixed_dma_clear(s->tx_channel); fixed_dma_clear(s->rx_channel);
    
    dma_reload_single(s->tx_channel,s->tx_lli,(uint32_t)(uintptr_t)tx,DMA_ADDR_SPI0_TDR,(unsigned)bytes);
    dma_reload_single(s->rx_channel,s->rx_lli,DMA_ADDR_SPI0_RDR,(uint32_t)(uintptr_t)rx,(unsigned)bytes);
    bflb_l1c_dcache_clean_range((void *)tx,(uint32_t)extent);
    bflb_l1c_dcache_clean_invalidate_range(rx,(uint32_t)extent);
    fence();
    
    s->tx=tx; s->rx=rx; s->bytes=bytes; s->cache_extent=extent;
    s->token=token; if(!keep)s->last_token=token; s->keep_selected=(uint8_t)keep; s->target=target; s->timeout_us=timeout_us;
    s->abort_started_us=0;s->tx_terminal=s->rx_terminal=0u;s->tx_completed_us=s->rx_completed_us=0u; s->result=S10_DMA_PENDING;
    if ((!keep&&s->binding.select(s->binding.user,target)) || s->binding.owner(s->binding.user)!=target) {
        /* Even a failed select can leave a chip selected. Keep ownership
         * until poll has confirmed every CS high; an error is not a fence. */
        s->started_us=s->binding.time_us(s->binding.user);
        abort_transfer(s,S10_DMA_OWNER);++s->owner_faults;
        return S10_DMA_OWNER;
    }
    s->started_us=s->binding.time_us(s->binding.user);
    
    __atomic_store_n(&s->state,S10_DMA_RUNNING,__ATOMIC_RELEASE);order_trace_arm((uint32_t)token);
    fixed_spi_dma_link(s->spi,1);
    /* RX is armed first, before TX can emit the first clock. */
    fixed_dma_start(s->rx_channel); fixed_dma_start(s->tx_channel);
    
    return S10_DMA_PENDING;
}

int s10_spi_dma_begin(s10_spi_dma *s,uint64_t token,int target,uint32_t frequency,
 const void *tx,size_t tx_capacity,void *rx,size_t rx_capacity,size_t bytes,uint32_t timeout_us){
 if(!frequency)return S10_DMA_ARGUMENT;
 return begin_dma(s,token,target,frequency,tx,tx_capacity,rx,rx_capacity,bytes,timeout_us);
}
int s10_spi_dma_begin_selected(s10_spi_dma *s,const void *tx,void *rx,size_t bytes,uint32_t timeout_us){
 if(bytes!=512)return S10_DMA_ARGUMENT;
 return begin_dma(s,0,BUS_SD,0,tx,512,rx,512,bytes,timeout_us);
}
static void abort_transfer(s10_spi_dma *s,int reason)
{
    if(s->state==S10_DMA_ABORTING)return;
    bus_fault_note_abort((unsigned)reason,s->keep_selected?1:2,s->started_us,s->token,s->state);
    s->abort_started_us=s->binding.time_us(s->binding.user);s->state=S10_DMA_ABORTING; s->result=reason;
    if(bus_fault_active())return;
    bflb_dma_channel_stop(s->tx_channel); bflb_dma_channel_stop(s->rx_channel);
    fixed_spi_dma_link(s->spi,0);
    fence();
}

RECORD_HOT static int quiescent(s10_spi_dma *s)
{
    return !hardware_active(s->tx_channel) && !hardware_active(s->rx_channel) &&
           !fixed_spi_busy(s->spi);
}

RECORD_HOT int s10_spi_dma_poll(s10_spi_dma *s,uint64_t token)
{
    if (!s || (!token&&!s->keep_selected) || token!=s->token || s->state==S10_DMA_IDLE) return S10_DMA_ARGUMENT;
    if (s->state==S10_DMA_RETIRED) return s->result;
    if(bus_fault_active())return s->result;
    if(s->state==S10_DMA_ABORTING&&s->binding.time_us(s->binding.user)-s->abort_started_us>=BUS_FAULT_ABORT_DRAIN_US&&
       (!quiescent(s)||s->binding.owner(s->binding.user)!=(s->keep_selected?s->target:0))){
        bus_fault_capture(BUS_FAULT_DMA_DRAIN,s->keep_selected?1:2,s->started_us,s->abort_started_us+BUS_FAULT_ABORT_DRAIN_US,s->token,s->state);
        return s->result;
    }
    unsigned tx_done=__atomic_load_n(&s->tx_terminal,__ATOMIC_ACQUIRE);
    unsigned rx_done=__atomic_load_n(&s->rx_terminal,__ATOMIC_ACQUIRE);
    if (s->state==S10_DMA_RUNNING) {
        if (s->binding.owner(s->binding.user)!=s->target) {
            ++s->owner_faults; abort_transfer(s,S10_DMA_OWNER);
        } else if (fixed_spi_fifo_error(s->spi)) {
            abort_transfer(s,S10_DMA_FIFO);
        } else if (s->binding.time_us(s->binding.user)-s->started_us>=s->timeout_us) {
            /* An IRQ can arrive while reading the timer. Re-acquire flags
             * after that read before classifying a deadline expiration. */
            tx_done=__atomic_load_n(&s->tx_terminal,__ATOMIC_ACQUIRE);
            rx_done=__atomic_load_n(&s->rx_terminal,__ATOMIC_ACQUIRE);
            if (!(tx_done && rx_done && s->tx_completed_us<s->timeout_us &&
                  s->rx_completed_us<s->timeout_us && quiescent(s))) {
                /* SD's total selected/lease deadline remains independent. */
                ++s->timed_out; abort_transfer(s,S10_DMA_TIMEOUT);
            }
        }
    }
    if (s->state==S10_DMA_RUNNING && (!tx_done || !rx_done)) return S10_DMA_PENDING;
    if (!quiescent(s)) return s->result;
    /* Only the failed/aborted path needs this check. Disabled RX DMA cannot
     * consume a residual byte; reusing it for a later PIO response is unsafe. */
    if(s->state==S10_DMA_ABORTING&&(getreg32(s->spi->reg_base+SPI_FIFO_CONFIG_1_OFFSET)&SPI_RX_FIFO_CNT_MASK)){
        bus_fault_capture(BUS_FAULT_DMA_RX_RESIDUE,s->keep_selected?3:4,s->started_us,0,s->token,s->state);
        return s->result;
    }
    order_trace_take(OT_IDLE,0);
    /* Both DMA bus accesses and the actual SPI tail/FIFO are finished. */
    fence();
    fixed_spi_dma_link(s->spi,0);
    if ((!s->keep_selected&&s->binding.select(s->binding.user,0)) || s->binding.owner(s->binding.user)!=(s->keep_selected?s->target:0)) {
        if (s->result==S10_DMA_PENDING) { ++s->owner_faults; s->result=S10_DMA_OWNER; }
        abort_transfer(s,S10_DMA_OWNER);
        return s->result;
    }
    bflb_l1c_dcache_invalidate_range(s->rx,(uint32_t)s->cache_extent);
    fence();
    fixed_dma_clear(s->tx_channel); fixed_dma_clear(s->rx_channel);
    if (s->result==S10_DMA_PENDING) { s->result=S10_DMA_DONE; ++s->completed; }
    s->state=S10_DMA_RETIRED;order_trace_take(OT_DMA_DONE,(unsigned)s->result);
    return s->result;
}

int s10_spi_dma_cancel(s10_spi_dma *s,uint64_t token)
{
    if (!s || token!=s->token || s->state==S10_DMA_IDLE) return S10_DMA_ARGUMENT;
    if (s->state==S10_DMA_RUNNING) { ++s->cancelled; abort_transfer(s,S10_DMA_CANCELLED); }
    return s10_spi_dma_poll(s,token);
}

RECORD_HOT int s10_spi_dma_is_retired(const s10_spi_dma *s,uint64_t token)
{
    return s && (token||s->keep_selected) && s->token==token && s->state==S10_DMA_RETIRED;
}

RECORD_HOT int s10_spi_dma_release(s10_spi_dma *s,uint64_t token)
{
    if (!s || token!=s->token) return S10_DMA_ARGUMENT;
    if (!s10_spi_dma_is_retired(s,token)) { ++s->early_release_rejected; return S10_DMA_BUSY; }
    s->tx=NULL; s->rx=NULL; s->token=0u; s->keep_selected=0; s->state=S10_DMA_IDLE;
    bus_fault_clear_abort();
    return S10_DMA_PENDING;
}
