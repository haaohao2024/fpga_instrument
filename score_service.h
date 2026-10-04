#ifndef SCORE_SERVICE_H
#define SCORE_SERVICE_H
#include <stdint.h>
uint32_t score_crc(const uint8_t *b,unsigned n);
int score_open(uint64_t epoch);
int score_close(void);
int score_next(uint8_t page[512],uint32_t *sequence,uint64_t epoch);
void score_cancel(void);
int score_is_cancelled(void);
unsigned score_default_mode(void);
int score_send(uint8_t cmd,uint64_t epoch,uint32_t sequence,uint64_t arg,const uint8_t *payload,unsigned len,uint8_t response[32]);
int score_run_file(uint64_t epoch,uint8_t status[32]);
#endif
