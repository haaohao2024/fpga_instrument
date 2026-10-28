#ifndef S9_BUS_SERVICE_H
#define S9_BUS_SERVICE_H
#include <stdint.h>
#include "s9_phone_state.h"
#define S9_BUS_COMMAND_SLOTS 4
typedef int (*s9_bus_status_fn)(void *,const uint8_t status[64]);
typedef struct {
 uint32_t ticket_sequence[8];uint8_t ticket_channel[8],ticket_known;
 s9_phone_instance instances[32];
 uint64_t query_identity;uint16_t query_generation,query_pan;
 uint32_t query_sequence;uint8_t query_active,query_opcode,query_key,query_from,query_slot,query_retry;
 s9_phone_ledger ledger; s9_phone_batch batch;
 uint32_t event_sequence;
 uint8_t awaiting_event,head_prepared,head_sent,cleanup_command;
 uint8_t request[S9_BUS_COMMAND_SLOTS][192];
 uint16_t length[S9_BUS_COMMAND_SLOTS];
 uint8_t session[16],status[64],pending_status[64];
 uint32_t started_ms,last_step_ms,last_keep_ms,last_good_ms;
 uint32_t transactions,crc_errors,completed,retries,timeouts;
 uint32_t epoch,next_serial,accepted_serial,ack_serial,last_result_serial,pending_result_serial;
 uint8_t ack_pending,have_result,pending_is_result;
 uint8_t head,count,offset,state,credit,status_pending;
 s9_bus_status_fn publish;void *context;
} s9_bus_service;
/* Sole bus-task context, including the SD all-CS-high service callback.
 * Every step performs at most one <=212-byte control transaction. */
void s9_bus_init(s9_bus_service *,s9_bus_status_fn,void *);
int s9_bus_open(s9_bus_service *,const uint8_t session[16]);
void s9_bus_close(s9_bus_service *);
int s9_bus_enqueue(s9_bus_service *,const uint8_t *,unsigned);
void s9_bus_step(s9_bus_service *,uint32_t now_ms);
/* Read-only exact byte-length quote for the next possible step. */
unsigned s9_bus_next_bytes(const s9_bus_service *,uint32_t now_ms);
#endif
