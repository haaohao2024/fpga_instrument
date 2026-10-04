#include "s10_spi_dma.h"
#include "bflb_spi.h"
#include "bflb_l1c.h"
#include "hardware/dma_reg.h"
#include <string.h>

static int hardware_active(struct bflb_device_s *channel)
{
    /* SDK isbusy checks only E. The A bit also fences an in-flight DMA bus
     * access after disable and is required before reclaiming memory. */
    return (getreg32(channel->reg_base + DMA_CxCONFIG_OFFSET) & (DMA_E | DMA_A)) != 0;
}

static void tx_terminal(void *arg)
{
    s10_spi_dma *s=(s10_spi_dma *)arg;
    if (s->state==S10_DMA_RUNNING) {
        s->tx_terminal=1u;
        if (s->wakeup) s->wakeup(s->wakeup_user);
    }
}
static void rx_terminal(void *arg)
{
    s10_spi_dma *s=(s10_spi_dma *)arg;
    if (s->state==S10_DMA_RUNNING) {
        s->rx_terminal=1u;
        if (s->wakeup) s->wakeup(s->wakeup_user);
    }
}
static void fence(void) { __atomic_thread_fence(__ATOMIC_SEQ_CST); }

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
    if (!s || !spi || !tx || !rx || tx==rx || !binding ||
        !binding->time_us || !binding->owner || !binding->select || !binding->dma_ram ||
        ((uintptr_t)s & 31u)) return S10_DMA_ARGUMENT;
    if ((s->initialized && s->state!=S10_DMA_IDLE) ||
        hardware_active(tx) || hardware_active(rx) || bflb_spi_isbusy(spi) ||
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
    s->initialized=1u;
    return S10_DMA_PENDING;
}

