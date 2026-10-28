#include "audio_timebase.h"
#ifndef LIVE_LOOP_RUNTIME_H
#define LIVE_LOOP_RUNTIME_H
#include "s9_protocol.h"
/* Release admission: real RTL engine plus CS/RTOS/SD controller model.
 * Software budgets (40us/transaction,8ms pause,16ms per actual analysis) still need
 * first-board high-water verification; shared S11/PCM is separate below. */
#ifndef LL_QUALIFIED_ROWS_PER_SECOND
#define LL_QUALIFIED_ROWS_PER_SECOND 200u
#endif
#ifndef LL_QUALIFIED_WINDOW_EVENTS
#define LL_QUALIFIED_WINDOW_EVENTS 12u
#endif
#ifndef LL_QUALIFIED_WINDOW_GROUPS
#define LL_QUALIFIED_WINDOW_GROUPS 4u
#endif
#ifndef LL_QUALIFIED_WINDOW_ROWS
#define LL_QUALIFIED_WINDOW_ROWS 4u
#endif
#ifndef LL_QUALIFIED_WIRE_WINDOW_SAMPLES
#define LL_QUALIFIED_WIRE_WINDOW_SAMPLES AUDIO_MS(20)
#endif
#ifndef LL_QUALIFIED_WIRE_WINDOW_ROWS
#define LL_QUALIFIED_WIRE_WINDOW_ROWS 4u
#endif
#ifndef LL_QUALIFIED_MAX_LENGTH_SAMPLES
#define LL_QUALIFIED_MAX_LENGTH_SAMPLES (INSTRUMENT_AUDIO_HZ*16u)
#endif
/* These are independent combination qualifications. Zero rejects a new
 * simultaneous workload while preserving whichever business is active. */
#ifndef LL_QUALIFIED_SHARED_RECORD_ROWS
#define LL_QUALIFIED_SHARED_RECORD_ROWS 0u
#endif
#ifndef LL_QUALIFIED_SHARED_MEDIA_ROWS
#define LL_QUALIFIED_SHARED_MEDIA_ROWS 0u
#endif
#ifndef LL_QUALIFIED_SHARED_COMBINED_ROWS
#define LL_QUALIFIED_SHARED_COMBINED_ROWS 0u
#endif
enum {LL_SHARED_RECORD=1,LL_SHARED_MEDIA=2};
int ll_runtime_shared_enter(unsigned kind);
void ll_runtime_shared_leave(unsigned kind);
typedef struct {uint32_t max_prepare_us,max_response_us,max_exchange_us,software_over_budget;} ll_runtime_profile;
extern volatile ll_runtime_profile ll_runtime_high_water;
void ll_runtime_init(void);
int ll_runtime_request(const s9_message *);
/* One physical exchange; caller may pump at most four before yielding. */
int ll_runtime_step(void);
void ll_runtime_disconnect(void);
int ll_runtime_result(uint8_t result[36]);
int ll_runtime_ensemble_notice(uint8_t payload[64]);
int ll_runtime_notice(uint8_t payload[64]);
int ll_runtime_active(void);
#endif
