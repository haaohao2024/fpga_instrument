#ifndef S10_SPI_DMA_H
#define S10_SPI_DMA_H
#include <stddef.h>
#include <stdint.h>
#include "bflb_dma.h"

#define S10_DMA_ALIGNMENT 32u
#define S10_DMA_MAX_BYTES 580u
enum { S10_DMA_IDLE=0, S10_DMA_RUNNING=1, S10_DMA_ABORTING=2, S10_DMA_RETIRED=3 };
enum { S10_DMA_PENDING=0, S10_DMA_DONE=1, S10_DMA_CANCELLED=2,
       S10_DMA_ARGUMENT=-1, S10_DMA_BUSY=-2, S10_DMA_OWNER=-3,
       S10_DMA_TIMEOUT=-4, S10_DMA_FIFO=-5, S10_DMA_SETUP=-6 };
typedef struct {
    void *user;
    uint64_t (*time_us)(void *user);
    /* owner returns 0 iff every shared CS is high, otherwise exactly the
     * requested logical bus target. A conflicted CS set must return -1. */
    int (*owner)(void *user);
    int (*select)(void *user, int target);
    /* Must validate that the complete cache-line extent belongs to a
     * DMA-accessible SRAM allocation. No implicit PSRAM support. */
    int (*dma_ram)(void *user, const void *address, size_t extent);
} s10_dma_binding;

typedef struct __attribute__((aligned(S10_DMA_ALIGNMENT))) {
    struct bflb_device_s *spi, *tx_channel, *rx_channel;
    s10_dma_binding binding;
    struct bflb_dma_channel_lli_pool_s tx_lli[1] __attribute__((aligned(32)));
    struct bflb_dma_channel_lli_pool_s rx_lli[1] __attribute__((aligned(32)));
    const uint8_t *tx;
    uint8_t *rx;
    size_t bytes, cache_extent;
    uint64_t token, last_token, started_us;
    uint32_t timeout_us;
    int target, result;
    volatile uint8_t tx_terminal, rx_terminal;
    uint8_t state, initialized;
    uint32_t completed, cancelled, timed_out, owner_faults, early_release_rejected;
    void (*wakeup)(void *user);
    void *wakeup_user;
} s10_spi_dma;

/* Bind only a zero-initialized or explicitly released object. This does not
 * configure board pins or install an application startup path. Channels are
 * dedicated to the unique bus task; APIs must not run in BLE callbacks. */
int s10_spi_dma_bind(s10_spi_dma *state, struct bflb_device_s *spi,
                    struct bflb_device_s *tx_channel,
                    struct bflb_device_s *rx_channel,
                    const s10_dma_binding *binding);
/* Optional ISR notification only. Set/disable after bind while IDLE, before
 * starting jobs. The callback must not use SPI/SD/Codec or mutate this object;
 * it may notify the sole bus task with its platform's ISR-safe primitive.
 * Callback presence never proves transfer retirement or permits buffer reuse. */
int s10_spi_dma_set_wakeup(s10_spi_dma *state, void (*callback)(void *), void *user);
/* Monotonically increasing nonzero token is a bus transaction identity,
 * separate from BLE session and PCM epoch. Both buffers remain exclusively
 * owned until poll retires AND release succeeds. Negative poll results do
 * not alone authorize memory reuse. Buffers must be separate 32-byte-aligned
 * complete cache-line allocations, capacity >= ceil(bytes/32)*32. */
int s10_spi_dma_begin(s10_spi_dma *state, uint64_t token, int target,
                     uint32_t frequency, const void *tx, size_t tx_capacity,
                     void *rx, size_t rx_capacity, size_t bytes,
                     uint32_t timeout_us);
int s10_spi_dma_poll(s10_spi_dma *state, uint64_t token);
int s10_spi_dma_cancel(s10_spi_dma *state, uint64_t token);
int s10_spi_dma_release(s10_spi_dma *state, uint64_t token);
int s10_spi_dma_is_retired(const s10_spi_dma *state, uint64_t token);
#endif
