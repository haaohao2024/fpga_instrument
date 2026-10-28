#include "link_diag.h"
#include "FreeRTOS.h"
#include "task.h"
#include <stdio.h>
#include <string.h>
/* Only small state metadata. No peer address, key, packet, note or audio data. */
typedef struct {uint32_t tick,kind,a,b,c;} link_record;
static link_record records[64];
static unsigned head,tail,count;
static uint32_t dropped,reported,once_mask;
void link_diag_event(unsigned kind,uint32_t a,uint32_t b,uint32_t c){
    taskENTER_CRITICAL();
    if(kind==LD_CONNECT)once_mask=0;
    if(kind==LD_LOCAL_CLOSE || kind==LD_PEER_TIMEOUT || kind==LD_BUS_TIMEOUT || kind==LD_INIT_TIMEOUT){
        uint32_t bit=1u<<kind;
        if(once_mask&bit){taskEXIT_CRITICAL();return;}
        once_mask|=bit;
    }
    if(count==64){++dropped;taskEXIT_CRITICAL();return;}
    records[head]=(link_record){xTaskGetTickCount(),kind,a,b,c};
    head=(head+1)&63;++count;
    taskEXIT_CRITICAL();
}
/* First failing completed DMA is frozen before its buffer can be reused.
 * The bus owner only copies; USB formatting runs later in status_task.
 * One capture per boot, publication after the complete copy. */
static uint8_t bad_request[64],bad_response[580];
static unsigned bad_length,bad_offset;
static int bad_error;
static uint32_t bad_tick;
static unsigned bad_state;
void link_diag_bad_response(int error,unsigned length,const uint8_t *request,const uint8_t *response){
 if(length<64||length>sizeof bad_response||__atomic_load_n(&bad_state,__ATOMIC_ACQUIRE))return;
 memcpy(bad_request,request,64);memcpy(bad_response,response,length);
 bad_error=error;bad_length=length;bad_tick=xTaskGetTickCount();
 __atomic_store_n(&bad_state,1,__ATOMIC_RELEASE);
}
static void bad_response_pump(void){
 if(__atomic_load_n(&bad_state,__ATOMIC_ACQUIRE)!=1)return;
 if(!bad_offset)printf("WIRE96 BAD tick=%lu error=%d length=%u\r\n",(unsigned long)bad_tick,bad_error,bad_length);
 for(unsigned chunk=0;chunk<2&&bad_offset<64+bad_length;chunk++){
  const uint8_t *data=bad_offset<64?bad_request:bad_response;
  unsigned offset=bad_offset<64?bad_offset:bad_offset-64;
  unsigned n=bad_offset<64?64-bad_offset:bad_length-offset;if(n>32)n=32;
  char line[112];int used=snprintf(line,sizeof line,"WIRE96 %s offset=%u hex=",bad_offset<64?"TX":"RX",offset);
  for(unsigned i=0;i<n;i++)used+=snprintf(line+used,sizeof line-(unsigned)used,"%02x",data[offset+i]);
  printf("%s\r\n",line);bad_offset+=n;
 }
 if(bad_offset==64+bad_length)__atomic_store_n(&bad_state,2,__ATOMIC_RELEASE);
}
void link_diag_pump(void){
    bad_response_pump();
    for(unsigned n=0;n<8;n++){
        link_record r;int have;
        taskENTER_CRITICAL();have=count!=0;
        if(have){r=records[tail];tail=(tail+1)&63;--count;}
        taskEXIT_CRITICAL();
        if(!have)break;
        printf("R81 LINK tick=%lu kind=%lu a=%lu b=%lu c=%lu\r\n",
               (unsigned long)r.tick,(unsigned long)r.kind,(unsigned long)r.a,
               (unsigned long)r.b,(unsigned long)r.c);
    }
    if(reported!=dropped){reported=dropped;printf("R81 LINK dropped=%lu\r\n",(unsigned long)reported);}
}
