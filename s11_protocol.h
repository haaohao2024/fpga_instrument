#ifndef S11_PROTOCOL_H
#define S11_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>

/* S11P v1. All integers little endian. A data transaction clocks 580
 * bytes. ACK/no-data QUERY with reverse_max_bytes=0 clocks 68 bytes;
 * response is a snapshot prepared before CS. Legacy S7/S9/S10P v1
 * framing remains independent. CRC32 is IEEE reflected (same as S9). */
#define S11_WIRE_BYTES 580u
#define S11_SHORT_WIRE_BYTES 68u
#define S11_HEADER_BYTES 64u
#define S11_PAYLOAD_BYTES 512u
#define S11_HEADER_CRC_OFFSET 60u
#define S11_PACKET_CRC_OFFSET 576u
#define S11_PCM_PAIRS 128u
#define S11_CELL_BYTES 32u
#define S11_EVR_PAGE_CELLS 15u
#define S11_WAV_DATA_OFFSET 512u
#define S11_MAX_PCM_BYTES 1073741824u

enum {S11_MEDIA_NOP=0,S11_MEDIA_START=1,S11_MEDIA_DATA=2,S11_MEDIA_STOP=3,S11_MEDIA_STATUS=4};
enum {S11_REC_QUERY=0,S11_REC_START=1,S11_REC_STOP=2,S11_REC_ACK=3};
enum {S11_KIND_NONE=0,S11_KIND_PCM=1,S11_KIND_EVENT=2};
enum {S11_MASK_PCM=1,S11_MASK_EVENT=2};
enum {S11_STOPPED=0,S11_ARMING=1,S11_CAPTURING=2,S11_DRAINING=3,S11_CLOSED=4,S11_INCOMPLETE=5,S11_ERROR=6};
enum {S11_E_OK=0,S11_E_ARGUMENT=1,S11_E_OVERFLOW=2,S11_E_SEQUENCE=3,S11_E_CRC=4,
      S11_E_GENERATION=5,S11_E_STORAGE=6,S11_E_SERVICE=7,S11_E_UNSUPPORTED=8,S11_E_CANCELLED=9};

/* Request: media portion keeps S10 field offsets (new magic).
 * 0 magic S11P,4 version,5 media_op,6 pair_count16,8 media_epoch64,
 * 16 media_sequence32,20 source_start64,28 media_flags32 (TRACK bit0),
 * 32 recording_id64,40 recorder_op8,41 mask8,42 ACK-kind8,43 reserved,
 * 44 recorder_command_sequence32,48 ACK-block_sequence32,
 * 52 reverse_max_bytes16 (512=full,0=short),54 reserved16,56 reserved32,60 headerCRC32,
 * Full: 64 payload[512],576 packetCRC32. Padding is zero/included in CRC.
 * Short: no payload,64 packetCRC32 over bytes0..63; media pair_count=0.
 * Short permits ACK/no-data QUERY, media NOP/STATUS and pair_count=0;
 * never media DATA, START or STOP. Recorder START/STOP use full framing.
 * ACK retires a previously returned recorder block only. START/STOP are
 * command-sequence idempotent and have no effect on any performance source.
 */

/* Response: 0 S7ST (common legacy prefix; request magic selects S11),
 * 4 version,5 media_state8,6 recorder_state8,
 * 7 flags (bit0 block_valid,bit1 incomplete),8 media_epoch64,
 * 16 media_last_sequence32,20 media_credit16,22 block_kind8,23 mask8,
 * 24 recording_id64,32 last_committed_recorder_command32,
 * 36 block_sequence32,40 block_first_frame64,48 valid_bytes16,
 * 50 items16 (PCM pairs or event cells),52 recorder_error32,
 * 56 captured_pcm_pairs32 (file cap makes this exact),60 headerCRC32,
 * Full: 64 payload[512],576 packetCRC32. Short:64 packetCRC32.
 * Short response has no payload; its pre-CS frozen header may still describe
 * the held block. It cannot deliver or retire a new block merely by reading.
 * All response headers are frozen before CS, independently of request length.
 * When incomplete=1 and block_valid=0, field40 instead identifies the
 * first missing frame (UINT64_MAX if unavailable), PCM error before EVR.
 * Forward and reverse identities and credits are independent. An ACK only
 * commits after complete request length, CRC, CS and identity checks.
 */

