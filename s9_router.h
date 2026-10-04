#ifndef S9_ROUTER_H
#define S9_ROUTER_H
#include "s9_protocol.h"
#define S9_ROUTER_SLOTS 8
typedef struct {
    uint8_t request[S9_MAX_MESSAGE],result[36];
    uint32_t order;
    uint16_t length;
    uint8_t used,sent,terminal,dirty;
} s9_router_entry;
typedef struct {
    s9_reassembly assembly[3];
    s9_router_entry entry[S9_ROUTER_SLOTS];
    uint8_t session[16],error_result[36];
    uint32_t generation,highwater[3],order,notification_sequence;
    uint32_t unique,retries,rejected,dispatched,finished,cancelled,stale_updates;
    uint8_t ready,error_dirty,dispatch_cursor,notification_cursor;
} s9_router;
void s9_router_reset(s9_router *state,const uint8_t session[16],uint32_t generation);
void s9_router_ready(s9_router *state,int ready);
void s9_router_disconnect(s9_router *state);
/* Protocol task only; no SPI, FatFs, BLE transmit or wait in these functions. */
int s9_router_fragment(s9_router *state,uint32_t generation,uint8_t channel,
                       const uint8_t *fragment,unsigned length,uint32_t now_ms);
/* Pointer remains valid until execution result or disconnect; bus/file queues
 * copy the bounded command before marking it sent. */
int s9_router_peek(s9_router *state,unsigned *slot,s9_message *message,const uint8_t **bytes,unsigned *length);
void s9_router_sent(s9_router *state,unsigned slot);
int s9_router_result(s9_router *state,uint32_t generation,const uint8_t session[16],const uint8_t result[36]);
int s9_router_notice(s9_router *state,uint8_t *out,unsigned capacity);
void s9_make_result(uint8_t out[36],uint8_t channel,uint32_t sequence,unsigned phase,int error);
#endif
