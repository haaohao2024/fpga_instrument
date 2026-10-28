#include "link_startup.h"
void link_startup_reset(link_startup_gate *g,uint32_t generation,uint32_t now){
    g->generation=generation;g->started=now;g->opened=0;
}
int link_startup_poll(const link_startup_gate *g,uint32_t generation,uint32_t now,int transport_ready){
    if(!generation || generation!=g->generation || g->opened)return 0;
    if((uint32_t)(now-g->started)>=20000u)return -1;
    return transport_ready?1:0;
}
