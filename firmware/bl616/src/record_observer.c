/* Fixed read-only two-task observer for the reviewed BL616 common RV32 port.
 * No RPC, FatFs, MMIO, allocation, task walk, stack scan or arbitrary address IO. */
#include "record_observer.h"
#include "FreeRTOS.h"
#include "task.h"
#include "bflb_core.h"
#include "s11_service.h"
#include "s11_storage.h"
#include "bus_fault.h"
#include <string.h>
extern volatile unsigned record_bench_stage;
typedef struct {uint32_t phase,tick,loops,progress,value,result;void *handle;uintptr_t low,high;} task_observation;
static volatile task_observation tasks[2];
void record_observer_phase(unsigned t,unsigned p){if(t>1)return;tasks[t].phase=p;tasks[t].tick=(uint32_t)xTaskGetTickCount();if(p==OBS_LOOP)tasks[t].loops++;}
void record_observer_progress(unsigned t,uint32_t value){if(t>1)return;tasks[t].progress++;tasks[t].value=value;}
void record_observer_result(unsigned t,int value){if(t<2)tasks[t].result=(uint32_t)value;}
void record_observer_bind(unsigned t,void *handle,unsigned words){
 if(t>1||!handle)return;TaskStatus_t s;vTaskGetInfo(handle,&s,pdFALSE,eReady);
 tasks[t].low=(uintptr_t)s.pxStackBase;tasks[t].high=tasks[t].low+words*sizeof(StackType_t);tasks[t].handle=handle;
}
/* SDK tasks.c guarantees pxTopOfStack is the first TCB word. portASM's
 * context[0]=mepc, context[1]=mstatus; FS dirty adds 132 bytes before the
 * integer frame. Four-byte context alignment, not sixteen, is correct. */
extern char __tcm_text_start__[],__tcm_text_end__[],__rom_text_start__[],__rom_text_end__[];
static void saved_context(const volatile task_observation *t,uint32_t w[6]){
 uintptr_t sp=0;for(unsigned i=0;i<6;i++)w[i]=0;
 if(!t->handle)return;memcpy(&sp,t->handle,sizeof sp);
 if((sp&3u)||sp<t->low||sp>t->high||t->high-sp<124u)return;
 const uint32_t *f=(const uint32_t*)sp;uint32_t status=f[1];unsigned bytes=(status&0x6000u)==0x6000u?256u:124u;
 if(t->high-sp<bytes)return;
 uint32_t pc=f[0];w[0]=(uint32_t)sp;w[1]=pc;w[2]=(uint32_t)(sp+bytes);
 /* Linker EXEC ranges: XIP application and ITCM. Do not follow PC. */
 w[3]=((uintptr_t)pc>=(uintptr_t)__rom_text_start__&&(uintptr_t)pc<(uintptr_t)__rom_text_end__)||((uintptr_t)pc>=(uintptr_t)__tcm_text_start__&&(uintptr_t)pc<(uintptr_t)__tcm_text_end__)?1u:2u;
 w[4]=f[bytes==256u?35u:2u];w[5]=status;
}
static char *hex(char *p,uint32_t n){static const char a[]="0123456789abcdef";for(int i=7;i>=0;i--)*p++=a[(n>>(i*4))&15u];return p;}
static char *word(char *p,uint32_t n){p=hex(p,n);*p++=',';return p;}
static char *fault_words(char *p,const bus_fault_snapshot *s){
 uint32_t w[20]={0};if(s){w[0]=(uint32_t)s->now;w[1]=(uint32_t)s->started;w[2]=(uint32_t)s->deadline;w[3]=(uint32_t)s->token;
 w[4]=s->reason;w[5]=s->phase;w[6]=s->dma_state;w[7]=s->spi_busy;w[8]=s->fifo0;w[9]=s->fifo1;w[10]=s->tx;w[11]=s->rx;w[12]=s->raw_error;w[13]=s->error;w[14]=s->cs_pads;w[15]=s->owner;w[16]=s->sd_command|(s->sd_phase<<8)|(s->sd_index<<16);w[17]=s->config;w[18]=s->prd0;w[19]=s->prd1;}
 for(unsigned i=0;i<20;i++)p=word(p,w[i]);return p;
}
unsigned record_observer_reply(char out[512],unsigned page,uint32_t seq){
 char *p=out;memcpy(p,"\r\nPEEK1 seq=",12);p+=12;p=hex(p,seq);memcpy(p," page=",6);p+=6;*p++=(char)('0'+page);memcpy(p," n=",3);p+=3;p=hex(p,page?42u:40u);memcpy(p," data=",6);p+=6;
 if(page){const bus_fault_snapshot *post=bus_fault_get(),*pre=bus_fault_pre_abort();p=word(p,(uint32_t)bus_fault_active());p=word(p,pre!=0);p=fault_words(p,pre);p=fault_words(p,post);}
 else{
  const s11_service_stats *s=s11_service_statistics();const s11_storage_stats *f=s11_storage_statistics();
  uint32_t w[16]={(uint32_t)xTaskGetTickCount(),record_bench_stage,(uint32_t)bus_fault_active(),s->active,s->wire_state,s->command,s->ack_pending,s->pcm_buffered,s->event_buffered,(uint32_t)s->received_pcm,(uint32_t)s->stored_pcm,f->state,(uint32_t)f->error,f->verified_pcm,s->remote_stop_unconfirmed,s->error};
  for(unsigned i=0;i<16;i++)p=word(p,w[i]);
  for(unsigned t=0;t<2;t++){uint32_t c[6];/* Only copy two suspended lower-priority frames while IRQs are briefly masked. */
   uintptr_t flags=bflb_irq_save();saved_context(&tasks[t],c);bflb_irq_restore(flags);
   p=word(p,tasks[t].phase);p=word(p,tasks[t].tick);p=word(p,tasks[t].loops);p=word(p,tasks[t].progress);p=word(p,tasks[t].value);p=word(p,tasks[t].result);for(unsigned i=0;i<6;i++)p=word(p,c[i]);}
 }
 --p;memcpy(p," END=",5);p+=5;p=hex(p,seq);*p++='\r';*p++='\n';return (unsigned)(p-out);
}
