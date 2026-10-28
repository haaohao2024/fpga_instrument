#ifndef RECORD_OBSERVER_H
#define RECORD_OBSERVER_H
#include <stdint.h>
enum {OBS_FILE=0,OBS_BUS=1};
enum {OBS_LOOP=1,OBS_BENCH=2,OBS_FILE_STEP=3,OBS_FILE_WAIT=4,
 OBS_PCM=5,OBS_EVENT=6,OBS_STOP=7,OBS_FINISH=8,OBS_SYNC=9,OBS_CLOSE=10,
 OBS_VERIFY=11,OBS_RENAME=12,OBS_CATALOGUE=13,OBS_TERMINAL=14,
 OBS_BUS_CONTROL=20,OBS_BUS_POLL=21,OBS_RPC_WAIT=22,OBS_RPC=23,OBS_RPC_DONE=24,OBS_QUARANTINE=25};
#ifdef RECORD_OBSERVER
void record_observer_phase(unsigned task,unsigned phase);
void record_observer_progress(unsigned task,uint32_t value);
void record_observer_result(unsigned task,int result);
void record_observer_bind(unsigned task,void *handle,unsigned words);
unsigned record_observer_reply(char out[512],unsigned page,uint32_t sequence);
#else
static inline void record_observer_bind(unsigned t,void *p,unsigned n){(void)t;(void)p;(void)n;}
static inline void record_observer_phase(unsigned t,unsigned p){(void)t;(void)p;}
static inline void record_observer_progress(unsigned t,uint32_t p){(void)t;(void)p;}
static inline void record_observer_result(unsigned t,int p){(void)t;(void)p;}
#endif
#endif
