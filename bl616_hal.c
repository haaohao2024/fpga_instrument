// Dock31004 Rev1.4: GPIO12 SD-CS,13 SCK,14 MOSI,15 MISO,10 STE1.
// Candidate application HAL. Application startup/flash/debugger integration is NOT qualified.
#include "score_hal.h"
#include "score_service.h"
#include "bflb_gpio.h"
#include "bflb_spi.h"
#include "bflb_mtimer.h"
#include "bl616_glb.h"
#include "board.h"
static struct bflb_device_s *gpio,*spi;
static struct bflb_spi_config_s config={.freq=400000,.role=SPI_ROLE_MASTER,.mode=SPI_MODE0,
 .data_width=SPI_DATA_WIDTH_8BIT,.bit_order=SPI_BIT_MSB,.byte_order=SPI_BYTE_LSB,.tx_fifo_threshold=0,.rx_fifo_threshold=0};
static int selected;
int hal_platform_init(void){
 board_init();gpio=bflb_device_get_by_name("gpio");spi=bflb_device_get_by_name("spi0");if(!gpio||!spi)return -1;
 bflb_gpio_init(gpio,10,GPIO_OUTPUT|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,11,GPIO_INPUT|GPIO_PULLUP|GPIO_SMT_EN); // STE2 unused, not driven
 bflb_gpio_init(gpio,12,GPIO_OUTPUT|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_set(gpio,10);bflb_gpio_set(gpio,12);
 // SDK board_gpio.c native pads18/19 are MISO/MOSI. Dock14/15 are
 // MOSI/MISO, requiring explicit SPI data swap rather than inherited boot state.
 GLB_SPI_Sig_Swap_Set(GLB_SPI_SIG_SWAP_GRP_GPIO12_GPIO23,0);
 GLB_Swap_MCU_SPI_0_MOSI_With_MISO(ENABLE);
 bflb_gpio_init(gpio,13,GPIO_FUNC_SPI0|GPIO_ALTERNATE|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,14,GPIO_FUNC_SPI0|GPIO_ALTERNATE|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_gpio_init(gpio,15,GPIO_FUNC_SPI0|GPIO_ALTERNATE|GPIO_PULLUP|GPIO_SMT_EN|GPIO_DRV_1);
 bflb_spi_init(spi,&config);selected=BUS_NONE;return 0;
}
int hal_select(int target){
 if(target<0||target>BUS_FPGA)return -1;
 bflb_gpio_set(gpio,10);bflb_gpio_set(gpio,12);selected=BUS_NONE;bflb_mtimer_delay_us(1);
 if(target==BUS_SD)bflb_gpio_reset(gpio,12);else if(target==BUS_FPGA)bflb_gpio_reset(gpio,10);
 selected=target;return 0;
}
uint8_t hal_exchange(uint8_t value){return (uint8_t)bflb_spi_poll_send(spi,value);}
void hal_frequency(uint32_t hz){hal_select(BUS_NONE);config.freq=hz;bflb_spi_init(spi,&config);}
uint64_t hal_time_us(void){return bflb_mtimer_get_time_us();}
int hal_cancelled(void){return score_is_cancelled();}
void hal_delay_us(uint32_t us){bflb_mtimer_delay_us(us);}
