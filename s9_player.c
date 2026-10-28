#include "audio_timebase.h"
#include "s9_player.h"
#include "s9_protocol.h"
#include "s9_score_check.h"
#include "score_service.h"
#include "shared_score.h"
#include <string.h>
/* File owner only. The protocol task is the sole raw composer/producer. */
static s9_score_check check;
void s9_player_init(s9_player *s,uint64_t seed){memset(s,0,sizeof *s);s->epoch_cursor=seed;}
void s9_player_autostart(s9_player *s,uint32_t now){if(!s9_player_command(s,1,0,now))s->file_default_mode=1;}
int s9_player_command(s9_player *s,unsigned cmd,unsigned arg,uint32_t now){
 if(s->pending||s->command_done)return S9_E_BUSY;
 if((cmd!=1&&cmd!=3&&cmd!=4&&cmd!=5&&cmd!=6)||arg>3)return S9_E_RANGE;
 if((cmd==4&&shared_score_stream.state!=2)||(cmd==5&&shared_score_stream.state!=3))return S9_E_STATE;
 s->pending=1;s->command=(uint8_t)cmd;s->argument=(uint8_t)arg;s->command_started=now;s->starting=0;s->result=0;s->errors=0;s->file_default_mode=0;
 if(cmd==1||cmd==3||cmd==6)s->stop_confirmed=0;
 return 0;
}
static void finish(s9_player *s,int error){s->pending=0;s->command_done=1;s->result=error;s->starting=0;}
int s9_player_completion(s9_player *s,int *error){if(!s->command_done)return 0;*error=s->result;s->command_done=0;return 1;}
static int fill(s9_player *s){
 if(s->eof||!ss_file_capacity())return 0;
 int r=score_next(s->page,&s->sequence,s->epoch);if(r<0)return S9_E_IO;
 if(r==1){s->eof=1;return 0;}
 return ss_file_push(s->page);
}
static int prepare(s9_player *s){
 if(s->epoch_cursor==UINT64_MAX)return S9_E_SEQUENCE;
 s->epoch=++s->epoch_cursor;
 if(score_open(s->epoch))return S9_E_IO;
 int r=score_next(s->page,&s->sequence,s->epoch);if(r||s->sequence)return S9_E_IO;
 uint32_t records=s9_get32(s->page+12);uint64_t end=s9_get64(s->page+16);
 if(s9_score_header(&check,s->page,(1+(records+29)/30)*512))return S9_E_FORMAT;
 shared_score_stream.file_rate=check.rate;
 if(audio_file_time(end,check.rate,&end))return S9_E_RANGE;
 s->mode=s->file_default_mode?(uint8_t)score_default_mode():s->argument;
 ss_profile p={0};unsigned head=0,count=0,events=0;
 while((r=score_next(s->page,&s->sequence,s->epoch))==0){
  if(s9_score_page(&check,s->page))return S9_E_FORMAT;
  unsigned n=s9_get16(s->page+4);
  for(unsigned i=0;i<n;i++){const uint8_t *e=s->page+16+i*16;if(e[8]!=4)events++;
   if(s9_get32(e+12)&1u){if(events){uint64_t at;if(audio_file_time(s9_get64(e),check.rate,&at))return S9_E_RANGE;ss_profile_group(&p,at,events,&head,&count);}events=0;}
  }
 }
 if(r<0||s9_score_finish(&check))return S9_E_FORMAT;
 if(score_close()||score_open(s->epoch))return S9_E_IO;
 if(score_next(s->page,&s->sequence,s->epoch)||s->sequence)return S9_E_IO;
 ss_file_reset(records,end,s->mode,&p);s->eof=0;
 for(unsigned i=0;i<32&&!s->eof;i++){r=fill(s);if(r)return r;}
 ss_file_ready();return 0;
}
void s9_player_step(s9_player *s,uint32_t now){
 (void)now;s->status[7]=shared_score_stream.state;s->active=shared_score_stream.state!=0;
 if(!s->pending&&shared_score_stream.reload){shared_score_stream.reload=0;s->command_done=0;if(!s9_player_command(s,1,s->mode,now))s->file_default_mode=0;}
 if(s->pending&&!s->starting){
  int r=ss_command(s->command==1?3:s->command);if(r)return;s->starting=s->command==1?1:3;
 }
 int error=0;
 if(s->pending&&s->starting&&ss_completion(&error)){
  if(error){
   if(s->starting==2){score_close();shared_score_stream.ready=0;s->eof=1;s->stop_confirmed=1;}
   finish(s,error);return;
  }
  if(s->starting==1){
   s->stop_confirmed=1;
   score_close();int r=prepare(s);if(r){score_close();shared_score_stream.ready=0;finish(s,r);return;}
   r=ss_command(1);if(r){score_close();shared_score_stream.ready=0;finish(s,r);return;}s->stop_confirmed=0;s->starting=2;
  }else{
   if(s->command==3||s->command==6){score_close();shared_score_stream.ready=0;s->eof=1;s->stop_confirmed=1;}
   finish(s,0);
  }
 }
 if(shared_score_stream.ready&&!s->eof&&ss_file_capacity()){
  int r=fill(s);if(r){score_close();shared_score_stream.file_error=r;s->eof=1;}
 }
}
