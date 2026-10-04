#ifndef S10_ISOLATED_INGRESS_CORE_H
#define S10_ISOLATED_INGRESS_CORE_H
#include <stdint.h>
#include <stddef.h>
#define IG_CONNECTIONS 1u
#define IG_SLOTS 8u
#define IG_SDU_BYTES 1024u
enum ig_reason { IG_NONE,IG_CONTEXT,IG_RESPONSE,IG_IDENTITY,IG_FULL,IG_FORMAT,IG_GENERATION,IG_CLOSED };
enum ig_slot_state { IG_FREE,IG_READY,IG_CLAIMED };
enum ig_signal { IG_START=7,IG_CLOSE=8,IG_SUSPEND=9,IG_ABORT=10 };
struct ig_identity { uintptr_t conn,chan; uint32_t connection_serial; uint16_t cid; };
struct ig_evidence {
 struct ig_identity identity;
 uintptr_t rx_task,send_task;
 uint32_t rx_serial;
 uint8_t request_label,request_signal,response_label,response_signal;
 uint8_t response_type,before_state,after_state,callback_state;
 int send_result;
};
struct ig_slot {
 uint8_t data[IG_SDU_BYTES];
 struct ig_identity identity;
 uint64_t epoch,ticket;
 uint16_t len;
 uint8_t state;
};
struct ig_transport {
 struct ig_identity identity;
 uint64_t epoch,retiring_epoch,pending_epoch,retire_serial;
 uint32_t last_rx_serial;
 uint8_t attached,playing,pending_start,fault,external_retire_pending;
};
struct ig_core {
 struct ig_transport transports[IG_CONNECTIONS];
 struct ig_slot slots[IG_SLOTS];
 uint64_t next_epoch,next_ticket,rx_active_epoch;
 uint32_t copied,claimed,released,discarded,old_rejected,retired,fences,accepted_starts,duplicate_starts,faults;
};
void ig_init(struct ig_core *s);
int ig_attach(struct ig_core *s,struct ig_identity id);
int ig_accepted(struct ig_core *s,const struct ig_evidence *e);
int ig_copy(struct ig_core *s,struct ig_identity id,uint64_t captured_epoch,uint32_t rx_serial,const uint8_t *sdu,uint16_t len);
int ig_claim(struct ig_core *s,uint64_t *ticket,const struct ig_slot **slot);
int ig_active(const struct ig_core *s,uint64_t epoch);
int ig_task_valid(const struct ig_core *s,uint64_t ticket,uint64_t epoch);
int ig_release(struct ig_core *s,uint64_t ticket,uint64_t epoch);
void ig_retire(struct ig_core *s,struct ig_identity id,enum ig_reason reason);
int ig_external_retire_done(struct ig_core *s,struct ig_identity id,uint64_t epoch,uint64_t retire_serial);
int ig_fence(struct ig_core *s,struct ig_identity id);
int ig_detach(struct ig_core *s,struct ig_identity id);
int ig_conserved(const struct ig_core *s);
#endif
