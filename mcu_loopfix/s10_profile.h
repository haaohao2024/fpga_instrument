#ifndef S10_PROFILE_H
#define S10_PROFILE_H
#include <stdint.h>
#include "s10_media_pipeline.h"
int s10_profile_prepare(s10_media_pipeline *pipeline);
/* Only after the one existing bt_enable completed successfully. */
int s10_profile_enable(void);
/* Sole media worker. Does not wait or perform SPI/SD. */
int s10_profile_step(void);
int s10_profile_busy(void);
int s10_profile_last_error(void);
/* Read-only A2DP ingress counters for the 2 s UART status line. */
int s10_profile_diag(char *text,unsigned size);
#endif
