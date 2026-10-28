#include "bflb_spi.h"
#include "bflb_mtimer.h"
#include "hardware/spi_reg.h"
#include "sd_proof.h"
#include <errno.h>
#undef romapi_bflb_spi_poll_exchange
static uint32_t proof_wdata;
static inline void proof_putreg(uint32_t v,uint32_t addr){
 if(sd_proof_feed_enabled&&addr==proof_wdata)sd_proof_feed_byte((uint8_t)v);
 putreg32(v,addr);
}
#define putreg32(v,a) proof_putreg((v),(a))
ATTR_TCM_SECTION int __wrap_bflb_spi_poll_exchange(struct bflb_device_s *dev, const void *txbuffer, void *rxbuffer, size_t nbytes)
{
#ifdef romapi_bflb_spi_poll_exchange
    return romapi_bflb_spi_poll_exchange(dev, txbuffer, rxbuffer, nbytes);
#else
    proof_wdata=dev->reg_base+SPI_FIFO_WDATA_OFFSET;
    sd_proof_feed_crc=0;sd_proof_feed_count=0;sd_proof_feed_enabled=txbuffer!=0&&sd_proof_observe;
    uint32_t regval;
    uint32_t reg_base = dev->reg_base;
    uint32_t tx_cnt;
    uint8_t fifo_cnt, frame_size;
    uint64_t start_time;

    /* get frame size */
    regval = getreg32(reg_base + SPI_CONFIG_OFFSET);
    frame_size = ((regval & SPI_CR_SPI_FRAME_SIZE_MASK) >> SPI_CR_SPI_FRAME_SIZE_SHIFT) + 1;
    if (frame_size == 3) {
        frame_size = 4;
    }

    nbytes /= frame_size;
    tx_cnt = nbytes;

#if 0
    /* Wait for tx FIFO to be empty */
#if (SPI_FIFO_WIDTH_VARIABLE_SUPPORT)
    do {
        regval = getreg32(reg_base + SPI_FIFO_CONFIG_1_OFFSET);
        fifo_cnt = (regval & SPI_TX_FIFO_CNT_MASK) >> SPI_TX_FIFO_CNT_SHIFT;
    } while (fifo_cnt < SPI_FIFO_BYTE_NUM_MAX);
#else
    do {
        regval = getreg32(reg_base + SPI_FIFO_CONFIG_1_OFFSET);
        fifo_cnt = (regval & SPI_TX_FIFO_CNT_MASK) >> SPI_TX_FIFO_CNT_SHIFT;
    } while (fifo_cnt < SPI_FIFO_WORD_NUM_MAX);
#endif

    /* Wait for SPI to idle */
    do {
        regval = getreg32(reg_base + SPI_BUS_BUSY_OFFSET);
    } while (regval);

    /* clear fifo */
    regval = getreg32(reg_base + SPI_FIFO_CONFIG_0_OFFSET);
    regval |= SPI_TX_FIFO_CLR;
    regval |= SPI_RX_FIFO_CLR;
    putreg32(regval, reg_base + SPI_FIFO_CONFIG_0_OFFSET);

#endif

    /* clear fifo */
    regval = getreg32(reg_base + SPI_FIFO_CONFIG_0_OFFSET);
    regval |= SPI_TX_FIFO_CLR;
    regval |= SPI_RX_FIFO_CLR;
    putreg32(regval, reg_base + SPI_FIFO_CONFIG_0_OFFSET);

    /* get tx fifo cnt */
    regval = getreg32(reg_base + SPI_FIFO_CONFIG_1_OFFSET);
#if (SPI_FIFO_WIDTH_VARIABLE_SUPPORT)
    fifo_cnt = ((regval & SPI_TX_FIFO_CNT_MASK) >> SPI_TX_FIFO_CNT_SHIFT) / frame_size;
#else
    fifo_cnt = ((regval & SPI_TX_FIFO_CNT_MASK) >> SPI_TX_FIFO_CNT_SHIFT);
#endif

    /* first fill tx fifo */
    fifo_cnt = fifo_cnt > nbytes ? nbytes : fifo_cnt;
    tx_cnt -= fifo_cnt;
    if (txbuffer != NULL) {
        /* Send valid data */
        for (; fifo_cnt > 0; fifo_cnt--) {
            switch (frame_size) {
                case 1:
                    regval = *(uint8_t *)txbuffer;
                    putreg32(regval, reg_base + SPI_FIFO_WDATA_OFFSET);
                    txbuffer = (uint8_t *)txbuffer + 1;
                    break;
                case 2:
                    regval = *(uint16_t *)txbuffer;
                    putreg32(regval, reg_base + SPI_FIFO_WDATA_OFFSET);
                    txbuffer = (uint8_t *)txbuffer + 2;
                    break;
                case 4:
                    regval = *(uint32_t *)txbuffer;
                    putreg32(regval, reg_base + SPI_FIFO_WDATA_OFFSET);
                    txbuffer = (uint8_t *)txbuffer + 4;
                    break;
                default:
                    break;
            }
        }
    } else {
        /* Send idle Data */
        for (; fifo_cnt > 0; fifo_cnt--) {
            putreg32(BFLB_SPI_IDEL_DATA, reg_base + SPI_FIFO_WDATA_OFFSET);
        }
    }

    /* read and write rest of the data */
    start_time = bflb_mtimer_get_time_ms();
    for (; nbytes > 0;) {
        /* get rx fifo cnt */
        regval = getreg32(reg_base + SPI_FIFO_CONFIG_1_OFFSET);

#if (SPI_FIFO_WIDTH_VARIABLE_SUPPORT)
        fifo_cnt = ((regval & SPI_RX_FIFO_CNT_MASK) >> SPI_RX_FIFO_CNT_SHIFT) / frame_size;
#else
        fifo_cnt = ((regval & SPI_RX_FIFO_CNT_MASK) >> SPI_RX_FIFO_CNT_SHIFT);
#endif
        if (fifo_cnt) {
            fifo_cnt = fifo_cnt > nbytes ? nbytes : fifo_cnt;
            nbytes -= fifo_cnt;
            start_time = bflb_mtimer_get_time_ms();
        } else {
            if ((bflb_mtimer_get_time_ms() - start_time) > 100) {
                return -ETIMEDOUT;
            }
        }

        /* read and write data */
        for (; fifo_cnt > 0; fifo_cnt--) {
            regval = getreg32(reg_base + SPI_FIFO_RDATA_OFFSET);
            switch (frame_size) {
                case 1:
                    if (rxbuffer) {
                        *((uint8_t *)rxbuffer) = (uint8_t)regval;
                        rxbuffer = (uint8_t *)rxbuffer + 1;
                    }
                    if (tx_cnt) {
                        if (txbuffer) {
                            regval = *(uint8_t *)txbuffer;
                            putreg32(regval, reg_base + SPI_FIFO_WDATA_OFFSET);
                            txbuffer = (uint8_t *)txbuffer + 1;
                        } else {
                            putreg32(BFLB_SPI_IDEL_DATA, reg_base + SPI_FIFO_WDATA_OFFSET);
                        }
                        tx_cnt--;
                    }
                    break;
                case 2:
                    if (rxbuffer) {
                        *((uint16_t *)rxbuffer) = (uint16_t)regval;
                        rxbuffer = (uint8_t *)rxbuffer + 2;
                    }
                    if (tx_cnt) {
                        if (txbuffer) {
                            regval = *(uint16_t *)txbuffer;
                            putreg32(regval, reg_base + SPI_FIFO_WDATA_OFFSET);
                            txbuffer = (uint8_t *)txbuffer + 2;
                        } else {
                            putreg32(BFLB_SPI_IDEL_DATA, reg_base + SPI_FIFO_WDATA_OFFSET);
                        }
                        tx_cnt--;
                    }
                    break;
                case 4:
                    if (rxbuffer) {
                        *((uint32_t *)rxbuffer) = (uint32_t)regval;
                        rxbuffer = (uint8_t *)rxbuffer + 4;
                    }
                    if (tx_cnt) {
                        if (txbuffer) {
                            regval = *(uint32_t *)txbuffer;
                            putreg32(regval, reg_base + SPI_FIFO_WDATA_OFFSET);
                            txbuffer = (uint8_t *)txbuffer + 4;
                        } else {
                            putreg32(BFLB_SPI_IDEL_DATA, reg_base + SPI_FIFO_WDATA_OFFSET);
                        }
                        tx_cnt--;
                    }
                    break;
                default:
                    break;
            }
        }
    }
    return 0;
#endif
}
