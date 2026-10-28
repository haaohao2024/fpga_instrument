#include "diag_trace.h"
#include "bflb_gpio.h"
#include "bflb_uart.h"
#include "bflb_irq.h"
#include "hardware/uart_reg.h"
#include "usb_console.h"
#define TX_N 4096u
static struct bflb_device_s *uart;
static uint8_t tx[TX_N];
static uint32_t tx_head,tx_tail,tx_lost;
/* Regular logging never waits for a hardware FIFO or a USB/DTR state. */
static ssize_t uart_write(const void *data,size_t size){
 if(!data)return size?-1:0;
 const uint8_t *p=data;size_t limit=size>128?128:size;
 uintptr_t f=bflb_irq_save();
 size_t sent=0;
 while(sent<limit && tx_head-tx_tail<TX_N){tx[tx_head&(TX_N-1)]=p[sent++];++tx_head;}
 tx_lost+=(uint32_t)(size-sent);bflb_irq_restore(f);return (ssize_t)size;
}

void diag_puts(const char *s){size_t n=0;while(s[n])++n;for(size_t off=0;off<n;){size_t count=n-off>128?128:n-off;(void)uart_write(s+off,count);off+=count;}}
void diag_hex(uint32_t v){char s[9];const char *h="0123456789abcdef";for(int i=0;i<8;i++)s[i]=h[(v>>(28-4*i))&15];s[8]=0;diag_puts(s);}
uint32_t diag_uart_dropped(void){return tx_lost;}
void diag_uart_init(void){
 struct bflb_device_s *gpio=bflb_device_get_by_name("gpio");
 bflb_gpio_uart_init(gpio,GPIO_PIN_28,GPIO_UART_FUNC_UART0_TX);
 bflb_gpio_uart_init(gpio,GPIO_PIN_27,GPIO_UART_FUNC_UART0_RX);
 struct bflb_uart_config_s cfg={0};cfg.baudrate=115200;cfg.data_bits=UART_DATA_BITS_8;
 cfg.stop_bits=UART_STOP_BITS_1;cfg.parity=UART_PARITY_NONE;cfg.flow_ctrl=0;
 cfg.tx_fifo_threshold=7;cfg.rx_fifo_threshold=7;cfg.bit_order=UART_LSB_FIRST;
 uart=bflb_device_get_by_name("uart0");bflb_uart_init(uart,&cfg);
 diag_puts("\r\nR77 UART READY 115200 8N1; FPGA bridge required\r\n");
 diag_uart_pump();
}
int diag_getchar(void){return uart?bflb_uart_getchar(uart):-1;}
void diag_uart_pump(void){
 if(!uart)return;
 uintptr_t f=bflb_irq_save();
 /* At most 32 bytes per call; no polling wait loop. */
 for(unsigned i=0;i<32 && tx_tail!=tx_head;i++){
  if(!(getreg32(uart->reg_base+UART_FIFO_CONFIG_1_OFFSET)&UART_TX_FIFO_CNT_MASK))break;
  putreg8(tx[tx_tail&(TX_N-1)],uart->reg_base+UART_FIFO_WDATA_OFFSET);++tx_tail;
 }
 bflb_irq_restore(f);
}
struct diag_fault_record {uint32_t magic,pc,a,b,c;const char *kind;};
volatile struct diag_fault_record diag_first_fault;
static void panic_byte(uint8_t ch){
 if(!uart)return;
 for(unsigned budget=0;budget<200000u;budget++){
  if(getreg32(uart->reg_base+UART_FIFO_CONFIG_1_OFFSET)&UART_TX_FIFO_CNT_MASK){
   putreg8(ch,uart->reg_base+UART_FIFO_WDATA_OFFSET);return;
  }
 }
}
static void panic_text(const char *s){for(unsigned i=0;i<200 && s[i];i++)panic_byte((uint8_t)s[i]);}
static void panic_hex(uint32_t v){const char *h="0123456789abcdef";for(int i=7;i>=0;i--)panic_byte(h[(v>>(i*4))&15]);}
void diag_fatal(const char *kind,uint32_t pc,uint32_t a,uint32_t b,uint32_t c){
 (void)bflb_irq_save();
 if(!diag_first_fault.magic)diag_first_fault=(struct diag_fault_record){0x52373346,pc,a,b,c,kind};
 panic_text("\r\nR77 FAULT ");panic_text(kind);panic_text(" pc=");panic_hex(pc);
 panic_text(" a=");panic_hex(a);panic_text(" b=");panic_hex(b);panic_text(" c=");panic_hex(c);panic_text(" HALTED\r\n");
#ifdef DIAG_HOST_TEST
 extern void diag_test_halt(void) __attribute__((noreturn));diag_test_halt();
#else
 for(;;)__asm__ volatile("":::"memory");
#endif
}

