#ifndef S9_BLE_QUEUE_H
#define S9_BLE_QUEUE_H
#include "s9_protocol.h"

/* Caller serializes push/pop/state changes with a short critical section.
 * This queue never calls a filesystem, SPI, BLE transmit or blocking API. */
typedef struct {
    uint8_t bytes[S9_BLE_FRAGMENT_MAX];
    uint32_t generation, order;
    uint16_t length;
    uint8_t channel, used;
} s9_ble_rx_slot;
typedef struct {
    s9_ble_rx_slot slot[S9_BLE_RX_SLOTS];
    uint32_t next_order, accepted, consumed, discarded, rejected;
    uint8_t high_priority_run;
} s9_ble_queue;
void s9_ble_queue_init(s9_ble_queue *queue);
unsigned s9_ble_queue_credit(const s9_ble_queue *queue, uint8_t channel);
int s9_ble_queue_push(s9_ble_queue *queue, uint32_t generation, uint8_t channel,
                      const uint8_t *data, unsigned length);
int s9_ble_queue_pop(s9_ble_queue *queue, s9_ble_rx_slot *out);
void s9_ble_queue_discard(s9_ble_queue *queue, uint32_t generation);
#endif
