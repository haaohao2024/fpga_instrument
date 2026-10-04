#include "s10_sd_admission.h"
#include <string.h>
void s10_sd_admission_init(s10_sd_admission *s,uint64_t epoch){memset(s,0,sizeof *s);s->epoch=epoch;}
uint32_t s10_sd_admission_rolling(const s10_sd_admission *s,uint64_t now){
    uint64_t lower=now>S10_SD_WINDOW_US?now-S10_SD_WINDOW_US:0,total=0;
    for(unsigned i=0;i<s->count;i++){const s10_sd_interval *p=&s->history[(s->head+i)%S10_SD_HISTORY];uint64_t a=p->start>lower?p->start:lower,b=p->end<now?p->end:now;if(b>a)total+=b-a;}
    if(s->active){uint64_t a=s->started_us>lower?s->started_us:lower;if(now>a)total+=now-a;}
    return total>UINT32_MAX?UINT32_MAX:(uint32_t)total;
}
static void prune(s10_sd_admission *s,uint64_t now){uint64_t lower=now>S10_SD_WINDOW_US?now-S10_SD_WINDOW_US:0;while(s->count&&s->history[s->head].end<=lower){s->head=(uint8_t)((s->head+1)%S10_SD_HISTORY);s->count--;}}
int s10_sd_admission_check(s10_sd_admission *s,uint64_t now){
    if(s->fault)return S10_SD_FAULT;
    if((s->active&&(now<s->started_us||now-s->started_us>S10_SD_MAX_US))||
       (s->need_refill&&(now<s->finished_us||now-s->finished_us>1000))){s->fault=1;s->violations++;return S10_SD_FAULT;}
    return 0;
}
int s10_sd_admission_begin(s10_sd_admission *s,s10_pcm_tx *tx,uint64_t now,int control){
    if(!s||!tx)return S10_SD_FAULT;
    s10_pcm_tx_sd_request(tx,0);
    if(s10_sd_admission_check(s,now))return S10_SD_FAULT;
    if(s->active||s->need_refill){s->denied_busy++;return S10_SD_BUSY;}
    if(control){s->denied_control++;return S10_SD_CONTROL;}
    prune(s,now);uint32_t occupied=s10_sd_admission_rolling(s,now);
    if(occupied>S10_SD_BUDGET_US-S10_SD_MAX_US||s->count==S10_SD_HISTORY){s->denied_budget++;return S10_SD_BUDGET;}
    if(tx->epoch==s->epoch&&tx->state==S10_TX_PLAY)s10_pcm_tx_sd_request(tx,1);
    if(tx->dma_active){s->denied_busy++;return S10_SD_BUSY;}
    if(tx->epoch!=s->epoch||tx->state!=S10_TX_PLAY||!tx->telemetry_valid||now<tx->telemetry_us||tx->stream_state!=2){s->denied_stock++;return S10_SD_STOCK;}
    uint64_t age=now-tx->telemetry_us;
    /* ceil(age * 48000 * 1.001 / 1e6), with overflow-safe rejection. */
    if(age>UINT64_MAX/48048u){s->denied_stock++;return S10_SD_STOCK;}
    uint64_t scaled=age*48048u;
    uint64_t used=scaled/1000000u+(scaled%1000000u!=0);
    if(used>tx->stream_buffered||tx->stream_buffered-used<768||s10_pcm_tx_unsent(tx)<512){s->denied_stock++;return S10_SD_STOCK;}
    s10_pcm_tx_sd_request(tx,0);
    s->active=1;s->started_us=now;return 0;
}
int s10_sd_admission_end(s10_sd_admission *s,s10_pcm_tx *tx,uint64_t now){
    if(!s||!tx||!s->active||now<s->started_us)return S10_SD_FAULT;
    uint64_t duration=now-s->started_us;s->active=0;
    unsigned at=(s->head+s->count)%S10_SD_HISTORY;s->history[at].start=s->started_us;s->history[at].end=now;s->count++;
    s->transactions++;s->occupied_us+=duration;s->finished_us=now;s->need_refill=1;
    if(duration>s->worst_us)s->worst_us=duration>UINT32_MAX?UINT32_MAX:(uint32_t)duration;
    uint32_t rolling=s10_sd_admission_rolling(s,now);if(rolling>s->max_rolling_us)s->max_rolling_us=rolling;
    if(duration>S10_SD_MAX_US||rolling>S10_SD_BUDGET_US){s->fault=1;s->violations++;return S10_SD_FAULT;}
    s10_pcm_tx_refill(tx);return 0;
}
int s10_sd_admission_pcm_started(s10_sd_admission *s,uint64_t now,unsigned pairs){
    if(!s||!pairs)return S10_SD_FAULT;
    if(s10_sd_admission_check(s,now))return S10_SD_FAULT;
    if(s->active)return S10_SD_BUSY;
    if(s->need_refill)s->need_refill=0;
    return 0;
}
