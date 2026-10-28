#ifndef BUS_FAULT_H
#define BUS_FAULT_H
#include <stdint.h>
enum {BUS_FAULT_PIO_BYTE=1,BUS_FAULT_PIO_BLOCK=2,BUS_FAULT_DMA_DRAIN=3,BUS_FAULT_DMA_RX_RESIDUE=4};
#define BUS_FAULT_ABORT_DRAIN_US 1000u
typedef struct {
 uint64_t now,started,deadline,token;
 uint32_t reason,phase,dma_state,spi_busy,fifo0,fifo1,tx,rx,raw_error,error;
 uint32_t cs_pads,owner,sd_command,sd_phase,sd_index;
 uint32_t config,prd0,prd1;
} bus_fault_snapshot;
void bus_fault_bind(uint32_t spi,uint32_t tx,uint32_t rx,uint32_t gpio);
int bus_fault_active(void);
void bus_fault_capture(unsigned reason,unsigned phase,uint64_t started,uint64_t deadline,uint64_t token,unsigned dma_state);
void bus_fault_note_abort(unsigned reason,unsigned phase,uint64_t started,uint64_t token,unsigned dma_state);
void bus_fault_clear_abort(void);
const bus_fault_snapshot *bus_fault_pre_abort(void);
const bus_fault_snapshot *bus_fault_get(void);
void bus_fault_report(void);
void bus_fault_pump(void);
#endif
