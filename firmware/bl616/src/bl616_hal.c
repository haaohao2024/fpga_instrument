#include "bus_fault.h"
#include "record_trace.h"
#include "record_hot.h"
#include "hardware/gpio_reg.h"
/* Capture the lhal input bit before the std GLB header aliases its name. */
enum { SHARED_GPIO_PAD_INPUT_MASK=GLB_REG_GPIO_0_I };
// Dock31004 Rev1.4: GPIO12 SD-CS,13 SCK,14 MOSI,15 MISO,10 STE1.
// NEO secondary application HAL; physical board validation remains required.
#include "score_hal.h"
#include "score_service.h"
#include "bflb_gpio.h"
#include "bflb_spi.h"
#include "bounded_spi_io.h"
#include "shared_spi_rate.h"
#include "bflb_mtimer.h"
#include "bl616_glb.h"
#include "board.h"
#include "record_bench.h"
#include "sd_spi.h"
#include "s10_runtime.h"
#include "FreeRTOS.h"
#include "task.h"
static struct bflb_device_s *gpio,*spi;
static struct bflb_spi_config_s config={.freq=400000,.role=SPI_ROLE_MASTER,.mode=SPI_MODE0,
 .data_width=SPI_DATA_WIDTH_8BIT,.bit_order=SPI_BIT_MSB,.byte_order=SPI_BYTE_LSB,.tx_fifo_threshold=0,.rx_fifo_threshold=0};
