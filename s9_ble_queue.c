#include "s9_ble_queue.h"
#include <string.h>

_Static_assert(sizeof(s9_ble_rx_slot)==256,"BLE callback slot budget");
void s9_ble_queue_init(s9_ble_queue *q) { memset(q,0,sizeof(*q)); }
unsigned s9_ble_queue_credit(const s9_ble_queue *q,uint8_t ch) {
    if(ch>S9_CH_FILE) return 0;
    unsigned own=0,free=0;
    for(unsigned i=0;i<S9_BLE_RX_SLOTS;i++) {
        if(!q->slot[i].used) free++;
        else if(q->slot[i].channel==ch) own++;
    }
    unsigned quota=ch==S9_CH_FILE?4u:2u;
    return own>=quota?0:(free<quota-own?free:quota-own);
}
int s9_ble_queue_push(s9_ble_queue *q,uint32_t generation,uint8_t ch,const uint8_t *data,unsigned n) {
    if(!generation || ch>S9_CH_FILE || !data || n<9 || n>S9_BLE_FRAGMENT_MAX ||
       s9_get16(data+6)!=n-8 || !s9_get32(data)) { q->rejected++;return S9_E_FORMAT; }
    if(!s9_ble_queue_credit(q,ch)) { q->rejected++;return S9_E_BUSY; }
    for(unsigned i=0;i<S9_BLE_RX_SLOTS;i++) if(!q->slot[i].used) {
        s9_ble_rx_slot *s=&q->slot[i];memcpy(s->bytes,data,n);
        s->generation=generation;s->order=q->next_order++;s->length=(uint16_t)n;
        s->channel=ch;s->used=1;q->accepted++;return S9_OK;
    }
    q->rejected++;return S9_E_BUSY;
}
int s9_ble_queue_pop(s9_ble_queue *q,s9_ble_rx_slot *out) {
    int best=-1;
    for(unsigned i=0;i<S9_BLE_RX_SLOTS;i++) if(q->slot[i].used) {
        const s9_ble_rx_slot *s=&q->slot[i];
        if(best<0) { best=(int)i;continue; }
        const s9_ble_rx_slot *b=&q->slot[best];
        if(q->high_priority_run>=8) {
            if((int32_t)(s->order-b->order)<0) best=(int)i;
        } else if(s->channel<b->channel ||
                  (s->channel==b->channel && (int32_t)(s->order-b->order)<0)) best=(int)i;
    }
    if(best<0) return S9_MORE;
    *out=q->slot[best];q->slot[best].used=0;q->consumed++;
    if(out->channel==S9_CH_FILE || q->high_priority_run>=8) q->high_priority_run=0;
    else q->high_priority_run++;
    return S9_COMPLETE;
}
void s9_ble_queue_discard(s9_ble_queue *q,uint32_t generation) {
    for(unsigned i=0;i<S9_BLE_RX_SLOTS;i++) if(q->slot[i].used && q->slot[i].generation==generation) {
        q->slot[i].used=0;q->discarded++;
    }
}
