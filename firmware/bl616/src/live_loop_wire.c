#include "live_loop_wire.h"
#include "s9_protocol.h"
#include <string.h>
static int encode(uint8_t *tx,uint32_t epoch,uint32_t serial,unsigned opcode,const uint8_t *payload,unsigned length){
    if(!tx||(!epoch&&opcode!=LL_WIRE_POLL)||length>116)return LL_E_ARGUMENT;
    memset(tx,0,LL_WIRE_BYTES);memcpy(tx,"R20C",4);tx[4]=LL_WIRE_VERSION;tx[5]=(uint8_t)opcode;
    s9_put16(tx+6,(uint16_t)length);s9_put32(tx+8,epoch);s9_put32(tx+12,serial);
    memcpy(tx+16,payload,length);s9_put32(tx+16+length,s9_crc32(tx,16+length));return LL_OK;
}
int ll_wire_control(uint8_t tx[LL_WIRE_BYTES],uint32_t epoch,uint32_t serial,uint8_t subop,uint16_t revision,uint32_t target){
    if(subop<1||subop>7||(!serial&&subop!=LL_CTL_KEEP)||
       ((subop==LL_CTL_RELEASE_REV||subop==LL_CTL_CAPTURE_ON)&&!revision))return LL_E_ARGUMENT;
    uint8_t p[8]={subop,0};s9_put16(p+2,revision);s9_put32(p+4,target);
    return encode(tx,epoch,serial,LL_WIRE_CONTROL,p,8);
}
int ll_wire_poll(uint8_t tx[LL_WIRE_BYTES],uint32_t epoch,uint32_t ack,unsigned max_count){
    if(max_count>2)return LL_E_ARGUMENT;
    uint8_t p[8]={0};s9_put32(p,ack);p[4]=(uint8_t)max_count;
    return encode(tx,epoch,0,LL_WIRE_POLL,p,8);
}
int ll_wire_decode(const uint8_t rx[LL_WIRE_BYTES],ll_wire_status *s){
    if(!rx||!s)return LL_E_ARGUMENT;
    if(memcmp(rx,"R20S",4)||rx[4]!=3||memcmp(rx+92,"L12S",4)||rx[96]!=1||
       rx[134]>2||rx[135]!=24||s9_get32(rx+200)!=s9_crc32(rx,200))return LL_E_ARGUMENT;
    memset(s,0,sizeof *s);s->state=rx[97];s->credit=rx[98];s->flags=rx[99];
    s->epoch=s9_get32(rx+100);s->accepted_serial=s9_get32(rx+104);s->effective_control_serial=s9_get32(rx+108);
    s->now=s9_get64(rx+112);s->watermark=s9_get64(rx+120);s->capture_sequence=s9_get32(rx+128);
    s->error=(int16_t)s9_get16(rx+132);s->count=rx[134];s->effective_sample=s9_get64(rx+136);s->first_missing=s9_get64(rx+192);
    if(s->watermark>s->now||(s->count&&!s->capture_sequence))return LL_E_TIME;
    for(unsigned i=0;i<s->count;i++){
        const uint8_t *p=rx+144+i*24;ll_capture_cell *v=&s->cell[i];
        v->frame=s9_get64(p);v->token=s9_get64(p+8);v->word=s9_get32(p+16);v->timbre=p[20];v->flags=p[21];
        unsigned source=v->word>>28,k=(v->word>>16)&255u,kind=(v->word>>24)&15u;
        if(!v->token||v->word&1u||v->timbre>5||v->flags!=1||s9_get16(p+22)||
           !((source==0&&k<8)||(source==2&&k<32))||kind<1||kind>3||v->frame>s->now)return LL_E_ARGUMENT;
        if(i&&v->frame<s->cell[i-1].frame)return LL_E_TIME;
    }
    return LL_OK;
}
int ll_wire_prepare(ll_core *c,ll_core *scratch,uint64_t through,uint32_t epoch,uint32_t serial,uint8_t tx[LL_WIRE_BYTES],ll_wire_batch *b){
    if(!c||!scratch||!tx||!b||b->active||!serial)return LL_E_STATE;
    *scratch=*c;memset(b,0,sizeof *b);ll_delivery next;
    int result=ll_peek(scratch,through,&next);if(result)return result;
    uint64_t target=next.due;uint16_t revision=next.revision;uint8_t timbre=next.timbre;
    uint8_t payload[116]={0};
    for(unsigned i=0;i<9;i++){
        if(next.due!=target||next.revision!=revision||next.timbre!=timbre)break;
        b->item[b->count++]=next;
        s9_put32(payload+8+i*12,next.word);s9_put64(payload+12+i*12,next.token);
        result=ll_pop(scratch,&next);if(result)return result;
        result=ll_peek(scratch,through,&next);
        if(result==LL_IGNORED){b->group_end=1;break;}
        if(result)return result;
        if(next.due!=target){b->group_end=1;break;}
    }
    s9_put32(payload,(uint32_t)target);payload[4]=b->count;payload[5]=timbre;s9_put16(payload+6,b->group_end?1:0);
    result=encode(tx,epoch,serial,LL_WIRE_EVENTS,payload,8+b->count*12);
    if(result)return result;
    b->serial=serial;b->active=1;return LL_OK;
}
int ll_wire_accept(ll_core *c,ll_wire_batch *b,uint32_t accepted){
    if(!c||!b||!b->active||accepted!=b->serial)return LL_E_ID;
    for(unsigned i=0;i<b->count;i++){int result=ll_pop(c,&b->item[i]);if(result)return result;}
    b->active=0;return LL_OK;
}
