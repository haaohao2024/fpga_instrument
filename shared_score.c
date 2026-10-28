#include "audio_timebase.h"
#include "shared_score.h"
#include "s9_protocol.h"
#include <string.h>
shared_score shared_score_stream;
void ss_init(void){memset(&shared_score_stream,0,sizeof shared_score_stream);shared_score_stream.file_rate=INSTRUMENT_AUDIO_HZ;}
void ss_file_reset(uint32_t records,uint64_t end,unsigned mode,const ss_profile *p){
 shared_score *s=&shared_score_stream;s->ready=0;s->write=s->released=0;s->records=records;s->end_time=end;s->mode=(uint8_t)mode;s->profile=*p;s->file_error=0;s->reload=0;
}
int ss_file_capacity(void){shared_score *s=&shared_score_stream;return __atomic_load_n(&s->write,__ATOMIC_ACQUIRE)-__atomic_load_n(&s->released,__ATOMIC_ACQUIRE)<32;}
int ss_file_push(const uint8_t p[512]){
 shared_score *s=&shared_score_stream;uint32_t w=s->write;
 if(!ss_file_capacity())return S9_E_BUSY;
 if(!s9_get16(p+4)||s9_get16(p+4)>30||s9_get32(p+508)!=s9_crc32(p,508))return S9_E_FORMAT;
 memcpy(s->memory.page[w&31],p,512);__atomic_store_n(&s->write,w+1,__ATOMIC_RELEASE);return 0;
}
void ss_file_ready(void){__atomic_store_n(&shared_score_stream.ready,1,__ATOMIC_RELEASE);}
int ss_command(unsigned cmd){
 shared_score *s=&shared_score_stream;
 if(cmd!=1&&cmd!=3&&cmd!=4&&cmd!=5&&cmd!=6)return S9_E_RANGE;
 if(s->command_done)return S9_E_BUSY;
 /* Exactly one file-task producer; protocol only retires this mailbox.
  * A subsequent command is posted only after ss_completion was consumed. */
 if(__atomic_load_n(&s->command,__ATOMIC_ACQUIRE))return S9_E_BUSY;
 __atomic_store_n(&s->command,(uint8_t)cmd,__ATOMIC_RELEASE);return 0;
}
int ss_completion(int *error){shared_score *s=&shared_score_stream;if(!__atomic_load_n(&s->command_done,__ATOMIC_ACQUIRE))return 0;*error=s->completion;s->command_done=0;return 1;}
void ss_complete(int error){shared_score *s=&shared_score_stream;s->completion=error;s->command=0;__atomic_store_n(&s->command_done,1,__ATOMIC_RELEASE);}
static int normalize(ss_cursor *c){
 shared_score *s=&shared_score_stream;
 if(c->page==__atomic_load_n(&s->write,__ATOMIC_ACQUIRE))return 0;
 unsigned n=s9_get16(s->memory.page[c->page&31]+4);
 if(c->index>=n){c->page++;c->index=0;if(c->page==__atomic_load_n(&s->write,__ATOMIC_ACQUIRE))return 0;}
 return 1;
}
int ss_peek(ss_cursor *c,uint64_t through,ss_event *e){
 if(!c->running)return 0;
 if(c->resume_mask){
  unsigned k=0;while(!(c->resume_mask&(1u<<k)))k++;
  if(c->resume_at>through)return 0;
  if(c->token_counter>=INT64_MAX)return S9_E_SEQUENCE;
  *e=(ss_event){c->resume_at,{0x11000000u|k<<16|(uint32_t)c->note[k]<<9|(uint32_t)c->pressure[k]<<1,c->token_counter+1},1,(uint8_t)k,c->note[k],c->pressure[k],1};return 1;
 }
 if(!normalize(c))return 0;
 const uint8_t *r=shared_score_stream.memory.page[c->page&31]+16+c->index*16;
 uint64_t t;if(audio_file_time(s9_get64(r),shared_score_stream.file_rate,&t))return S9_E_RANGE;if(t>UINT64_MAX-c->origin)return S9_E_RANGE;t+=c->origin;if(t>through)return 0;
 unsigned kind=r[8],key=r[9],note=r[10],pressure=r[11];
 if(kind==4){*e=(ss_event){t,{0,0},4,0,0,0,0};return 1;}
 if(kind<1||kind>3||key>=32)return S9_E_FORMAT;
 uint64_t token=c->key_token[key];if(kind==1){if(c->token_counter>=INT64_MAX)return S9_E_SEQUENCE;token=c->token_counter+1;}
 if(!token)return S9_E_SEQUENCE;
 *e=(ss_event){t,{0x10000000u|kind<<24|key<<16|note<<9|pressure<<1,token},(uint8_t)kind,(uint8_t)key,(uint8_t)note,(uint8_t)pressure,0};return 1;
}
int ss_take(ss_cursor *c,const ss_event *e){
 unsigned k=e->key;
 if(e->kind==1){c->token_counter=e->item.token;c->key_token[k]=e->item.token;c->held|=1u<<k;c->note[k]=e->note;c->pressure[k]=e->pressure;}
 else if(e->kind==2)c->held&=~(1u<<k);
 else if(e->kind==3){c->note[k]=e->note;c->pressure[k]=e->pressure;}
 else if(e->kind==4)c->running=0;
 if(e->resume)c->resume_mask&=~(1u<<k);else{c->index++;c->seen++;normalize(c);}
 return 0;
}
void ss_commit(const ss_cursor *c){__atomic_store_n(&shared_score_stream.released,c->page,__ATOMIC_RELEASE);}
void ss_profile_group(ss_profile *p,uint64_t at,unsigned events,unsigned *head,unsigned *count){
 ss_group *g=shared_score_stream.memory.probe;
 while(*count&&at-g[*head].at>=AUDIO_MS(100)){*head=(*head+1)&127;(*count)--;}
 unsigned index=(*head+*count)&127;g[index]=(ss_group){at,(uint16_t)events,(uint16_t)((events+8)/9)};(*count)++;
 uint32_t e48=0,g48=0,r48=0,r960=0,r4800=0;
 for(unsigned i=0;i<*count;i++){const ss_group *q=&g[(*head+i)&127];uint64_t age=at-q->at;r4800+=q->rows;if(age<AUDIO_MS(20))r960+=q->rows;if(age<AUDIO_MS(1)){e48+=q->events;r48+=q->rows;g48++;}}
 if(e48>p->events48)p->events48=e48;
 if(g48>p->groups48)p->groups48=g48;
 if(r48>p->rows48)p->rows48=r48;
 if(r960>p->rows960)p->rows960=r960;
 if(r4800>p->rows4800)p->rows4800=r4800;
}
