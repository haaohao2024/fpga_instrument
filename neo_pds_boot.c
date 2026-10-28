#include "bl616_glb.h"
/* The controller's PDS reset also covers USB PHY/control state. Complete
 * the first reset before clocks, USB, RTOS and services are initialized.
 * Later controller resets retain SDK behavior; only the initial reset
 * request consumes the already-performed bootstrap reset. */
static unsigned bootstrap_reset_pending;
volatile unsigned neo_pds_reset_count;
void neo_pds_bootstrap(void) {
 GLB_AHB_MCU_Software_Reset(GLB_AHB_MCU_SW_PDS);
 neo_pds_reset_count++;
 bootstrap_reset_pending=1;
}
void btblecontroller_software_pds_reset(void) {
 if(bootstrap_reset_pending){bootstrap_reset_pending=0;return;}
 GLB_AHB_MCU_Software_Reset(GLB_AHB_MCU_SW_PDS);
 neo_pds_reset_count++;
}
