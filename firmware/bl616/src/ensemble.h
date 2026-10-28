#ifndef ENSEMBLE_H
#define ENSEMBLE_H
#include "shared_raw.h"
#include <stdint.h>
#define ENS_CAPACITY 96u
#define ENS_VOICES 12u
#define ENS_NATIVE_SLOTS 48u
#define ENS_CONTEXT_BUDGET 16u
enum {ENS_START=0x68,ENS_STOP=0x69,ENS_STATUS=0x6a,ENS_INFO=0x84,ENS_METRICS=41};
typedef struct {uint8_t level,root,minor,style;uint16_t bpm;} ens_config;
typedef struct {uint64_t due,token;uint32_t word;uint8_t timbre;} ens_event;
typedef struct {uint64_t token,off,tail[2];uint8_t note,timbre,on,velocity;} ens_voice;
typedef struct {uint64_t tag;uint8_t source,key,note,gate,velocity,weight;} ens_native;
typedef struct {uint64_t at;uint8_t note,velocity;} ens_motif;
typedef struct {
 ens_event queue[ENS_CAPACITY];ens_voice voice[ENS_VOICES];ens_native native[ENS_NATIVE_SLOTS];
 ens_config config;uint64_t anchor,next_tick,last_input,last_generated;
 uint32_t read,write,token_counter,tick_index,generated,skipped,observed;
 uint16_t revision,histogram[12];uint8_t running,pending,reason,chord,last_note,human_held,peak_slots;
 uint64_t evidence_at,decay_at,analysis_now,last_release,response_at,response_cooldown;
 ens_motif motif[8];
 uint32_t skipped_budget,skipped_tail,skipped_optional;
 int16_t harmony_scores[7];
 uint8_t motif_count,motif_head,response_count,response_index,response_note[4],response_gap[4],response_vel[4];
 uint8_t voicing[3],voicing_valid,proposed_chord,dense,variant;
} ensemble;
extern ensemble ensemble_state;
int ens_decode_config(const uint8_t p[8],ens_config *);
void ens_init(ensemble *);
int ens_begin(ensemble *,const ens_config *,uint64_t anchor,uint16_t revision);
void ens_capture(ensemble *,const uint8_t cell[32]);
int ens_generate(ensemble *,uint64_t now,uint64_t through);
int ens_peek(const ensemble *,uint32_t cursor,uint64_t through,ens_event *);
void ens_commit(ensemble *,uint32_t cursor);
void ens_pause(ensemble *);
void ens_retired(ensemble *);
void ens_info(const ensemble *,uint8_t p[64]);
/* Scores are diatonic degrees 0..6, never model class IDs. Read-only backend. */
void ens_harmony_scores(const ensemble *,int16_t scores[7]);
#endif
