#ifndef S9_GATT_H
#define S9_GATT_H
#include <stdint.h>

/* Hooks execute bounded state/queue operations only. Never filesystem/SPI waits. */
typedef struct {
    uint32_t (*connected)(void);
    void (*disconnected)(uint32_t generation);
    int (*receive)(uint32_t generation,uint8_t channel,const uint8_t *bytes,unsigned length);
    void (*info_snapshot)(uint8_t out[64]);
} s9_gatt_hooks;
int s9_gatt_init(const s9_gatt_hooks *hooks);
/* Called by protocol task. Nonblocking: returns negative if stack has no credit. */
int s9_gatt_notify_fragment(uint32_t generation,const uint8_t *fragment,unsigned length);
unsigned s9_gatt_mtu(void);
int s9_gatt_advertise(void);
int s9_gatt_connected(void);
void s9_gatt_disconnect(void);
#endif
