/* Project-owned basic A2DP media ingress; the closed Profile stays unchanged.
 * Host observers are synchronous, bounded and never decode/send/wait. */
#include "s10_profile.h"
#include "profile_context.h"
#include "s10_host_observer.h"
#include "s10_runtime.h"
#include "FreeRTOS.h"
#include "task.h"
#include "bluetooth.h"
#include "conn.h"
#include "l2cap.h"
#include "a2dp.h"
#include "avrcp.h"
#include "net/buf.h"
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
extern int bt_avdtp_l2cap_recv(struct bt_l2cap_chan*,struct net_buf*);
extern int bt_avdtp_l2cap_media_stream_recv(struct bt_l2cap_chan*,struct net_buf*);
static struct pc_core core;
static s10_media_pipeline *pipe;
static struct bt_avdtp_stream *live_stream;
static struct ig_identity identity,deferred_identity;
static struct bt_avdtp_stream *deferred_stream;
static uint8_t deferred_alive;
static uint32_t next_connection=1;
static uint8_t prepared,enabled,alive,reserved;
static int last_error;
static uint32_t busy_starts,second_media,readonly_writes;
static void lock(void*u){(void)u;taskENTER_CRITICAL();}
static void unlock(void*u){(void)u;taskEXIT_CRITICAL();}
static int active(void*u,uint64_t epoch){(void)u;return ig_active(&core.source,epoch);}
static int claim(void*u,s10_media_sdu*out){const struct ig_slot*slot;uint64_t ticket;(void)u;if(!ig_claim(&core.source,&ticket,&slot))return 0;out->ticket=ticket;out->epoch=slot->epoch;out->bytes=slot->data;out->length=slot->len;return 1;}
static int valid(void*u,uint64_t ticket,uint64_t epoch){(void)u;return ig_task_valid(&core.source,ticket,epoch);}
static int release(void*u,uint64_t ticket,uint64_t epoch){(void)u;return ig_release(&core.source,ticket,epoch);}
/* Called while the source lock is held: invalidate publication at the same
 * edge as accepted retirement. Cleanup, ticket release and TX/DMA draining
 * remain worker/bus responsibilities; this callback never waits. */
static void retire_pipeline_locked(void)
{
 const struct ig_transport *t=&core.source.transports[0];
 uint64_t epoch=0;int error=0;
 if(!t->retiring_epoch)return;
 int state=s10_media_state(pipe,&epoch,&error);
 if(epoch==t->retiring_epoch&&(state==S10_MEDIA_OPENING||state==S10_MEDIA_PLAY))
  (void)s10_media_stop(pipe,epoch,t->fault?S10_MEDIA_SOURCE:S10_MEDIA_OK);
}
static uintptr_t task_identity(void){return (uintptr_t)xTaskGetCurrentTaskHandle();}
static int media_channel(struct bt_l2cap_chan*chan){return chan&&chan->ops&&chan->ops->recv==bt_avdtp_l2cap_media_stream_recv;}
/* The closed A2DP profile advertises the sink SBC capability from this global
 * (bt_a2dp_init: bt_a2dp_set_sbc_codec_info() -> 0xFF,0xFF,2,53 = every rate).
 * Offer 48 kHz only, so the phone streams at the FPGA rate and the BL616 does
 * no 44.1k->48k resampling (measured: decode+resample could not keep real time). */
