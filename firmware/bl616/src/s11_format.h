#ifndef S11_FORMAT_H
#define S11_FORMAT_H
#include "s11_protocol.h"
/* EVR1 header: version u32@4, recording_id u64@8, sample_rate u32@16,
 * clock_hz u32@20, cell_count u32@24, page_count u32@28, first_frame u64@32,
 * last_frame u64@40, missing_frame u64@48, file_phase u8@56, mask u8@57,
 * error i16@58, reserved zero through507, CRC32@508.
 * E11P: version u16@4, cells u16@6, page_seq u32@8, recording_id u64@12,
 * flags u32@20, reserved u32@24, 15 cells@28, IEEE CRC32@508.
 * PCM WAV data starts512; RIFF size504+4N, fmt PCM16 stereo48k, JUNK460.
 * New recordings: EVR2 remains native128k; PCM indices are48k.
 * MET2 keeps PCM first/last/missing@56/64/72, rates@80/84, native origin@88,
 * event first/last/missing@96/104/112, clock@120, ratio3/8@124/126,
 * delay335/768000sec@128/132, CRC@508. Read MET1 by legacy WAV/EVR rates.
 * W/E/M + seven-digit file numbers are allocated independently of full64
 * recording_id. MET lookup checks the persisted64-bit identity. Retained
 * TMP files reserve their filename number; duplicate persisted IDs reject.
 * S11M MET512: version u32@4, recording_id u64@8, kinds u8@16,
 * storage_phase u8@17, PCM pairs u32@20, EVR cells u32@24, pages u32@28,
 * PCM data bytes u32@32, full-file CRC32 PCM@36/EVR@40,
 * payload CRC32 PCM@44/EVR@48, first/last frame u64@56/64,
 * IEEE CRC32@508 over bytes0..507. Normal SAVED bytes52..55 and72..79
 * remain zero. INCOMPLETE/ERROR uses error i32@52 and first_missing u64@72
 * (UINT64_MAX when unknown); partial files never qualify for DOWNLOAD.
 */
enum {S11_EVR_HEADER_BYTES=512,S11_EVR_PAGE_BYTES=512};
#endif
