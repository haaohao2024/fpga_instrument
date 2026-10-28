#ifndef S9_SCORE_CHECK_H
#define S9_SCORE_CHECK_H
#include <stdint.h>
typedef struct {
    uint64_t recent[128],last_time,end_time;
    uint32_t rate,records,seen,held,next_page;
    uint16_t recent_head,recent_count,group;
    uint8_t closed,ended,initialized;
} s9_score_check;
int s9_score_header(s9_score_check *state,const uint8_t page[512],uint32_t file_bytes);
int s9_score_page(s9_score_check *state,const uint8_t page[512]);
int s9_score_finish(const s9_score_check *state);
#endif