static int selected;
static uint64_t io_deadline;
static int io_error;
int hal_io_failed(void){return io_error;}
void hal_io_deadline(uint64_t limit){if(!bus_fault_active())io_deadline=limit;}
static uint64_t transfer_deadline(unsigned bytes){uint64_t end=hal_time_us()+((uint64_t)bytes*8000000u+config.freq-1u)/config.freq+1000u;return io_deadline&&io_deadline<end?io_deadline:end;}
uint32_t shared_spi_peripheral_hz;
int hal_platform_init(void){
 /* board_init already completed by R76 main. */gpio=bflb_device_get_by_name("gpio");spi=bflb_device_get_by_name("spi0");if(!gpio||!spi)return -1;
 for(unsigned pin=0;pin<4;pin++)bflb_gpio_init(gpio,pin,GPIO_INPUT|GPIO_PULL_NONE|GPIO_SMT_EN);
 for(unsigned pin=0;pin<4;pin++)bflb_gpio_init(gpio,pin,GPIO_INPUT|GPIO_PULL_NONE|GPIO_SMT_EN);
 for(unsigned pin=0;pin<4;pin++)bflb_gpio_init(gpio,pin,GPIO_INPUT|GPIO_PULL_NONE|GPIO_SMT_EN);
 bflb_gpio_init(gpio,10,GPIO_INPUT|GPIO_OUTPUT|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,11,GPIO_INPUT|GPIO_OUTPUT|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,12,GPIO_INPUT|GPIO_OUTPUT|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_set(gpio,10);bflb_gpio_set(gpio,11);bflb_gpio_set(gpio,12);
 // SDK board_gpio.c native pads18/19 are MISO/MOSI. Dock14/15 are
 // MOSI/MISO, requiring explicit SPI data swap rather than inherited boot state.
 GLB_SPI_Sig_Swap_Set(GLB_SPI_SIG_SWAP_GRP_GPIO12_GPIO23,0);
 GLB_Swap_MCU_SPI_0_MOSI_With_MISO(ENABLE);
 bflb_gpio_init(gpio,13,GPIO_FUNC_SPI0|GPIO_ALTERNATE|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,14,GPIO_FUNC_SPI0|GPIO_ALTERNATE|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,15,GPIO_FUNC_SPI0|GPIO_ALTERNATE|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_spi_init(spi,&config);
 shared_spi_peripheral_hz=bflb_clk_get_peripheral_clock(BFLB_DEVICE_TYPE_SPI,spi->idx);
 if(!shared_spi_peripheral_hz)return -1;
 selected=BUS_NONE;bus_fault_bind(spi->reg_base,0x2000c100u,0x2000c200u,gpio->reg_base);return 0;
}
RECORD_HOT int hal_select(int target){
 if(bus_fault_active()||target<0||target>BUS_CONTROL)return -1;
 /* An expired SD occupancy budget is not evidence of live hardware. Give
  * cleanup its own physical-fence deadline, then preserve the SD error. */
 if(bounded_spi_idle(spi,hal_time_us()+1000u))return -1;
 io_deadline=0;io_error=0;
 order_trace_select(OT_SWITCH,selected,(unsigned)target);
 /* GPIO10/11/12 were pad-validated by bflb_gpio_init at startup.
  * BL616 SDK W1SET: all shared CS high in one register write. */
 putreg32((1u<<10)|(1u<<11)|(1u<<12),gpio->reg_base+GLB_GPIO_CFG138_OFFSET);selected=BUS_NONE;order_trace_select(OT_HIGH,0,(unsigned)target);bflb_mtimer_delay_us(1);
 if(target!=BUS_NONE&&record_bench_stress)record_bench_bus_pause();
 if(target!=BUS_NONE){unsigned pin=target==BUS_SD?12u:target==BUS_FPGA?10u:11u;putreg32(1u<<pin,gpio->reg_base+GLB_GPIO_CFG140_OFFSET);}
 selected=target;
 if(target!=BUS_NONE)order_trace_select(OT_LOW,0,(unsigned)target);
 /* Source-synchronous TX still freezes its response in the40MHz domain.
  * Explicit CS setup keeps that contract independent of software overhead. */
 if(target==BUS_FPGA)bflb_mtimer_delay_us(1);
 return 0;
}
RECORD_HOT uint8_t hal_exchange(uint8_t value){uint8_t rx=255;if(bus_fault_active()||io_error)return rx;if(bounded_spi_byte(spi,value,transfer_deadline(1),&rx))io_error=1;return rx;}
RECORD_HOT int hal_exchange_block(const uint8_t *tx,uint8_t *rx,unsigned bytes){if(bus_fault_active()||io_error)return -1;order_trace_take(OT_PIO_BEGIN,bytes);int r=(selected==BUS_SD&&tx&&!rx&&bytes==512&&sd_data_dma)?(bounded_spi_idle(spi,hal_time_us()+1000u)?-1:s10_runtime_sd_exchange(tx,bytes,config.freq)):bounded_spi_block(spi,tx,rx,bytes,transfer_deadline(bytes));if(r)io_error=1;order_trace_take(OT_PIO_RETURN,bytes);return r;}
RECORD_HOT void hal_frequency(uint32_t hz){if(bus_fault_active()||hal_select(BUS_NONE))return;config.freq=hz;order_trace_take(OT_CFG_BEGIN,0);shared_spi_rate(spi,hz);order_trace_take(OT_CFG_DONE,0);}
RECORD_HOT uint64_t hal_time_us(void){return bflb_mtimer_get_time_us();}
#ifdef S9_RUNTIME
extern int s9_disk_cancelled(void);
RECORD_HOT int hal_cancelled(void){return bus_fault_active()||s9_disk_cancelled();}
#else
RECORD_HOT int hal_cancelled(void){return bus_fault_active()||score_is_cancelled();}
#endif
void hal_delay_us(uint32_t us){bflb_mtimer_delay_us(us);}

#ifdef S10_MEDIA_RUNTIME
#include "s10_spi_dma.h"
/* Read the actual shared CS pad levels as well as the selected software
 * target. A conflict is a fault, never interpreted as BUS_NONE. */
RECORD_HOT int hal_bus_owner(void){
 /* Preserve actual pad reads; output latch alone is not ownership. */
 int a=!(getreg32(gpio->reg_base+GLB_GPIO_CFG0_OFFSET+(10u<<2))&SHARED_GPIO_PAD_INPUT_MASK);
 int b=!(getreg32(gpio->reg_base+GLB_GPIO_CFG0_OFFSET+(11u<<2))&SHARED_GPIO_PAD_INPUT_MASK);
 int c=!(getreg32(gpio->reg_base+GLB_GPIO_CFG0_OFFSET+(12u<<2))&SHARED_GPIO_PAD_INPUT_MASK);
 if(a+b+c>1)return -1;
 int owner=a?BUS_FPGA:b?BUS_CONTROL:c?BUS_SD:BUS_NONE;
 return owner==selected?owner:-1;
}
int hal_media_dma_bind(s10_spi_dma *state,const s10_dma_binding *binding){
 struct bflb_device_s *tx=bflb_device_get_by_name("dma0_ch0"),*rx=bflb_device_get_by_name("dma0_ch1");
 if(!tx||!rx||!spi)return -1;
 order_trace_bind(spi->reg_base,tx->reg_base,rx->reg_base,gpio->reg_base);
 return s10_spi_dma_bind(state,spi,tx,rx,binding);
}
#endif

void hal_startup_pause(void){vTaskDelay(pdMS_TO_TICKS(25));}
