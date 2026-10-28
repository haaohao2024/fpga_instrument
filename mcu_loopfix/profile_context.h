#ifndef S10_PROFILE_CONTEXT_H
#define S10_PROFILE_CONTEXT_H
#include "ingress_core.h"
#define PC_RX_CONTEXTS 2
#define PC_MEDIA 1
#define PC_SIGNAL 2
struct pc_rx {
 uintptr_t task; uint64_t captured_epoch; uint32_t serial; struct ig_evidence e;
 uint8_t active,kind,have_response,callback_seen;
};
struct pc_core { struct ig_core source; struct pc_rx rx[PC_RX_CONTEXTS]; uint32_t next_rx,context_faults,media_before,original_returned,late_callbacks; };
struct pc_send { uintptr_t task; struct ig_identity identity; uint32_t serial; uint8_t label,signal,type,valid; };
void pc_init(struct pc_core *c);
uint32_t pc_begin(struct pc_core*c,uintptr_t task,struct ig_identity id,int kind,uint8_t before,const uint8_t*data,uint16_t len);
struct pc_send pc_send_before(struct pc_core*c,uintptr_t task,uintptr_t conn,const uint8_t*data,uint16_t len);
void pc_send_after(struct pc_core*c,const struct pc_send*s,int result);
void pc_callback(struct pc_core*c,uintptr_t task,uint8_t state);
int pc_fence(struct pc_core*c,struct ig_identity id);
int pc_end(struct pc_core*c,uintptr_t task,uint32_t serial);
#endif
