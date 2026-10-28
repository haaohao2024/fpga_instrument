#ifndef SD_LEASE_H
#define SD_LEASE_H
/* Local capture defaults to6ms; explicit native tests may quote8ms. Mixed stays2ms. */
#define SD_MIXED_LEASE_US 2000u
#define SD_LOCAL_LEASE_US 6000u
#define SD_NATIVE_MAX_LEASE_US 8000u
static inline unsigned sd_lease_ceiling(int mixed){return mixed?SD_MIXED_LEASE_US:SD_NATIVE_MAX_LEASE_US;}
#endif