extern uint8_t sbc_info[4]; /* read by AVDTP GET_(ALL_)CAPABILITIES at request time */
void s10_profile_host_connected(struct bt_l2cap_chan*chan)
{struct ig_identity fresh;struct bt_avdtp_stream*stream;
 /* bt_a2dp_init() rewrites sbc_info after enable; every L2CAP connect (the AVDTP
  * signalling channel precedes GET_CAPABILITIES) re-applies the 48 kHz-only offer. */
 if(prepared&&enabled)sbc_info[0]=(uint8_t)(0x10u|(sbc_info[0]&0x0fu));
 if(!prepared||!enabled||!media_channel(chan))return;lock(0);
 if(alive&&identity.chan==(uintptr_t)chan&&identity.conn==(uintptr_t)chan->conn){unlock(0);return;}
 if(!next_connection){last_error=S10_MEDIA_EXHAUSTED;unlock(0);return;}
 fresh=(struct ig_identity){(uintptr_t)chan->conn,(uintptr_t)chan,next_connection++,((struct bt_l2cap_br_chan*)chan)->rx.cid};
 stream=(struct bt_avdtp_stream*)((uint8_t*)chan - offsetof(struct bt_avdtp_stream,chan));
 if(core.source.transports[0].attached){if(!alive&&!deferred_alive){deferred_identity=fresh;deferred_stream=stream;deferred_alive=1;}else second_media++;last_error=S10_MEDIA_BUSY;unlock(0);return;}
 identity=fresh;if(!ig_attach(&core.source,identity)){last_error=S10_MEDIA_SOURCE;unlock(0);return;}live_stream=stream;alive=1;unlock(0);}
void s10_profile_host_disconnected(struct bt_l2cap_chan*chan)
{if(!prepared)return;lock(0);if(deferred_alive&&deferred_identity.chan==(uintptr_t)chan){deferred_alive=0;deferred_stream=0;}if(alive&&identity.chan==(uintptr_t)chan){/* Never dereference this object again after original disconnected callback. */alive=0;live_stream=0;ig_retire(&core.source,identity,IG_NONE);retire_pipeline_locked();}unlock(0);}
uint32_t s10_profile_host_rx_before(struct bt_conn*conn,struct bt_l2cap_chan*chan,uint16_t cid,struct net_buf*buf)
{uint32_t token=0;if(!prepared||!enabled||!chan||!chan->ops||!buf)return 0;lock(0);if(alive&&live_stream&&identity.conn==(uintptr_t)conn){if(media_channel(chan)&&identity.chan==(uintptr_t)chan&&identity.cid==cid)token=pc_begin(&core,task_identity(),identity,PC_MEDIA,(uint8_t)live_stream->state,buf->data,buf->len);else if(chan->ops->recv==bt_avdtp_l2cap_recv)token=pc_begin(&core,task_identity(),identity,PC_SIGNAL,(uint8_t)live_stream->state,buf->data,buf->len);}if(!token&&deferred_alive&&deferred_identity.conn==(uintptr_t)conn)last_error=S10_MEDIA_BUSY;
 if(core.source.transports[0].fault){last_error=S10_MEDIA_SOURCE;}retire_pipeline_locked();
 unlock(0);return token;}