static int memory_valid(s10_spi_dma *s,const void *tx,size_t tx_cap,
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

int s10_spi_dma_begin(s10_spi_dma *s,uint64_t token,int target,uint32_t frequency,
                     const void *tx,size_t tx_capacity,void *rx,size_t rx_capacity,
                     size_t bytes,uint32_t timeout_us)
{
    struct bflb_spi_config_s config={0};
    struct bflb_dma_channel_lli_transfer_s t,r;
    size_t extent=(bytes+31u) & ~(size_t)31u;
    if (!s || !s->initialized || !token || token<=s->last_token ||
        target<1 || target>3 || !bytes || bytes>S10_DMA_MAX_BYTES || !timeout_us ||
        (frequency!=400000u && frequency!=2000000u && frequency!=4000000u && frequency!=5000000u && frequency!=8000000u)) return S10_DMA_ARGUMENT;
    if (s->state!=S10_DMA_IDLE || hardware_active(s->tx_channel) ||
        hardware_active(s->rx_channel) || bflb_spi_isbusy(s->spi)) return S10_DMA_BUSY;
    if (s->binding.owner(s->binding.user)!=0) return S10_DMA_OWNER;
    if (!memory_valid(s,tx,tx_capacity,rx,rx_capacity,extent)) return S10_DMA_ARGUMENT;
    config.freq=frequency; config.role=SPI_ROLE_MASTER; config.mode=SPI_MODE0;
    config.data_width=SPI_DATA_WIDTH_8BIT; config.bit_order=SPI_BIT_MSB;
    config.byte_order=SPI_BYTE_LSB; config.tx_fifo_threshold=config.rx_fifo_threshold=0u;
    bflb_spi_init(s->spi,&config);
    bflb_spi_feature_control(s->spi,SPI_CMD_SET_CS_DISABLE,1u);
    bflb_spi_feature_control(s->spi,SPI_CMD_CLEAR_TX_FIFO,0u);
    bflb_spi_feature_control(s->spi,SPI_CMD_CLEAR_RX_FIFO,0u);
    bflb_dma_channel_tcint_clear(s->tx_channel); bflb_dma_channel_tcint_clear(s->rx_channel);
    t.src_addr=(uint32_t)(uintptr_t)tx; t.dst_addr=DMA_ADDR_SPI0_TDR; t.nbytes=(uint32_t)bytes;
    r.src_addr=DMA_ADDR_SPI0_RDR; r.dst_addr=(uint32_t)(uintptr_t)rx; r.nbytes=(uint32_t)bytes;
    if (bflb_dma_channel_lli_reload(s->tx_channel,s->tx_lli,1u,&t,1u)!=1 ||
        bflb_dma_channel_lli_reload(s->rx_channel,s->rx_lli,1u,&r,1u)!=1) return S10_DMA_SETUP;
    bflb_l1c_dcache_clean_range((void *)tx,(uint32_t)extent);
    bflb_l1c_dcache_clean_invalidate_range(rx,(uint32_t)extent);
    fence();
    s->tx=tx; s->rx=rx; s->bytes=bytes; s->cache_extent=extent;
    s->token=token; s->last_token=token; s->target=target; s->timeout_us=timeout_us;
    s->tx_terminal=s->rx_terminal=0u; s->result=S10_DMA_PENDING;
    if (s->binding.select(s->binding.user,target) || s->binding.owner(s->binding.user)!=target) {
        /* Even a failed select can leave a chip selected. Keep ownership
         * until poll has confirmed every CS high; an error is not a fence. */
        s->state=S10_DMA_ABORTING; s->result=S10_DMA_OWNER; ++s->owner_faults;
        return S10_DMA_OWNER;
    }
    s->started_us=s->binding.time_us(s->binding.user);
    s->state=S10_DMA_RUNNING;
    bflb_spi_link_rxdma(s->spi,true); bflb_spi_link_txdma(s->spi,true);
    /* RX is armed first, before TX can emit the first clock. */
    bflb_dma_channel_start(s->rx_channel); bflb_dma_channel_start(s->tx_channel);
    return S10_DMA_PENDING;
}

static void abort_transfer(s10_spi_dma *s,int reason)
{
    s->state=S10_DMA_ABORTING; s->result=reason;
    bflb_dma_channel_stop(s->tx_channel); bflb_dma_channel_stop(s->rx_channel);
    bflb_spi_link_txdma(s->spi,false); bflb_spi_link_rxdma(s->spi,false);
    fence();
}

static int quiescent(s10_spi_dma *s)
{
    return !hardware_active(s->tx_channel) && !hardware_active(s->rx_channel) &&
           !bflb_spi_isbusy(s->spi);
}

int s10_spi_dma_poll(s10_spi_dma *s,uint64_t token)
{
    if (!s || !token || token!=s->token || s->state==S10_DMA_IDLE) return S10_DMA_ARGUMENT;
    if (s->state==S10_DMA_RETIRED) return s->result;
    if (s->state==S10_DMA_RUNNING) {
        if (s->binding.owner(s->binding.user)!=s->target) {
            ++s->owner_faults; abort_transfer(s,S10_DMA_OWNER);
        } else if (s->binding.time_us(s->binding.user)-s->started_us>=s->timeout_us) {
            ++s->timed_out; abort_transfer(s,S10_DMA_TIMEOUT);
        } else if (bflb_spi_feature_control(s->spi,SPI_CMD_READ_FIFO_ERROR_FLAG,0u)) {
            abort_transfer(s,S10_DMA_FIFO);
        }
    }
    if (s->state==S10_DMA_RUNNING && (!s->tx_terminal || !s->rx_terminal)) return S10_DMA_PENDING;
    if (!quiescent(s)) return s->result;
    /* Both DMA bus accesses and the actual SPI tail/FIFO are finished. */
    fence();
    bflb_spi_link_txdma(s->spi,false); bflb_spi_link_rxdma(s->spi,false);
    if (s->binding.select(s->binding.user,0) || s->binding.owner(s->binding.user)!=0) {
        if (s->result==S10_DMA_PENDING) { ++s->owner_faults; s->result=S10_DMA_OWNER; }
        s->state=S10_DMA_ABORTING;
        return s->result;
    }
    bflb_l1c_dcache_invalidate_range(s->rx,(uint32_t)s->cache_extent);
    fence();
    bflb_dma_channel_tcint_clear(s->tx_channel); bflb_dma_channel_tcint_clear(s->rx_channel);
    if (s->result==S10_DMA_PENDING) { s->result=S10_DMA_DONE; ++s->completed; }
    s->state=S10_DMA_RETIRED;
    return s->result;
}

int s10_spi_dma_cancel(s10_spi_dma *s,uint64_t token)
{
    if (!s || token!=s->token || s->state==S10_DMA_IDLE) return S10_DMA_ARGUMENT;
    if (s->state==S10_DMA_RUNNING) { ++s->cancelled; abort_transfer(s,S10_DMA_CANCELLED); }
    return s10_spi_dma_poll(s,token);
}

int s10_spi_dma_is_retired(const s10_spi_dma *s,uint64_t token)
{
    return s && token && s->token==token && s->state==S10_DMA_RETIRED;
}

int s10_spi_dma_release(s10_spi_dma *s,uint64_t token)
{
    if (!s || token!=s->token) return S10_DMA_ARGUMENT;
    if (!s10_spi_dma_is_retired(s,token)) { ++s->early_release_rejected; return S10_DMA_BUSY; }
    s->tx=NULL; s->rx=NULL; s->token=0u; s->state=S10_DMA_IDLE;
    return S10_DMA_PENDING;
}
