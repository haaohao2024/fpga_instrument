// Dock31004 Rev1.4: GPIO12 SD-CS,13 SCK,14 MOSI,15 MISO,10 STE1.
// NEO secondary application HAL; physical board validation remains required.
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
 bflb_spi_init(spi,&config);selected=BUS_NONE;return 0;
}
int hal_select(int target){
 if(target<0||target>BUS_CONTROL)return -1;
 bflb_gpio_set(gpio,10);bflb_gpio_set(gpio,11);bflb_gpio_set(gpio,12);selected=BUS_NONE;bflb_mtimer_delay_us(1);
 if(target==BUS_SD)bflb_gpio_reset(gpio,12);else if(target==BUS_FPGA)bflb_gpio_reset(gpio,10);else if(target==BUS_CONTROL)bflb_gpio_reset(gpio,11);
 selected=target;return 0;
}
uint8_t hal_exchange(uint8_t value){return (uint8_t)bflb_spi_poll_send(spi,value);}
void hal_frequency(uint32_t hz){hal_select(BUS_NONE);config.freq=hz;bflb_spi_init(spi,&config);}
uint64_t hal_time_us(void){return bflb_mtimer_get_time_us();}
#ifdef S9_RUNTIME
extern int s9_disk_cancelled(void);
int hal_cancelled(void){return s9_disk_cancelled();}
#else
int hal_cancelled(void){return score_is_cancelled();}
#endif
void hal_delay_us(uint32_t us){bflb_mtimer_delay_us(us);}

#ifdef S10_MEDIA_RUNTIME
#include "s10_spi_dma.h"
/* Read the actual shared CS pad levels as well as the selected software
 * target. A conflict is a fault, never interpreted as BUS_NONE. */
int hal_bus_owner(void){
 int a=!bflb_gpio_read(gpio,10),b=!bflb_gpio_read(gpio,11),c=!bflb_gpio_read(gpio,12);
 if(a+b+c>1)return -1;
 int owner=a?BUS_FPGA:b?BUS_CONTROL:c?BUS_SD:BUS_NONE;
 return owner==selected?owner:-1;
}
int hal_media_dma_bind(s10_spi_dma *state,const s10_dma_binding *binding){
 struct bflb_device_s *tx=bflb_device_get_by_name("dma0_ch0"),*rx=bflb_device_get_by_name("dma0_ch1");
 if(!tx||!rx||!spi)return -1;
 return s10_spi_dma_bind(state,spi,tx,rx,binding);
}
#endif