struct s10_host_send_snapshot s10_profile_host_send_before(struct bt_l2cap_chan*chan,const uint8_t*data,uint16_t len)
{struct s10_host_send_snapshot out={0};struct pc_send s;if(!prepared||!enabled||!chan||!data)return out;lock(0);s=pc_send_before(&core,task_identity(),(uintptr_t)chan->conn,data,len);out.task=s.task;out.conn=s.identity.conn;out.serial=s.serial;out.header[0]=(uint8_t)((s.label<<4)|s.type);out.header[1]=s.signal;out.valid=s.valid;unlock(0);return out;}
void s10_profile_host_send_after(const struct s10_host_send_snapshot*out,int result)
{struct pc_send s;if(!prepared||!out||!out->valid)return;lock(0);s=(struct pc_send){out->task,identity,out->serial,(uint8_t)(out->header[0]>>4),(uint8_t)(out->header[1]&63),(uint8_t)(out->header[0]&3),1};s.identity.conn=out->conn;pc_send_after(&core,&s,result);unlock(0);}
static void profile_stream(uint8_t state){if(!prepared)return;lock(0);pc_callback(&core,task_identity(),state);unlock(0);}
static void profile_chain(struct bt_conn*conn,uint8_t state){if(!prepared)return;if(state==BT_A2DP_CHAIN_DISCONNECTED){lock(0);if(deferred_alive&&deferred_identity.conn==(uintptr_t)conn){deferred_alive=0;deferred_stream=0;}if(identity.conn==(uintptr_t)conn){alive=0;live_stream=0;ig_retire(&core.source,identity,IG_NONE);retire_pipeline_locked();}unlock(0);}}
static struct a2dp_callback callbacks={.chain=profile_chain,.stream=profile_stream};
void s10_profile_host_rx_after(uint32_t token)
{struct pc_rx*r=0;unsigned i;uintptr_t task=task_identity();int accepted;if(!token||!prepared)return;lock(0);for(i=0;i<PC_RX_CONTEXTS;i++)if(core.rx[i].active&&core.rx[i].serial==token&&core.rx[i].task==task){r=&core.rx[i];break;}if(!r){unlock(0);return;}
 if(!alive&&r->kind==PC_SIGNAL&&r->e.request_signal==IG_START)r->e.callback_state=0;
 if(r->kind==PC_SIGNAL&&r->e.request_signal==IG_START&&!core.source.transports[0].playing&&!core.source.transports[0].pending_start&&r->e.response_type==2&&r->e.send_result>=0&&r->e.callback_state==3&&(r->e.before_state==2||r->e.before_state==3)&&r->e.rx_task==r->e.send_task&&r->e.request_label==r->e.response_label&&r->e.request_signal==r->e.response_signal){if(s10_runtime_media_claim()!=0){busy_starts++;last_error=S10_MEDIA_BUSY;r->e.callback_state=0;}else reserved=1;}
 accepted=pc_end(&core,task,token);if(accepted&&r->e.request_signal==IG_START)last_error=0;if(core.source.transports[0].fault)last_error=S10_MEDIA_SOURCE;retire_pipeline_locked();unlock(0);}
/* Original closed Profile still reaches these read-only hooks. Raw data was
 * copied once before dispatch; there is no second decoder or data queue. */
void *sbc2pcm_player_open(void*parent,unsigned rate,unsigned channels,void*arg){(void)parent;(void)rate;(void)channels;(void)arg;return (void*)1;}
int sbc2pcm_player_write(void*handle,void*data,unsigned size){(void)handle;(void)data;(void)size;lock(0);readonly_writes++;unlock(0);return 0;}
int s10_profile_prepare(s10_media_pipeline*p)
{if(!p||prepared)return S10_MEDIA_ARGUMENT;pc_init(&core);pipe=p;next_connection=1;last_error=0;alive=reserved=enabled=deferred_alive=0;live_stream=deferred_stream=0;s10_media_binding b={0,lock,unlock,active,claim,valid,release};if(s10_media_init(pipe,&b)!=S10_MEDIA_OK)return S10_MEDIA_SOURCE;prepared=1;return 0;}
/* The locked Host initializes the built-in Sink SEP before bluetooth_ready.
 * Its GET_CAPS uses Profile-global SBC capabilities (all four rates). Do not
 * register a second SEP or claim endpoint.caps constrains that advertisement.
 * Project ingress accepts only complete 44.1/48k SBC frames; other rates
 * trigger the worker's explicit FORMAT/STOP path. */
/* Phone volume keys arrive as AVRCP SetAbsoluteVolume (the stack's TG already
 * advertises it, so the phone stops attenuating PCM itself). */
