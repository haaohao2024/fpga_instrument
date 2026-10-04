#include "s10_pcm_tx.h"
#include <string.h>
enum { EMPTY=0, READY=1, WAIT_ACK=2, CANCELED=3 };
enum { START=1, DATA=2, STOP=3, STATUS=4 };
static void put16(uint8_t *p,uint16_t v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void put32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static void put64(uint8_t *p,uint64_t v){for(unsigned i=0;i<8;i++)p[i]=(uint8_t)(v>>(8*i));}
static uint16_t get16(const uint8_t *p){return (uint16_t)(p[0]|((uint16_t)p[1]<<8));}
static uint32_t get32(const uint8_t *p){uint32_t v=0;for(unsigned i=0;i<4;i++)v|=(uint32_t)p[i]<<(8*i);return v;}
static uint64_t get64(const uint8_t *p){uint64_t v=0;for(unsigned i=0;i<8;i++)v|=(uint64_t)p[i]<<(8*i);return v;}
uint32_t s10_pcm_crc32(const uint8_t *p,size_t n){uint32_t c=0xffffffffu;while(n--){c^=*p++;for(unsigned k=0;k<8;k++)c=(c>>1)^((c&1)?0xedb88320u:0);}return ~c;}
static void header(uint8_t *p,unsigned op,uint64_t epoch,uint32_t seq,uint64_t origin,unsigned pairs,unsigned flags){
    memset(p,0,64);memcpy(p,"S10P",4);p[4]=1;p[5]=(uint8_t)op;put16(p+6,(uint16_t)pairs);
    put64(p+8,epoch);put32(p+16,seq);put64(p+20,origin);put32(p+28,flags);
}
void s10_pcm_tx_init(s10_pcm_tx *s){memset(s,0,sizeof *s);s->next_ticket=1;
    s->service=(s10_tx_service_config){474,896,2560,32,64,2500};}
int s10_pcm_tx_service_configure(s10_pcm_tx *s,const s10_tx_service_config *c){
    if(!s||!c||c->steady_trigger<256||c->steady_trigger>768||c->sd_trigger<768||c->sd_trigger>1536||
       c->mcu_target<1024||c->mcu_target>3584||c->mcu_bias_divisor<16||c->mcu_bias_limit>128||
       c->query_period_us<1000||c->query_period_us>5000)return S10_TX_ARGUMENT;
    if(s->state!=S10_TX_CLOSED||s->dma_active)return S10_TX_BUSY;
    s->service=*c;return 0;
}
void s10_pcm_tx_sd_request(s10_pcm_tx *s,int requested){s->sd_request=(uint8_t)(requested!=0);}
void s10_pcm_tx_refill(s10_pcm_tx *s){s->force_refill=1;}
int s10_pcm_tx_open(s10_pcm_tx *s,uint64_t epoch,int track){
    if(!s||!epoch||(track!=0&&track!=1))return S10_TX_ARGUMENT;
    if(s->state!=S10_TX_CLOSED||s->dma_active||s->count)return S10_TX_BUSY;
    if(epoch<=s->last_epoch)return S10_TX_STALE;
    if(s->generation==UINT64_MAX)return S10_TX_EXHAUSTED;
    s->epoch=epoch;s->last_epoch=epoch;s->generation++;s->track=(uint8_t)track;s->state=S10_TX_OPENING;
    s->next_sequence=1;s->last_ack=0;s->source_head=0;s->credit=0;s->reserved=0;
    s->telemetry_valid=0;s->have_stream_generation=0;s->sd_request=0;s->force_refill=0;s->data_after_status=0;s->record_burst=0;
    s->last_status_us=0;s->bank[0].state=s->bank[1].state=EMPTY;return 0;
}
int s10_pcm_tx_enqueue(s10_pcm_tx *s,uint64_t epoch,const int16_t *lr,size_t n){
    if(!s||(!lr&&n)||n>S10_TX_CAPACITY)return S10_TX_ARGUMENT;
    if(epoch!=s->epoch)return S10_TX_STALE;
    if(s->state!=S10_TX_OPENING&&s->state!=S10_TX_PLAY)return S10_TX_BUSY;
    if(n>S10_TX_CAPACITY-s->count||UINT64_MAX-s->ingressed<n){s->source_rejections++;return S10_TX_BUSY;}
    for(size_t i=0;i<n;i++){unsigned at=(s->head+s->count+i)%S10_TX_CAPACITY;s->pcm[at][0]=lr[2*i];s->pcm[at][1]=lr[2*i+1];}
    s->count=(uint16_t)(s->count+n);s->ingressed+=n;return 0;
}
int s10_pcm_tx_stop(s10_pcm_tx *s,uint64_t epoch){
    if(!s)return S10_TX_ARGUMENT;
    if(epoch!=s->epoch)return S10_TX_STALE;
    if(s->state==S10_TX_CLOSED||s->state==S10_TX_CLOSING)return 0;
    if(s->generation==UINT64_MAX)return S10_TX_EXHAUSTED;
    s->generation++;s->state=S10_TX_CLOSING;s->discarded+=s->count;s->count=0;s->reserved=0;s->head=0;
    s->telemetry_valid=0;s->credit=0;s->sd_request=0;s->force_refill=0;s->record_burst=0;
    for(unsigned i=0;i<2;i++)s->bank[i].state=(s->dma_active&&s->dma_slot==i)?CANCELED:EMPTY;
    return 0;
}
static int free_bank(const s10_pcm_tx *s){for(unsigned i=0;i<2;i++)if(s->bank[i].state==EMPTY)return (int)i;return -1;}
static int oldest(const s10_pcm_tx *s,unsigned state){int a=-1;for(unsigned i=0;i<2;i++)if(s->bank[i].state==state&&(a<0||s->bank[i].sequence<s->bank[a].sequence))a=(int)i;return a;}
static void make_data(s10_pcm_tx *s,unsigned i,unsigned limit){
    s10_tx_bank *b=&s->bank[i];unsigned n=s->count-s->reserved;if(n>128)n=128;if(n>limit)n=limit;
    b->sequence=s->next_sequence++;b->origin=s->source_head+s->reserved;b->pairs=(uint16_t)n;
    b->length=(uint16_t)(36+4*n);if(b->length<64)b->length=64;
    header(b->tx,DATA,s->epoch,b->sequence,b->origin,n,0);
    for(unsigned k=0;k<n;k++){unsigned at=(s->head+s->reserved+k)%4096;put16(b->tx+32+4*k,(uint16_t)s->pcm[at][0]);put16(b->tx+34+4*k,(uint16_t)s->pcm[at][1]);}
    put32(b->tx+32+4*n,s10_pcm_crc32(b->tx,32+4*n));
    /* At5MHz, each DATA follows the inventory target. No forced four-packet
     * overshoot that pins TRACK fast while the MCU reservoir drains. */
    s->record_burst=0;
    b->state=READY;b->sent=0;s->reserved=(uint16_t)(s->reserved+n);
}
static unsigned estimated_stock(const s10_pcm_tx *s,uint64_t now){
    if(!s->telemetry_valid||now<s->telemetry_us)return 0;
    uint64_t base=s->stream_buffered+s->stream_pending+s->source_head-s->telemetry_source_head;
    /* Sent but not ACKed may already belong to FPGA. Count at most these two
     * immutable packets here; missing ACKs are resolved by a fresh STATUS. */
    for(unsigned i=0;i<2;i++)if(s->bank[i].state!=EMPTY&&s->bank[i].state!=CANCELED&&s->bank[i].sent)base+=s->bank[i].pairs;
    uint64_t age=now-s->telemetry_us;if(age>UINT64_MAX/48048u)return 0;
    uint64_t a=age*48048u,used=a/1000000u+(a%1000000u!=0);
    if(used>=base)return 0;
    base-=used;return base>UINT32_MAX?UINT32_MAX:(unsigned)base;
}
static int next_job(s10_pcm_tx *s,uint64_t now,s10_tx_job *j,int only_status){
    if(!s||!j)return S10_TX_ARGUMENT;
    if(s->dma_active||s->state==S10_TX_CLOSED)return S10_TX_BUSY;
    if(!s->next_ticket)return S10_TX_EXHAUSTED;
    unsigned op=STATUS;int slot=2;
    if(s->state==S10_TX_OPENING)op=START;
    else if(s->state==S10_TX_CLOSING)op=STOP;
    else if(!only_status){
        int ready=oldest(s,READY);int wait=oldest(s,WAIT_ACK);
        unsigned unsent=s->count-s->reserved,stock=estimated_stock(s,now);
        int bias=((int)(s->record_feedback?s->count:unsent)-(int)s->service.mcu_target)/(int)s->service.mcu_bias_divisor;
        if(bias>(int)s->service.mcu_bias_limit)bias=s->service.mcu_bias_limit;
        if(bias< -(int)s->service.mcu_bias_limit)bias=-(int)s->service.mcu_bias_limit;
        unsigned trigger=(unsigned)((int)s->service.steady_trigger+bias);
        int boosting=s->sd_request&&unsent>512;
        if(boosting)trigger=s->service.sd_trigger;
        unsigned period=s->force_refill||s->sd_request?500:s->service.query_period_us;
        int retry_ready=ready>=0&&(wait<0||s->bank[ready].sequence<s->bank[wait].sequence)&&s->credit>=128;
        int new_ready=unsent&&s->credit>=128&&(s->force_refill||(s->record_feedback&&s->record_burst)||stock<trigger)&&s->next_sequence!=UINT32_MAX&&s->source_head<=UINT64_MAX-s->count&&free_bank(s)>=0;
        if(!s->telemetry_valid||(!s->force_refill&&now-s->last_status_us>=period&&(s->data_after_status||(!retry_ready&&!new_ready))))slot=2;
        else if(retry_ready){slot=ready;op=DATA;if(s->bank[ready].sent)s->retries++;}
        else if(wait>=0&&now-s->bank[wait].last_sent_us>=S10_TX_RETRY_US){slot=wait;op=DATA;s->retries++;}
        else if(unsent&&s->credit>=128&&(s->force_refill||(s->record_feedback&&s->record_burst)||stock<trigger)&&s->next_sequence!=UINT32_MAX&&s->source_head<=UINT64_MAX-s->count){
            slot=free_bank(s);if(slot>=0){make_data(s,(unsigned)slot,boosting&&!s->force_refill?unsent-512:128);op=DATA;}else slot=2;
        }
        if(slot==2&&s->telemetry_valid&&now-s->last_status_us<period)return S10_TX_BUSY;
    }
    if(slot==2){header(s->control_tx,op,s->epoch,0,0,0,op==START?s->track:op==STATUS?1:0);put32(s->control_tx+32,s10_pcm_crc32(s->control_tx,32));memset(s->control_rx,0,64);j->tx=s->control_tx;j->rx=s->control_rx;j->length=64;j->pairs=0;if(op==STATUS){s->queries++;if(s->sd_request||s->force_refill)s->urgent_queries++;}}
    else {s10_tx_bank *b=&s->bank[slot];j->tx=b->tx;j->rx=b->rx;j->length=b->length;j->pairs=b->pairs;memset(b->rx,0,sizeof b->rx);b->last_sent_us=now;b->sent=1;s->force_refill=0;s->data_after_status=1;}
    s->dma_active=1;s->dma_slot=(uint8_t)slot;s->dma_op=(uint8_t)op;s->started_us=now;s->ticket=s->next_ticket++;
    j->ticket=s->ticket;j->epoch=s->epoch;j->generation=s->generation;j->operation=(uint8_t)op;return 0;
}
int s10_pcm_tx_next(s10_pcm_tx *s,uint64_t now,s10_tx_job *j){return next_job(s,now,j,0);}
int s10_pcm_tx_status_next(s10_pcm_tx *s,uint64_t now,s10_tx_job *j){return next_job(s,now,j,1);}
static int accept_status(s10_pcm_tx *s,const uint8_t *p,unsigned op,unsigned slot){
    if(memcmp(p,"S10S",4)||p[4]!=1||get32(p+28)!=s10_pcm_crc32(p,28)){s->bad_status++;return S10_TX_PROTOCOL;}
    uint32_t ack=get32(p+16);unsigned wirestate=p[5]&3u;unsigned credit=get16(p+6);
    if(s->state==S10_TX_OPENING&&op==START&&wirestate==0&&get64(p+8)<s->epoch){
        /* Every response describes the state before its own request. The
         * preceding stopped epoch on first START is expected, not a fault. */
        return 0;
    }
    if(s->state==S10_TX_CLOSING){
        /* STOP owns a source discard barrier, so previous DATA ACKs must not
         * consume the now-cleared ring. A never-opened remote epoch zero is
         * already stopped and also safely completes this local barrier. */
        uint64_t remote_epoch=get64(p+8);
        if(remote_epoch!=s->epoch&&!(remote_epoch==0&&wirestate==0)){s->bad_status++;return S10_TX_PROTOCOL;}
        if(wirestate==0)s->state=S10_TX_CLOSED;
        return 0;
    }
    if(get64(p+8)!=s->epoch){s->bad_status++;return S10_TX_PROTOCOL;}
    if(credit>256||credit%128||ack<s->last_ack||ack>=s->next_sequence){s->bad_status++;return S10_TX_PROTOCOL;}
    /* FPGA acknowledgements are cumulative in one strictly ordered epoch.
     * Validate the entire prefix before modifying the source ring. */
    uint32_t expect=s->last_ack+1;unsigned total=0;
    while(expect<=ack){int found=-1;for(unsigned i=0;i<2;i++)if(s->bank[i].state!=EMPTY&&s->bank[i].state!=CANCELED&&s->bank[i].sequence==expect&&s->bank[i].sent)found=(int)i;
        if(found<0){s->bad_status++;return S10_TX_PROTOCOL;}total+=s->bank[found].pairs;expect++;}
    if(total>s->count||total>s->reserved){s->bad_status++;return S10_TX_PROTOCOL;}
    for(unsigned i=0;i<2;i++)if(s->bank[i].state!=EMPTY&&s->bank[i].state!=CANCELED&&s->bank[i].sequence<=ack)s->bank[i].state=EMPTY;
    s->head=(uint16_t)((s->head+total)%4096);s->count=(uint16_t)(s->count-total);s->reserved=(uint16_t)(s->reserved-total);
    s->committed+=total;s->source_head+=total;s->last_ack=ack;
    /* Response is sampled at CS assertion, before the current DATA commits.
     * Reserve a whole 128-pair FPGA bank if that packet was not in snapshot. */
    if(op==DATA&&slot<2&&s->bank[slot].state!=EMPTY&&s->bank[slot].sequence>ack)credit=credit>=128?credit-128:0;
    s->credit=(uint16_t)credit;
    int generation_changed=0;
    if(p[5]&128u){
        uint32_t gen=get32(p+24);generation_changed=s->have_stream_generation&&gen!=s->stream_generation;
        s->stream_state=p[5]&7u;s->stream_buffered=get16(p+20);s->stream_pending=get16(p+22);s->stream_generation=gen;
        s->telemetry_us=s->started_us;s->telemetry_source_head=s->source_head;s->telemetry_valid=1;s->have_stream_generation=1;
    }
    if(s->state==S10_TX_OPENING&&wirestate==2)s->state=S10_TX_PLAY;
    if((p[5]&128u)&&s->state==S10_TX_PLAY&&(s->stream_state==3||s->stream_state==4||generation_changed)){
        /* Stage6 underrun FADE/DRAIN ends this media generation. Commit the
         * validated ACK prefix above, then discard the remaining source and
         * enter an explicit STOP barrier. Recovery requires a NEW epoch. */
        s->unexpected_stream_ends++;
        if(generation_changed)s->unexpected_generation_changes++;
        return s10_pcm_tx_stop(s,s->epoch);
    }
    /* A STATUS begins after all previous SPI transactions completed. If its
     * last sequence is behind a sent packet, that packet was not accepted:
     * retry the identical earliest sequence now, rather than wait 20 ms. */
    if(op==STATUS)for(unsigned i=0;i<2;i++)if(s->bank[i].state==WAIT_ACK&&s->bank[i].sequence>ack)s->bank[i].state=READY;
    if(s->state==S10_TX_CLOSING&&wirestate==0)s->state=S10_TX_CLOSED;
    return 0;
}
int s10_pcm_tx_complete(s10_pcm_tx *s,uint64_t ticket,int success,uint64_t now){
    if(!s)return S10_TX_ARGUMENT;
    if(!s->dma_active||ticket!=s->ticket){s->stale_completions++;return S10_TX_STALE;}
    unsigned slot=s->dma_slot,op=s->dma_op;s->dma_active=0;s->transfers++;
    if(slot<2&&s->bank[slot].state==CANCELED){s->bank[slot].state=EMPTY;s->stale_completions++;return S10_TX_STALE;}
    if(s->state==S10_TX_CLOSING&&op!=STOP){s->stale_completions++;return S10_TX_STALE;}
    if(!success){s->failures++;if(slot<2)s->bank[slot].state=READY;s->credit=0;return S10_TX_PROTOCOL;}
    if(slot<2)s->bank[slot].state=WAIT_ACK;
    if(op==STATUS){s->last_status_us=now;s->data_after_status=0;}
    return accept_status(s,slot<2?s->bank[slot].rx+32:s->control_rx+32,op,slot);
}
size_t s10_pcm_tx_unsent(const s10_pcm_tx *s){return s&&s->count>=s->reserved?s->count-s->reserved:0;}
int s10_pcm_tx_conserved(const s10_pcm_tx *s){
    if(!s||s->count>4096||s->reserved>s->count||s->ingressed-s->committed-s->discarded!=s->count)return 0;
    unsigned reserved=0;for(unsigned i=0;i<2;i++)if(s->bank[i].state==READY||s->bank[i].state==WAIT_ACK)reserved+=s->bank[i].pairs;
    return reserved==s->reserved;
}
