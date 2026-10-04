#ifndef S9_TASKS_BUS_H
#define S9_TASKS_BUS_H
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
int s9_tasks_bus_init(void);
void s9_tasks_bus_run(void *);
#ifdef S10_MEDIA_RUNTIME
/* Sole bus task only; neither callback recursively performs SD. */
int s9_tasks_bus_control_pending(void);
void s9_tasks_bus_control_service(void);
#endif
int s9_tasks_bus_command(const uint8_t *,unsigned);
int s9_tasks_bus_open(const uint8_t session[16]);
void s9_tasks_bus_close(void);
int s9_tasks_bus_status(uint8_t out[64]);
int s9_tasks_bus_initialized(void);
void s9_tasks_bus_peer_deadline(uint32_t now_ms);
void s9_tasks_bus_abort_disk(int value);
int s9_disk_cancelled(void);
#endif
