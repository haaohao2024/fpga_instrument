#ifndef DIAG_TRACE_H
#define DIAG_TRACE_H
#include <stdint.h>
#include <stddef.h>
enum {
 D_STAGE=1,D_RESULT,D_HCI_SUBMIT,D_HCI_WAIT,D_HCI_WAKE,D_HOST_COMPLETE,
 D_ADV_ENTER,D_ADV_RETURN,D_COMPLETE_SEND,D_COMPLETE_RETURN,D_TO_HOST,D_TO_HOST_RETURN,
 D_DM_IN,D_DM_OUT,D_BLE_IN,D_BLE_OUT,D_BT_IN,D_BT_OUT,
 D_EVENT_IN,D_EVENT_OUT,D_HOST_CB_IN,D_HOST_CB_OUT,D_FREE_IN,D_FREE_OUT,
 D_BUFFER_IN,D_BUFFER_OUT,D_READY,D_USB_EVENT,D_USB_REG,D_COUNT
};
struct diag_record {uint32_t seq,cycles,id,a,b;};
void diag_event(unsigned id,uint32_t a,uint32_t b);
int diag_take(struct diag_record *out);
uint32_t diag_count(unsigned id);
uint32_t diag_dropped(void);
void diag_focus(void);
void diag_uart_init(void);
void diag_uart_pump(void);
void diag_puts(const char *text);
int diag_getchar(void);
uint32_t diag_uart_dropped(void);
void diag_hex(uint32_t value);
void diag_fatal(const char *kind,uint32_t pc,uint32_t a,uint32_t b,uint32_t c) __attribute__((noreturn));
void diag_usb_checkpoint(unsigned tag);
int diag_fix_26m_clock(void);
#endif
