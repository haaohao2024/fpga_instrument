#ifndef AUDIO_TIMEBASE_H
#define AUDIO_TIMEBASE_H
#include <stdint.h>
/* Build-time native DAC clock, separate from the unchanged 48k PCM ingress. */
#ifndef INSTRUMENT_AUDIO_HZ
#define INSTRUMENT_AUDIO_HZ 48000u
#endif
#ifndef INSTRUMENT_SYS_HZ
#define INSTRUMENT_SYS_HZ 25000000u
#endif
/* Recorder-only PCM rate; output synthesis and event timestamps stay native. */
#ifndef RECORD_PCM_HZ
#define RECORD_PCM_HZ 48000u
#endif
#define RECORD_PCM_CAPACITY_PAIRS 3072u
#define RECORD_PCM_BUFFER_US ((RECORD_PCM_CAPACITY_PAIRS*1000000ull)/RECORD_PCM_HZ)
#define AUDIO_MS(ms) ((INSTRUMENT_AUDIO_HZ/1000u)*(ms))
static inline int audio_file_rate(uint32_t rate){return rate==48000u||rate==96000u||rate==128000u;}
/* Integer timestamp conversion with nearest-native-sample rounding. Splitting
 * quotient/remainder avoids overflow; ordering is monotonic; equal-time
 * events retain their original queue order. External PCM is still48kHz. */
static inline int audio_file_time(uint64_t value,uint32_t rate,uint64_t *out){
 if(!out||!audio_file_rate(rate)||INSTRUMENT_AUDIO_HZ<rate)return -1;
 uint64_t whole=value/rate;
 uint64_t tail=((value%rate)*(uint64_t)INSTRUMENT_AUDIO_HZ+rate/2u)/rate;
 if(whole>(UINT64_MAX-tail)/INSTRUMENT_AUDIO_HZ)return -1;
 *out=whole*INSTRUMENT_AUDIO_HZ+tail;return 0;
}
#endif
