#ifndef S9_PROTOCOL_H
#define S9_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
#include "s9_constants.h"

enum s9_result {
    S9_OK = 0, S9_MORE = 1, S9_COMPLETE = 2,
    S9_E_LENGTH = -1, S9_E_FORMAT = -2, S9_E_CRC = -3, S9_E_RANGE = -4,
    S9_E_SESSION = -5, S9_E_SEQUENCE = -6, S9_E_BUSY = -7,
    S9_E_TIMEOUT = -8, S9_E_CONFLICT = -9, S9_E_STATE = -10,
    S9_E_STALE = -11, S9_E_IO = -12, S9_E_EXPIRED = -13
};
typedef struct {
    const uint8_t *session;
    const uint8_t *payload;
    uint32_t sequence;
    uint16_t length;
    uint8_t channel, opcode;
} s9_message;
typedef struct {
    uint8_t bytes[S9_MAX_MESSAGE];
    uint32_t message_sequence, started_ms, progress_ms;
    uint16_t used;
    uint8_t active;
} s9_reassembly;

uint16_t s9_get16(const uint8_t *p);
uint32_t s9_get32(const uint8_t *p);
uint64_t s9_get64(const uint8_t *p);
void s9_put16(uint8_t *p, uint16_t v);
void s9_put32(uint8_t *p, uint32_t v);
void s9_put64(uint8_t *p, uint64_t v);
uint32_t s9_crc32_update(uint32_t state,const uint8_t *p,size_t n);
uint32_t s9_crc32(const uint8_t *p, size_t n);
int s9_decode(const uint8_t *bytes, size_t count, s9_message *message);
int s9_validate_request(const s9_message *message);
int s9_encode(uint8_t *out, size_t capacity, uint8_t channel, uint8_t opcode,
              const uint8_t session[16], uint32_t sequence, const uint8_t *payload, uint16_t length);
void s9_reassembly_reset(s9_reassembly *state);
int s9_fragment_push(s9_reassembly *state, uint8_t channel, const uint8_t *fragment,
                     size_t count, uint32_t now_ms, uint16_t *complete_length);
#endif
