#ifndef SD_PROOF_H
#define SD_PROOF_H
#include <stdint.h>
#ifndef RECORD_FIFO_PROOF
#define RECORD_FIFO_PROOF 1
#endif
typedef struct {
 uint32_t blocks,source_changes,feed_changes,rejects;
 uint32_t frozen,sector,index,before,feed,after,response,count;
} sd_proof_state;
extern volatile uint32_t sd_proof_feed_crc,sd_proof_feed_count,sd_proof_feed_enabled;
extern volatile uint32_t sd_proof_observe;
extern const uint16_t sd_proof_crc_nibble[16];
/* Observes the actual8-bit value immediately before the SDK writes WDATA.
 * This is CPU-to-FIFO evidence, NOT a measurement of external MOSI pins. */
static inline void sd_proof_feed_byte(uint8_t b){
 uint16_t c=(uint16_t)sd_proof_feed_crc;
 c=(uint16_t)((c<<4)^sd_proof_crc_nibble[(c>>12)^(b>>4)]);
 c=(uint16_t)((c<<4)^sd_proof_crc_nibble[(c>>12)^(b&15)]);
 sd_proof_feed_crc=c;sd_proof_feed_count++;
}
int sd_resume_config(unsigned policy);
int sd_proof_config(uint32_t hz,unsigned card_crc,unsigned observe);
void sd_proof_report(void);
const sd_proof_state *sd_proof_get(void);
#endif
