#ifndef LINK_DIAG_H
#define LINK_DIAG_H
#include <stdint.h>
enum { LD_CONNECT=1,LD_GENERATION,LD_SECURITY_REQUEST,LD_SECURITY_CHANGED,
       LD_INFO,LD_CCC,LD_RX,LD_DISCONNECT,LD_LOCAL_CLOSE,LD_OPEN,
       LD_BUS_STATE,LD_PEER_TIMEOUT,LD_BUS_TIMEOUT,LD_INIT_TIMEOUT };
void link_diag_event(unsigned kind,uint32_t a,uint32_t b,uint32_t c);
void link_diag_pump(void);
void link_diag_bad_response(int error,unsigned length,const uint8_t *request,const uint8_t *response);
#endif
