#include "score_hal.h"
#include "score_service.h"
#include <stdint.h>
#include "bflb_sec_trng.h"
static uint64_t epoch;
// Probabilistic boot identity; durable nonreuse awaits approved Flash integration.
static int new_session(void){uint64_t random=0;if(bflb_trng_readlen((uint8_t*)&random,sizeof random)!=0||!random||random==epoch)return -1;epoch=random;return 0;}
int main(void){
 uint8_t status[32];if(hal_platform_init())for(;;){}
 for(;;){
  if(new_session()){hal_delay_us(20000);continue;}
  int r=score_run_file(epoch,status);
  if(r==0)for(;;){hal_delay_us(20000);score_send(8,epoch,0,0,0,0,status);}
  if(r<0)hal_delay_us(20000);
 }
}
