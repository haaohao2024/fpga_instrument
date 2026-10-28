#include "audio_timebase.h"
#include "s9_score_check.h"
#include "s9_protocol.h"
#include <string.h>
static int zero(const uint8_t *p,unsigned n){while(n--)if(*p++)return 0;return 1;}
int s9_score_header(s9_score_check *s,const uint8_t p[512],uint32_t bytes){
 memset(s,0,sizeof *s);
 uint32_t n=s9_get32(p+12);
 if(memcmp(p,"S7EV",4)||s9_get32(p+4)!=1||!audio_file_rate(s9_get32(p+8))||!n||n>1000000||
    s9_get32(p+24)>1||!zero(p+28,480)||s9_crc32(p,508)!=s9_get32(p+508)||
    bytes!=(1+(n+29)/30)*512)return S9_E_FORMAT;
 s->rate=s9_get32(p+8);s->records=n;s->end_time=s9_get64(p+16);s->next_page=1;s->closed=1;s->initialized=1;return 0;
}
int s9_score_page(s9_score_check *s,const uint8_t p[512]){
 if(!s->initialized||s->ended||s9_get32(p)!=s->next_page||!zero(p+6,10)||s9_crc32(p,508)!=s9_get32(p+508))return S9_E_FORMAT;
 unsigned n=s9_get16(p+4),expected=s->records-s->seen;if(expected>30)expected=30;
 if(!n||n!=expected||!zero(p+16+n*16,508-16-n*16))return S9_E_FORMAT;
 for(unsigned i=0;i<n;i++){
  const uint8_t *r=p+16+i*16;uint64_t t=s9_get64(r);unsigned op=r[8],key=r[9],note=r[10],value=r[11];uint32_t flags=s9_get32(r+12);
  if(flags>1||t>s->end_time||s->ended)return S9_E_FORMAT;
  if(s->seen){
   if(t<s->last_time||(t==s->last_time&&s->closed)||(t!=s->last_time&&!s->closed))return S9_E_FORMAT;
   if(t!=s->last_time)s->group=0;
  }
  if(++s->group>64)return S9_E_RANGE;
  while(s->recent_count&&t-s->recent[s->recent_head]>=s->rate/10u){s->recent_head=(s->recent_head+1)&127;s->recent_count--;}
  if(s->recent_count==128)return S9_E_RANGE;
  s->recent[(s->recent_head+s->recent_count++)&127]=t;
  if(op==1){
   if(key>=32||note>127||!value||(s->held&(1u<<key)))return S9_E_FORMAT;
   s->held|=1u<<key;
  }else if(op==2||op==3){
   if(key>=32||note>127||!(s->held&(1u<<key))||(op==2&&(note||value)))return S9_E_FORMAT;
   if(op==2)s->held&=~(1u<<key);
  }else if(op==4){
   if(key||note||value||flags!=1||s->seen+1!=s->records||t!=s->end_time)return S9_E_FORMAT;
   s->ended=1;
  }else return S9_E_FORMAT;
  s->last_time=t;s->closed=(uint8_t)flags;s->seen++;
 }
 s->next_page++;return 0;
}
int s9_score_finish(const s9_score_check *s){return s->initialized&&s->ended&&s->closed&&s->seen==s->records?0:S9_E_FORMAT;}
