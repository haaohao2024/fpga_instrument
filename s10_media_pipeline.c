#include "s10_media_pipeline.h"
#include <string.h>

static void lock(s10_media_pipeline *p){p->binding.lock(p->binding.user);}
static void unlock(s10_media_pipeline *p){p->binding.unlock(p->binding.user);}
static uint16_t be16(const uint8_t *b){return (uint16_t)(((uint16_t)b[0]<<8)|b[1]);}
static uint32_t be32(const uint8_t *b){return ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3];}
static int running(const s10_media_pipeline *p)
{return p->state==S10_MEDIA_OPENING||p->state==S10_MEDIA_PLAY;}
static void close_locked(s10_media_pipeline *p,int reason)
{
    if(p->state==S10_MEDIA_CLOSED||p->state==S10_MEDIA_CLOSING)return;
    if(reason){p->last_error=reason;++p->errors;}
    if(p->generation!=UINT64_MAX)++p->generation;
    else {p->last_error=S10_MEDIA_EXHAUSTED;++p->errors;}
    p->state=S10_MEDIA_CLOSING;p->worker_clean=0;p->bus_stop_sent=0;++p->stops;
    for(unsigned i=0;i<S10_MEDIA_PCM_SLOTS;i++)if(p->pcm[i].ready){
        p->discarded_pairs+=p->pcm[i].pairs;p->pcm[i].ready=0;p->pcm[i].pairs=0;
    }
    p->pcm_count=0;p->pcm_head=0;
}
static int fail(s10_media_pipeline *p,int reason)
{lock(p);close_locked(p,reason);unlock(p);return reason;}
int s10_media_init(s10_media_pipeline *p,const s10_media_binding *b)
{
    if(!p||!b||!b->lock||!b->unlock||!b->active||!b->claim||!b->valid||!b->release)return S10_MEDIA_ARGUMENT;
    memset(p,0,sizeof(*p));p->binding=*b;p->initialized=1;p->worker_clean=1;
    return S10_MEDIA_OK;
}
int s10_media_start(s10_media_pipeline *p,uint64_t epoch,uint32_t rate)
{
    if(!p||!p->initialized||!epoch||(rate!=0&&rate!=44100&&rate!=48000))return S10_MEDIA_ARGUMENT;
    lock(p);
    if(p->state!=S10_MEDIA_CLOSED){unlock(p);return S10_MEDIA_BUSY;}
    if(epoch<=p->last_epoch){unlock(p);return S10_MEDIA_STALE;}
    if(p->generation==UINT64_MAX){unlock(p);return S10_MEDIA_EXHAUSTED;}
    p->epoch=epoch;p->last_epoch=epoch;p->rate=rate;++p->generation;
    p->state=S10_MEDIA_OPENING;p->worker_clean=0;p->bus_opened=0;p->bus_stop_sent=0;p->last_error=0;
    unlock(p);return S10_MEDIA_OK;
}
int s10_media_stop(s10_media_pipeline *p,uint64_t epoch,int reason)
{
    if(!p||!p->initialized)return S10_MEDIA_ARGUMENT;
    lock(p);
    if(epoch!=p->epoch){unlock(p);return S10_MEDIA_STALE;}
    close_locked(p,reason);unlock(p);return S10_MEDIA_OK;
}
static int valid_locked(s10_media_pipeline *p,uint64_t generation)
{
    return running(p)&&p->generation==generation&&p->binding.active(p->binding.user,p->epoch)>0&&
        (!p->have_claim||p->binding.valid(p->binding.user,p->claimed.ticket,p->claimed.epoch)>0);
}
static void invalid_locked(s10_media_pipeline *p,uint64_t generation)
{if(running(p)&&p->generation==generation)close_locked(p,S10_MEDIA_SOURCE);}
static int release_locked(s10_media_pipeline *p)
{
    if(!p->have_claim)return 1;
    int ok=p->binding.release(p->binding.user,p->claimed.ticket,p->claimed.epoch);
    if(ok>0){++p->released_sdus;p->have_claim=0;memset(&p->claimed,0,sizeof(p->claimed));}
    else close_locked(p,S10_MEDIA_SOURCE);
    return ok>0;
}
/* Called only by the worker. Reset cannot race a different worker. */
static int synchronize_worker(s10_media_pipeline *p)
{
    uint64_t generation,epoch;uint32_t rate;int active;
    lock(p);generation=p->generation;epoch=p->epoch;rate=p->rate;active=running(p);
    if(p->worker_generation==generation&&!(p->state==S10_MEDIA_CLOSING&&!p->worker_clean)){unlock(p);return 0;}
    if(!release_locked(p)){unlock(p);return S10_MEDIA_SOURCE;}
    p->discarded_pairs+=p->normal_count;p->normal_count=0;
    unlock(p);
    s10_codec_stop(&p->codec);s10_fir_reset(&p->fir);
    p->decoded_count=p->decoded_offset=0;p->frame_bytes=p->fragment_bytes=0;
    p->packet_offset=0;p->frames_remaining=0;p->fragment_remaining=0;
    p->fragmented=0;p->frame_ready=0;p->have_rtp=0;
    int r=active&&rate?s10_codec_start(&p->codec,epoch,rate):S10_CODEC_OK;
    lock(p);
    if(p->generation==generation){
        p->worker_generation=generation;p->worker_clean=(uint8_t)!active;
        if(r)close_locked(p,S10_MEDIA_DECODE);
    }
    unlock(p);return r?S10_MEDIA_DECODE:1;
}
static int publish_normal(s10_media_pipeline *p,uint64_t generation)
{
    lock(p);
    if(!p->normal_count){unlock(p);return 0;}
    if(!valid_locked(p,generation)){
        p->discarded_pairs+=p->normal_count;p->normal_count=0;++p->stale_results;
        if(running(p)&&p->generation==generation)close_locked(p,S10_MEDIA_SOURCE);
        unlock(p);return S10_MEDIA_STALE;
    }
    if(p->pcm_count==S10_MEDIA_PCM_SLOTS){unlock(p);return S10_MEDIA_BUSY;}
    unsigned at=(p->pcm_head+p->pcm_count)%S10_MEDIA_PCM_SLOTS;
    s10_media_pcm_slot *slot=&p->pcm[at];
    memcpy(slot->samples,p->normalized,p->normal_count*4u);
    slot->epoch=p->epoch;slot->generation=generation;slot->pairs=p->normal_count;slot->ready=1;
    p->published_pairs+=p->normal_count;p->normal_count=0;++p->pcm_count;
    unlock(p);return 1;
}
static unsigned sbc_length(const uint8_t *b,unsigned n);
static int claim_packet(s10_media_pipeline *p,uint64_t generation)
{
    s10_media_sdu sdu={0};int got;
    lock(p);
    if(!valid_locked(p,generation)){invalid_locked(p,generation);unlock(p);return S10_MEDIA_STALE;}
    got=p->binding.claim(p->binding.user,&sdu);
    if(!got){unlock(p);return 0;}
    if(got<0){close_locked(p,S10_MEDIA_SOURCE);unlock(p);return S10_MEDIA_SOURCE;}
    if(!sdu.bytes||!sdu.ticket||sdu.epoch!=p->epoch||sdu.length>S10_MEDIA_SDU_LIMIT){
        (void)p->binding.release(p->binding.user,sdu.ticket,sdu.epoch);
        close_locked(p,S10_MEDIA_SOURCE);unlock(p);return S10_MEDIA_SOURCE;
    }
    p->claimed=sdu;p->have_claim=1;++p->claimed_sdus;unlock(p);
    const uint8_t *b=sdu.bytes;unsigned n=sdu.length;
    if(n<13||(b[0]>>6)!=2||(b[0]&0x30))return fail(p,S10_MEDIA_FORMAT);
    unsigned header=12u+4u*(b[0]&15u);
    if(n<=header)return fail(p,S10_MEDIA_FORMAT);
    uint16_t seq=be16(b+2);uint32_t ts=be32(b+4),ssrc=be32(b+8);
    uint8_t payload=b[1]&127u,fh=b[header],count=fh&15u;
    if(!count||(fh&0x10))return fail(p,S10_MEDIA_FORMAT);
    if(p->have_rtp){
        if(seq!=p->expected_sequence||ssrc!=p->ssrc||payload!=p->payload_type)return fail(p,S10_MEDIA_SEQUENCE);
        if(ts!=(p->fragmented?p->fragment_timestamp:p->expected_timestamp))return fail(p,S10_MEDIA_SEQUENCE);
    }else{p->ssrc=ssrc;p->payload_type=payload;p->expected_timestamp=ts;p->have_rtp=1;}
    p->expected_sequence=(uint16_t)(seq+1u);p->packet_offset=(uint16_t)(header+1u);
    if(!(fh&0x80)){
        if((fh&0x60)||p->fragmented)return fail(p,S10_MEDIA_FORMAT);
        /* Validate the entire declared frame group before decoding its first
         * frame. A wrong count/truncated last frame must not leak a prefix. */
        unsigned at=p->packet_offset;
        for(unsigned i=0;i<count;i++){
            unsigned bytes=sbc_length(b+at,n-at);
            if(!bytes||bytes>n-at)return fail(p,S10_MEDIA_FORMAT);
            at+=bytes;
        }
        if(at!=n)return fail(p,S10_MEDIA_FORMAT);
        p->frames_remaining=count;return 1;
    }
    if(fh&0x40){
        if(p->fragmented||(fh&0x20)||count<2)return fail(p,S10_MEDIA_FORMAT);
        p->fragmented=1;p->fragment_bytes=0;p->fragment_remaining=count;p->fragment_timestamp=ts;
    }else if(!p->fragmented||count+1u!=p->fragment_remaining)return fail(p,S10_MEDIA_SEQUENCE);
    p->fragment_remaining=count;
    unsigned bytes=n-p->packet_offset;
    if(!bytes||bytes>S10_SBC_MAX_FRAME-p->fragment_bytes)return fail(p,S10_MEDIA_FORMAT);
    memcpy(p->frame+p->fragment_bytes,b+p->packet_offset,bytes);p->fragment_bytes=(uint16_t)(p->fragment_bytes+bytes);
    if((count==1)!=!!(fh&0x20))return fail(p,S10_MEDIA_FORMAT);
    lock(p);
    if(!valid_locked(p,generation)){invalid_locked(p,generation);unlock(p);return S10_MEDIA_STALE;}
    if(!release_locked(p)){unlock(p);return S10_MEDIA_SOURCE;}unlock(p);
    if(fh&0x20){p->frame_bytes=p->fragment_bytes;p->frame_ready=1;p->fragmented=0;p->fragment_bytes=0;}
    return 1;
}
static unsigned sbc_length(const uint8_t *b,unsigned n)
{
    if(n<4||b[0]!=0x9c)return 0;
    unsigned blocks=4u*(((b[1]>>4)&3u)+1u),bands=(b[1]&1u)?8u:4u;
    unsigned mode=(b[1]>>2)&3u,pool=b[2],channels=mode?2u:1u;
    if(pool<2||pool>250||pool>bands*(mode<2?16u:32u))return 0;
    unsigned bits=blocks*pool*(mode<2?channels:1u)+(mode==3?bands:0u);
    unsigned length=4u+bands*channels/2u+(bits+7u)/8u;
    return length<=S10_SBC_MAX_FRAME?length:0;
}
static int obtain_frame(s10_media_pipeline *p,uint64_t generation)
{
    if(p->frame_ready){
        if(sbc_length(p->frame,p->frame_bytes)!=p->frame_bytes)return fail(p,S10_MEDIA_FORMAT);
        return 1;
    }
    if(!p->have_claim){int r=claim_packet(p,generation);if(r<=0)return r;if(p->frame_ready)return obtain_frame(p,generation);if(!p->have_claim)return 0;}
    unsigned left=p->claimed.length-p->packet_offset;
    unsigned bytes=sbc_length(p->claimed.bytes+p->packet_offset,left);
    if(!p->frames_remaining||!bytes||bytes>left)return fail(p,S10_MEDIA_FORMAT);
    if(p->frames_remaining==1&&bytes!=left)return fail(p,S10_MEDIA_FORMAT);
    memcpy(p->frame,p->claimed.bytes+p->packet_offset,bytes);p->frame_bytes=(uint16_t)bytes;
    p->packet_offset=(uint16_t)(p->packet_offset+bytes);--p->frames_remaining;p->frame_ready=1;
    return 1;
}
int s10_media_worker_step(s10_media_pipeline *p)
{
    if(!p||!p->initialized)return S10_MEDIA_ARGUMENT;
    int synced=synchronize_worker(p);if(synced)return synced;
    lock(p);uint64_t generation=p->generation,epoch=p->epoch;int active=running(p);
    unsigned full=p->pcm_count==S10_MEDIA_PCM_SLOTS;unlock(p);
    if(!active)return 0;
    if(p->normal_count)return publish_normal(p,generation);
    if(full)return S10_MEDIA_BUSY;
    if(p->decoded_offset==p->decoded_count){
        int r=obtain_frame(p,generation);if(r<=0)return r;
        if(!p->codec.active){
            unsigned frequency=p->frame[1]>>6;
            uint32_t rate=frequency==2u?44100u:frequency==3u?48000u:0u;
            if(!rate)return fail(p,S10_MEDIA_FORMAT);
            if(s10_codec_start(&p->codec,epoch,rate))return fail(p,S10_MEDIA_DECODE);
            lock(p);
            if(!valid_locked(p,generation)){invalid_locked(p,generation);unlock(p);return S10_MEDIA_STALE;}
            p->rate=rate;unlock(p);
        }
        size_t made=0;r=s10_codec_frame(&p->codec,epoch,p->frame,p->frame_bytes,&p->decoded[0][0],S10_SBC_MAX_PAIRS,&made);
        if(r)return fail(p,r==S10_CODEC_FORMAT?S10_MEDIA_FORMAT:S10_MEDIA_DECODE);
#ifdef S10_MEDIA_TESTING
        extern void s10_media_test_checkpoint(s10_media_pipeline *,unsigned);
        s10_media_test_checkpoint(p,1u);
#endif
        lock(p);p->decoded_pairs+=made;++p->frames;
        if(!valid_locked(p,generation)){++p->stale_results;invalid_locked(p,generation);unlock(p);return S10_MEDIA_STALE;}
        p->decoded_count=(uint16_t)made;p->decoded_offset=0;
        p->expected_timestamp+=(uint32_t)made;p->frame_ready=0;
        if(p->have_claim&&!p->frames_remaining){if(!release_locked(p)){unlock(p);return S10_MEDIA_SOURCE;}}
        unlock(p);
    }
    size_t made,taken=0;unsigned available=p->decoded_count-p->decoded_offset;
    if(p->rate==48000){made=available;memcpy(p->normalized,p->decoded+p->decoded_offset,made*4u);taken=made;}
    else made=s10_fir_process(&p->fir,&p->decoded[p->decoded_offset][0],available,&p->normalized[0][0],S10_MEDIA_PCM_PAIRS,&taken);
    p->decoded_offset=(uint16_t)(p->decoded_offset+taken);
    lock(p);p->normal_count=(uint16_t)made;p->normalized_pairs+=made;
    if(!valid_locked(p,generation)){p->discarded_pairs+=made;p->normal_count=0;++p->stale_results;invalid_locked(p,generation);unlock(p);return S10_MEDIA_STALE;}
    unlock(p);return made?publish_normal(p,generation):0;
}
int s10_media_bus_step(s10_media_pipeline *p,s10_pcm_tx *tx)
{
    if(!p||!p->initialized||!tx)return S10_MEDIA_ARGUMENT;
    lock(p);int progress=0;
    if(running(p)){
        if(!p->bus_opened){
            if(tx->state!=S10_TX_CLOSED){unlock(p);return S10_MEDIA_BUSY;}
            if(s10_pcm_tx_open(tx,p->epoch,1)){close_locked(p,S10_MEDIA_TRANSPORT);unlock(p);return S10_MEDIA_TRANSPORT;}
            p->bus_opened=1;progress=1;
        }
        if(tx->epoch!=p->epoch){close_locked(p,S10_MEDIA_TRANSPORT);unlock(p);return S10_MEDIA_TRANSPORT;}
        if(tx->state==S10_TX_CLOSED||tx->state==S10_TX_CLOSING){close_locked(p,S10_MEDIA_TRANSPORT);}
        else {
            if(tx->state==S10_TX_PLAY)p->state=S10_MEDIA_PLAY;
            if(p->pcm_count){
                s10_media_pcm_slot *slot=&p->pcm[p->pcm_head];
                if(slot->epoch!=p->epoch||slot->generation!=p->generation){
                    close_locked(p,S10_MEDIA_STALE);unlock(p);return S10_MEDIA_STALE;
                }
                int r=s10_pcm_tx_enqueue(tx,slot->epoch,&slot->samples[0][0],slot->pairs);
                if(r==S10_TX_OK){p->bus_pairs+=slot->pairs;slot->ready=0;slot->pairs=0;p->pcm_head=(uint8_t)((p->pcm_head+1u)%S10_MEDIA_PCM_SLOTS);--p->pcm_count;progress=1;}
                else if(r!=S10_TX_BUSY){close_locked(p,S10_MEDIA_TRANSPORT);unlock(p);return S10_MEDIA_TRANSPORT;}
            }
        }
    }
    if(p->state==S10_MEDIA_CLOSING){
        if(tx->state!=S10_TX_CLOSED){
            if(tx->epoch!=p->epoch){unlock(p);return S10_MEDIA_TRANSPORT;}
            if(!p->bus_stop_sent){if(s10_pcm_tx_stop(tx,p->epoch)){unlock(p);return S10_MEDIA_TRANSPORT;}p->bus_stop_sent=1;progress=1;}
        }
        if(tx->state==S10_TX_CLOSED&&!tx->dma_active&&p->worker_clean&&p->worker_generation==p->generation&&!p->have_claim){p->state=S10_MEDIA_CLOSED;progress=1;}
    }
    unlock(p);return progress;
}
int s10_media_state(s10_media_pipeline *p,uint64_t *epoch,int *error)
{
    if(!p||!p->initialized)return S10_MEDIA_ARGUMENT;
    lock(p);int state=p->state;if(epoch)*epoch=p->epoch;if(error)*error=p->last_error;unlock(p);return state;
}
int s10_media_conserved(s10_media_pipeline *p)
{
    if(!p||!p->initialized)return 0;
    lock(p);uint64_t queued=0;unsigned slots=0;
    for(unsigned i=0;i<S10_MEDIA_PCM_SLOTS;i++)if(p->pcm[i].ready){queued+=p->pcm[i].pairs;++slots;}
    int ok=slots==p->pcm_count&&p->claimed_sdus==p->released_sdus+p->have_claim&&
        p->normalized_pairs==p->bus_pairs+p->discarded_pairs+queued+p->normal_count;
    unlock(p);return ok;
}
