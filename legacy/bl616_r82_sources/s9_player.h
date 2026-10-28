#ifndef S9_PLAYER_H
#define S9_PLAYER_H
#include <stdint.h>
typedef struct {
 uint8_t page[512],status[32];
 uint64_t epoch,epoch_cursor;
 uint32_t sequence,last_poll,deadline,command_started;
 int result;
 uint8_t active,have_page,eof,started,mode,pending,command,argument,command_done,stop_confirmed,errors,starting,file_default_mode;
} s9_player;
/* All calls and all FatFs operations run in the single file task. */
void s9_player_init(s9_player *,uint64_t epoch_seed);
void s9_player_autostart(s9_player *,uint32_t now_ms);
int s9_player_command(s9_player *,unsigned command,unsigned argument,uint32_t now_ms);
void s9_player_step(s9_player *,uint32_t now_ms);
int s9_player_completion(s9_player *,int *result);
#endif
