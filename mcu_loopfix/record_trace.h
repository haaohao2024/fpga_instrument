#ifndef RECORD_TRACE_H
#define RECORD_TRACE_H
#include <stdint.h>
typedef struct {uint32_t cycle,sequence,transaction,event_flags,spi,dma;} order_trace_row;
enum {OT_SWITCH=1,OT_HIGH,OT_CFG_BEGIN,OT_CFG_DONE,OT_LOW,OT_DMA_ARM,OT_TX_IRQ,OT_RX_IRQ,OT_IDLE,OT_DMA_DONE,OT_PIO_BEGIN,OT_PIO_RETURN,OT_SD_BLOCK,OT_SD_RESPONSE,OT_FREEZE,OT_SD_READY,OT_SD_COMMAND,OT_RESELECT,OT_STOP,OT_CAPTURE_GRANT,OT_CAPTURE_REFILL,OT_CAPTURE_REFUSE,OT_CAPTURE_LEASE};
extern volatile uint32_t order_trace_mode,order_trace_count,order_trace_frozen,order_trace_reason;
extern volatile order_trace_row order_trace_rows[96];
void order_trace_bind(uint32_t spi,uint32_t tx,uint32_t rx,uint32_t gpio);
void order_trace_config(unsigned mode);
void order_trace_select(unsigned event,unsigned previous,unsigned target);
void order_trace_take(unsigned event,unsigned detail);
void order_trace_data(unsigned event,uint32_t a,uint32_t b);
void order_trace_arm(uint32_t token);
void order_trace_irq(unsigned rx);
void order_trace_freeze(unsigned reason);
void order_trace_dump(void);
void record_trace_reset(void);
/* This image replaces the old aggregate timing rows with ordered events. */
enum {
    RP_PAYLOAD,
    RP_STOP_WINDOW,
    RP_ADMIT,
    RP_SDCRC,
    RP_COMMAND,
    RP_FILECRC,
    RP_FPGA,
    RP_SD_LEASE,
    RP_CARD_BUSY,
    RP_ADMIT_DELAY_US,
    RP_SD_DMA_WAIT,
    RP_COUNT
};
void record_phase_add(unsigned kind,uint32_t us);
void record_phase_fpga(uint64_t begin,uint64_t end);
void record_phase_card_begin(uint64_t now);
void record_phase_card_end(uint64_t now);
/* Keep skipped timing expressions unevaluated to avoid perturbing the baseline. */
#define record_trace_measure(kind, us) \
    do { \
        if ((kind)==RP_PAYLOAD || (kind)==RP_ADMIT || (kind)==RP_SDCRC || \
            (kind)==RP_FILECRC || (kind)==RP_CARD_BUSY || (kind)==RP_ADMIT_DELAY_US || \
            (kind)==RP_SD_DMA_WAIT) { \
            record_phase_add((kind), (us)); \
        } \
    } while (0)
#define record_trace_start(...) ((void)0)
#define record_trace_sd(...) ((void)0)
#define record_trace_retire(d,p,q,r,s,b,f,e) record_capture_metric((r),(b))
void record_capture_metric(uint32_t received,uint32_t buffered);
#endif
