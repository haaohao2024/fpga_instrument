#ifndef LINK_STARTUP_H
#define LINK_STARTUP_H
#include <stdint.h>
typedef struct {uint32_t generation,started;unsigned opened;} link_startup_gate;
void link_startup_reset(link_startup_gate *,uint32_t generation,uint32_t now);
/* 1 permits OPEN, 0 waits/already opened, -1 is the separate pre-auth timeout. */
int link_startup_poll(const link_startup_gate *,uint32_t generation,uint32_t now,int transport_ready);
#endif
