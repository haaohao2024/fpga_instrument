#ifndef SHARED_SCORE_H
#define SHARED_SCORE_H
#include "shared_raw.h"
#include <stdint.h>
typedef struct {uint32_t events48,groups48,rows48,rows960,rows4800;} ss_profile;
typedef struct {
 uint64_t origin,token_counter,paused_elapsed,resume_at,key_token[32];
 uint32_t page,held,resume_mask,seen;uint8_t index,mode,running,paused;
 uint8_t note[32],pressure[32];
} ss_cursor;
typedef struct {uint64_t target;raw_item item;uint8_t kind,key,note,pressure,resume;} ss_event;
typedef struct {uint64_t at;uint16_t events,rows;} ss_group;
typedef struct {
 union {uint8_t page[32][512];ss_group probe[128];} memory;
 ss_profile profile;uint64_t end_time;uint32_t records,file_rate;
 volatile uint32_t write,released;volatile int file_error,completion;
 volatile uint8_t ready,command,command_done,state,reload;uint8_t mode;
} shared_score;
extern shared_score shared_score_stream;
void ss_init(void);
void ss_file_reset(uint32_t records,uint64_t end_time,unsigned mode,const ss_profile *);
int ss_file_capacity(void);
int ss_file_push(const uint8_t page[512]);
void ss_file_ready(void);
int ss_command(unsigned command);
int ss_completion(int *error);
void ss_complete(int error);
int ss_peek(ss_cursor *,uint64_t through,ss_event *);
int ss_take(ss_cursor *,const ss_event *);
void ss_commit(const ss_cursor *);
/* File-owner profile helper. probe aliases the16KiB queue only while idle. */
void ss_profile_group(ss_profile *,uint64_t at,unsigned events,unsigned *head,unsigned *count);
#endif
