#ifndef SHARED_RAW_H
#define SHARED_RAW_H
#include <stdint.h>
#define RAW_PAGE_BYTES 512u
#define RAW_PACKET_BYTES 548u
#define RAW_STATUS_BYTES 32u
#define RAW_PAGE_CELLS 30u
enum {RAW_OPEN=1,RAW_PAGE=2,RAW_CLOSE=3,RAW_POLL=8};
enum {RAW_CREDIT=1,RAW_IS_OPEN=2,RAW_CAUGHT_UP=4,RAW_BARRIER_BUSY=8,RAW_PUBLISHED=16};
typedef struct {uint32_t epoch,accepted,now,audible,barrier;uint8_t error,flags,state;} raw_status;
typedef struct {uint32_t word;uint64_t token;} raw_item;
/* Exact audit/raw_contract.json revision2. Return encoded physical length. */
int raw_request(uint8_t out[RAW_PACKET_BYTES],unsigned command,uint32_t epoch,uint32_t sequence,const uint8_t page[512]);
int raw_decode(const uint8_t in[32],raw_status *);
void raw_page_begin(uint8_t page[512],uint32_t sequence);
int raw_head(uint8_t cell[16],uint32_t target,unsigned owner,unsigned timbre,unsigned teach,unsigned count,int last_target);
int raw_event(uint8_t cell[16],const raw_item *,int commit);
int raw_page_cell(uint8_t page[512],const uint8_t cell[16]);
int raw_page_row(uint8_t page[512],uint32_t target,unsigned owner,unsigned timbre,unsigned teach,const raw_item *,unsigned count,int last_target);
int raw_page_barrier(uint8_t page[512],uint32_t target,uint32_t id,unsigned sources,int all_revisions,uint16_t revision,int clear_guide);
void raw_page_finish(uint8_t page[512]);
#endif
