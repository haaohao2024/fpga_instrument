#ifndef S10_HOST_OBSERVER_H
#define S10_HOST_OBSERVER_H
#include <stdint.h>
#include <stddef.h>
struct bt_conn;struct bt_l2cap_chan;struct net_buf;
struct s10_host_send_snapshot { uintptr_t task,conn;uint32_t serial;uint8_t header[2],valid; };
#if defined(S10_PROFILE_HOST_OBSERVER)
extern uint32_t s10_profile_host_rx_before(struct bt_conn*,struct bt_l2cap_chan*,uint16_t,struct net_buf*) __attribute__((weak));
extern void s10_profile_host_rx_after(uint32_t) __attribute__((weak));
extern void s10_profile_host_connected(struct bt_l2cap_chan*) __attribute__((weak));
extern void s10_profile_host_disconnected(struct bt_l2cap_chan*) __attribute__((weak));
extern struct s10_host_send_snapshot s10_profile_host_send_before(struct bt_l2cap_chan*,const uint8_t*,uint16_t) __attribute__((weak));
extern void s10_profile_host_send_after(const struct s10_host_send_snapshot*,int) __attribute__((weak));
#endif
#endif
