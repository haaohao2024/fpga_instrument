#ifndef RECORD_BENCH_H
#define RECORD_BENCH_H
extern volatile unsigned record_bench_stress;
extern volatile unsigned record_bench_stage,record_bench_multi;
void record_bench_bus_pause(void);
#endif
