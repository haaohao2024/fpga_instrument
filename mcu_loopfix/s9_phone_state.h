#ifndef S9_PHONE_STATE_H
#define S9_PHONE_STATE_H
#include "s9_protocol.h"
/* Protocol-task/bus-service owned, never accessed from a BLE ISR. */
typedef struct {uint64_t press,token;} s9_phone_key;
typedef struct {
 uint32_t held;uint64_t next_token;uint8_t exhausted;
 s9_phone_key key[32];
} s9_phone_ledger;
typedef struct {
 s9_phone_ledger next;
 uint8_t items[9][12],presses[9][8],count,prepared;
 uint32_t ticket;
} s9_phone_batch;
typedef struct {
 uint64_t press,token,identity;
 uint16_t generation;uint8_t key,known;
} s9_phone_instance;
void s9_phone_ledger_open(s9_phone_ledger *,uint64_t next_token,int exhausted);
int s9_phone_prepare(const s9_phone_ledger *,s9_phone_batch *,uint32_t ticket,const uint8_t *records,unsigned count);
int s9_phone_accept(s9_phone_ledger *,s9_phone_batch *,uint32_t ticket);
void s9_phone_cancel(s9_phone_batch *);
int s9_phone_next_off(const s9_phone_ledger *,uint8_t record[16]);
int s9_phone_instance_commit(s9_phone_instance slots[32],const s9_phone_batch *,unsigned item,unsigned slot,uint64_t identity,uint16_t generation);
int s9_phone_candidate(const s9_phone_instance slots[32],uint8_t key,uint64_t press,unsigned from);
#endif
