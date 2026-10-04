#include "s9_player.h"
#include "s9_protocol.h"
#include "score_service.h"
#include <string.h>
void s9_player_init(s9_player *s,uint64_t seed){memset(s,0,sizeof *s);s->epoch_cursor=seed;}
void s9_player_autostart(s9_player *s,uint32_t now){if(!s9_player_command(s,1,0,now))s->file_default_mode=1;}
int s9_player_command(s9_player *s,unsigned cmd,unsigned arg,uint32_t now){
 if(s->pending||s->command_done)return S9_E_BUSY;
 if((cmd!=1&&cmd!=3&&cmd!=4&&cmd!=5&&cmd!=6)||arg>3)return S9_E_RANGE;
 if((cmd==4&&(!s->active||s->status[7]!=2))||(cmd==5&&(!s->active||s->status[7]!=3)))return S9_E_STATE;
 s->pending=1;s->command=(uint8_t)cmd;s->argument=(uint8_t)arg;s->command_started=now;s->starting=0;s->result=0;s->errors=0;
 s->file_default_mode=0;
 if(cmd==1||cmd==3||cmd==6)s->stop_confirmed=0;
 return 0;
}
static void finish(s9_player *s,int result){s->pending=0;s->command_done=1;s->result=result;}
static void failure(s9_player *s,int error){
 score_cancel();score_close();s->have_page=0;s->eof=0;s->active=0;s->stop_confirmed=0;
 /* Keep retrying the real source-scoped STOP fence. Never substitute panic. */
 s->command=3;s->starting=0;s->result=error;s->pending=1;
}
int s9_player_completion(s9_player *s,int *result){if(!s->command_done)return 0;*result=s->result;s->command_done=0;return 1;}
void s9_player_step(s9_player *s,uint32_t now){
 if((uint32_t)(now-s->last_poll)<2)return;
 s->last_poll=now;
 if(score_send(8,s->epoch,0,0,0,0,s->status)){
  if(++s->errors>=20)failure(s,S9_E_IO);
  return;
 }
 s->errors=0;
 uint64_t actual_epoch=s9_get64(s->status+8);unsigned state=s->status[7];
 if(s->pending&&(s->command==1||s->command==3||s->command==6)&&!s->starting){
  if(state){score_send(3,actual_epoch,0,0,0,0,s->status);return;}
  if(score_close()){finish(s,S9_E_IO);return;}
  s->active=0;s->have_page=0;s->eof=0;s->stop_confirmed=1;
  if(s->command!=1){finish(s,s->result);return;}
  if(s->epoch_cursor==UINT64_MAX){finish(s,S9_E_SEQUENCE);return;}
  s->epoch=++s->epoch_cursor;s->mode=s->argument;
  if(score_open(s->epoch)){finish(s,S9_E_IO);return;}
  if(s->file_default_mode)s->mode=(uint8_t)score_default_mode();
  if(score_send(1,s->epoch,0,s->mode,0,0,s->status)){failure(s,S9_E_IO);return;}
  s->starting=1;s->stop_confirmed=0;s->started=0;s->deadline=now;return;
 }
 if(s->starting){
  if(actual_epoch==s->epoch&&state){s->active=1;s->started=1;s->starting=0;finish(s,0);}
  else {if((uint32_t)(now-s->deadline)>100)failure(s,S9_E_TIMEOUT);return;}
 }
 if(s->pending&&(s->command==4||s->command==5)){
  unsigned goal=s->command==4?3:2;
  if(actual_epoch==s->epoch&&state==goal)finish(s,0);
  else if(!state||actual_epoch!=s->epoch){finish(s,S9_E_STATE);}
  else {score_send(s->command,s->epoch,0,0,0,0,s->status);return;}
 }
 if(!s->active)return;
 if(actual_epoch!=s->epoch||s->status[5]){failure(s,S9_E_IO);return;}
 if(s->have_page&&s9_get32(s->status+16)==s->sequence)s->have_page=0;
 if(!s->have_page&&!s->eof){
  int r=score_next(s->page,&s->sequence,s->epoch);
  if(r<0){failure(s,S9_E_IO);return;}
  if(r==1)s->eof=1;else{s->have_page=1;s->deadline=now;}
 }
 if(!state){
  if(!s->eof){failure(s,S9_E_STATE);return;}
  score_close();s->active=0;s->stop_confirmed=1;
  if(s->status[6]&2){s->command_done=0;s9_player_command(s,1,s->mode,now);}
  return;
 }
 if(s->have_page){
  if(!(s->status[6]&1)){s->deadline=now;return;}
  if((uint32_t)(now-s->deadline)>100){failure(s,S9_E_TIMEOUT);return;}
  if(score_send(2,s->epoch,s->sequence,0,s->page,512,s->status)){failure(s,S9_E_IO);return;}
 }
}