static void avrcp_volume(uint8_t vol){s10_media_volume=(uint8_t)(vol>127u?127u:vol);}
static struct avrcp_callback avrcp_callbacks={.abs_vol=avrcp_volume};
int s10_profile_enable(void)
{int e;if(!prepared||enabled)return S10_MEDIA_ARGUMENT;sbc_info[0]=(uint8_t)(0x10u|(sbc_info[0]&0x0fu));a2dp_cb_register(&callbacks);avrcp_cb_register(&avrcp_callbacks);e=bt_br_set_connectable(1);if(e&&e!=-EALREADY){last_error=S10_MEDIA_SOURCE;return e;}e=bt_br_set_discoverable(1);if(e&&e!=-EALREADY){last_error=S10_MEDIA_SOURCE;return e;}last_error=0;enabled=1;return 0;}
int s10_profile_step(void)
{struct ig_transport t;uint64_t epoch=0;int error=0,state;if(!prepared)return S10_MEDIA_ARGUMENT;lock(0);t=core.source.transports[0];unlock(0);state=s10_media_state(pipe,&epoch,&error);
 if((t.retiring_epoch||t.fault)&&state!=S10_MEDIA_CLOSED){s10_media_stop(pipe,epoch,t.fault?S10_MEDIA_SOURCE:S10_MEDIA_OK);/* Normal peer retirement is not a media fault. The worker must execute cleanup; STOP is not a timer/fence. */return s10_media_worker_step(pipe);}
 if(t.retiring_epoch&&state==S10_MEDIA_CLOSED){lock(0);ig_external_retire_done(&core.source,t.identity,t.retiring_epoch,t.retire_serial);int fenced=pc_fence(&core,t.identity);unlock(0);return fenced?1:0;}
 if(state==S10_MEDIA_CLOSING){if(t.playing){lock(0);last_error=error?error:S10_MEDIA_SOURCE;ig_retire(&core.source,t.identity,IG_CONTEXT);unlock(0);}return s10_media_worker_step(pipe);}
 if(t.playing&&state==S10_MEDIA_CLOSED){/* Same short lock keeps accepted source identity stable through start. */lock(0);if(!ig_active(&core.source,t.epoch)){unlock(0);return 0;}int e=s10_media_start(pipe,t.epoch,0);if(e!=S10_MEDIA_OK){last_error=e;ig_retire(&core.source,t.identity,IG_CONTEXT);}unlock(0);return 1;}
 if(t.playing&&(state==S10_MEDIA_OPENING||state==S10_MEDIA_PLAY)&&epoch==t.epoch)return s10_media_worker_step(pipe);
 if(state==S10_MEDIA_CLOSED){lock(0);t=core.source.transports[0];if(!t.playing&&!t.pending_start&&!t.retiring_epoch){if(!alive&&t.attached)ig_detach(&core.source,t.identity);if(deferred_alive&&!core.source.transports[0].attached){identity=deferred_identity;live_stream=deferred_stream;alive=1;deferred_alive=0;deferred_stream=0;ig_attach(&core.source,identity);}if(reserved){s10_runtime_media_release();reserved=0;}}unlock(0);}
 return 0;}
int s10_profile_busy(void){int b;lock(0);b=reserved||deferred_alive||core.source.transports[0].retiring_epoch||core.source.transports[0].pending_start;unlock(0);return b;}
int s10_profile_last_error(void){int e;lock(0);e=last_error;unlock(0);return e;}
int s10_profile_diag(char *text,unsigned size){
 const struct ig_core *s=&core.source;const struct ig_transport *t=&s->transports[0];
 lock(0);uint32_t v[14]={enabled,alive,t->attached,t->playing,t->pending_start,t->fault,s->copied,s->claimed,s->released,s->full_drops,s->accepted_starts,s->faults,busy_starts,second_media};int e=last_error;unlock(0);
 return snprintf(text,size,"A2DP_IN en=%lu alive=%lu att=%lu play=%lu pend=%lu fault=%lu copied=%lu claimed=%lu released=%lu full=%lu starts=%lu faults=%lu busy=%lu second=%lu err=%d",
  (unsigned long)v[0],(unsigned long)v[1],(unsigned long)v[2],(unsigned long)v[3],(unsigned long)v[4],(unsigned long)v[5],(unsigned long)v[6],(unsigned long)v[7],(unsigned long)v[8],(unsigned long)v[9],(unsigned long)v[10],(unsigned long)v[11],(unsigned long)v[12],(unsigned long)v[13],e);
}