/* S9 application envelope extensions. FILE commands keep session/sequence
 * reassembly and retry cache. DOWNLOAD_DATA is a separate notification type,
 * never a RESULT payload. */
enum {S11_APP_START=80,S11_APP_STOP=81,S11_APP_STATUS=82,S11_APP_DOWNLOAD=83,
      S11_APP_DOWNLOAD_CANCEL=84,S11_APP_EXPORT=85,S11_APP_FIELD_TEST=86,
      S11_APP_DOWNLOAD_DATA=129,S11_APP_RECORD_INFO=130};
/* START payload: record_id64, mask8, reserved[7] (16 bytes).
 * STOP/STATUS: record_id64 (8). DOWNLOAD: file_id64,offset64,length16,
 * kind8,reserved8 (20); length 1..480. CANCEL: file_id64 (8).
 * EXPORT: record_id64 (8). FIELD_TEST: op8 (START=1/STOP=2),voices8
 * (1/8/16/32 for START,0 for STOP),reserved[6] (8), channel CONFIG.
 * DOWNLOAD_DATA: file_id64,offset64,total_length64,chunk_crc32,
 * kind8,flags8,reserved16,data[0..480] (32+data bytes).
 * RECORD_INFO (72): recording_id64, storage_phase8 (idle0,capture1,
 * drain2,closed3,verify_pending4,saved5,incomplete6,error7),wire_state8,
 * mask8,flags8 (PCM_verified1,EVR_verified2,partial4),error32,
 * pcm_pairs64,event_cells64,pcm_file_bytes64,evr_file_bytes64,
 * pcm_file_crc32,evr_file_crc32,first_frame64,last_frame64.
 */

/* EVR1 cells are fixed 32 bytes; big transactions use ordered extension
 * cells with END_BATCH flag. Never discard unknown cell types on export.
 * 0 type8,1 flags8,2 source8,3 key8,4 cell_sequence32,8 frame_id64,
 * 16 persistent_note_id64,24 payload64.
 * Event payload: bits[15:0] clock-within-frame,[22:16] note,[30:23]
 * pressure,[33:31] timbre,[42:34] pan,[58:43] generation,[63:59] slot.
 * Identity/token/config extension payloads use all 64 bits; their parent
 * event supplies subframe time. Slot is diagnostic, never replay identity.
 */
enum {S11_CELL_START=1,S11_CELL_BIND_ID=2,S11_CELL_BIND_TOKEN=3,
      S11_CELL_NOTE_ON=4,S11_CELL_NOTE_OFF=5,S11_CELL_EXPRESSION=6,
      S11_CELL_VIBRATO=7,S11_CELL_CONTINUATION=8,S11_CELL_STEAL=9,
      S11_CELL_RECLAIM=10,S11_CELL_STALE=11,S11_CELL_REJECT=12,
      S11_CELL_ABORT=13,S11_CELL_TIMBRE=14,S11_CELL_GLIDE=15,
      S11_CELL_PAN=16,S11_CELL_EFFECTS=17,S11_CELL_GAIN=18,
      S11_CELL_KEYMAP=19,S11_CELL_MEDIA=20,S11_CELL_CONFIG_EXTENSION=21,
      S11_CELL_END=22,S11_CELL_OVERFLOW=23,S11_CELL_RESET=24,S11_CELL_PUBLISH=25};
#define S11_CELL_END_BATCH 1u
#define S11_CELL_INITIAL 2u
#define S11_CELL_DIAGNOSTIC 4u
#define S11_CELL_INCOMPLETE 8u
#define S11_CELL_RELEASE 16u /* INITIAL CONTINUATION has gate=0; never fake Attack. */

/* EVR file: 512-byte header (magic EVR1/version/record_id/time units and CRC);
 * pages: 28B header + 15*32B cells + CRC at508. Page header E11P,version,
 * valid_cells16,page_sequence32,record_id64,flags32,reserved32.
 * Final page has END cell and carries complete/incomplete state. */
#endif
