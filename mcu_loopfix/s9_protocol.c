#include "record_hot.h"
#include "s9_protocol.h"
#include "live_loop_wire.h"
#include "ensemble.h"
#include "s11_protocol.h"
#include <string.h>

RECORD_HOT uint16_t s9_get16(const uint8_t *p) { return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1] << 8); }
RECORD_HOT uint32_t s9_get32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
RECORD_HOT uint64_t s9_get64(const uint8_t *p) { return (uint64_t)s9_get32(p) | (uint64_t)s9_get32(p+4)<<32; }
RECORD_HOT void s9_put16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
RECORD_HOT void s9_put32(uint8_t *p, uint32_t v) { for (unsigned i=0;i<4;i++) p[i]=(uint8_t)(v>>(8*i)); }
RECORD_HOT void s9_put64(uint8_t *p, uint64_t v) { for (unsigned i=0;i<8;i++) p[i]=(uint8_t)(v>>(8*i)); }
const uint32_t crc32Tab[256] RECORD_CONST={
 UINT32_C(0x00000000),UINT32_C(0x77073096),UINT32_C(0xee0e612c),UINT32_C(0x990951ba),UINT32_C(0x076dc419),UINT32_C(0x706af48f),UINT32_C(0xe963a535),UINT32_C(0x9e6495a3),
 UINT32_C(0x0edb8832),UINT32_C(0x79dcb8a4),UINT32_C(0xe0d5e91e),UINT32_C(0x97d2d988),UINT32_C(0x09b64c2b),UINT32_C(0x7eb17cbd),UINT32_C(0xe7b82d07),UINT32_C(0x90bf1d91),
 UINT32_C(0x1db71064),UINT32_C(0x6ab020f2),UINT32_C(0xf3b97148),UINT32_C(0x84be41de),UINT32_C(0x1adad47d),UINT32_C(0x6ddde4eb),UINT32_C(0xf4d4b551),UINT32_C(0x83d385c7),
 UINT32_C(0x136c9856),UINT32_C(0x646ba8c0),UINT32_C(0xfd62f97a),UINT32_C(0x8a65c9ec),UINT32_C(0x14015c4f),UINT32_C(0x63066cd9),UINT32_C(0xfa0f3d63),UINT32_C(0x8d080df5),
 UINT32_C(0x3b6e20c8),UINT32_C(0x4c69105e),UINT32_C(0xd56041e4),UINT32_C(0xa2677172),UINT32_C(0x3c03e4d1),UINT32_C(0x4b04d447),UINT32_C(0xd20d85fd),UINT32_C(0xa50ab56b),
 UINT32_C(0x35b5a8fa),UINT32_C(0x42b2986c),UINT32_C(0xdbbbc9d6),UINT32_C(0xacbcf940),UINT32_C(0x32d86ce3),UINT32_C(0x45df5c75),UINT32_C(0xdcd60dcf),UINT32_C(0xabd13d59),
 UINT32_C(0x26d930ac),UINT32_C(0x51de003a),UINT32_C(0xc8d75180),UINT32_C(0xbfd06116),UINT32_C(0x21b4f4b5),UINT32_C(0x56b3c423),UINT32_C(0xcfba9599),UINT32_C(0xb8bda50f),
 UINT32_C(0x2802b89e),UINT32_C(0x5f058808),UINT32_C(0xc60cd9b2),UINT32_C(0xb10be924),UINT32_C(0x2f6f7c87),UINT32_C(0x58684c11),UINT32_C(0xc1611dab),UINT32_C(0xb6662d3d),
 UINT32_C(0x76dc4190),UINT32_C(0x01db7106),UINT32_C(0x98d220bc),UINT32_C(0xefd5102a),UINT32_C(0x71b18589),UINT32_C(0x06b6b51f),UINT32_C(0x9fbfe4a5),UINT32_C(0xe8b8d433),
 UINT32_C(0x7807c9a2),UINT32_C(0x0f00f934),UINT32_C(0x9609a88e),UINT32_C(0xe10e9818),UINT32_C(0x7f6a0dbb),UINT32_C(0x086d3d2d),UINT32_C(0x91646c97),UINT32_C(0xe6635c01),
 UINT32_C(0x6b6b51f4),UINT32_C(0x1c6c6162),UINT32_C(0x856530d8),UINT32_C(0xf262004e),UINT32_C(0x6c0695ed),UINT32_C(0x1b01a57b),UINT32_C(0x8208f4c1),UINT32_C(0xf50fc457),
 UINT32_C(0x65b0d9c6),UINT32_C(0x12b7e950),UINT32_C(0x8bbeb8ea),UINT32_C(0xfcb9887c),UINT32_C(0x62dd1ddf),UINT32_C(0x15da2d49),UINT32_C(0x8cd37cf3),UINT32_C(0xfbd44c65),
 UINT32_C(0x4db26158),UINT32_C(0x3ab551ce),UINT32_C(0xa3bc0074),UINT32_C(0xd4bb30e2),UINT32_C(0x4adfa541),UINT32_C(0x3dd895d7),UINT32_C(0xa4d1c46d),UINT32_C(0xd3d6f4fb),
 UINT32_C(0x4369e96a),UINT32_C(0x346ed9fc),UINT32_C(0xad678846),UINT32_C(0xda60b8d0),UINT32_C(0x44042d73),UINT32_C(0x33031de5),UINT32_C(0xaa0a4c5f),UINT32_C(0xdd0d7cc9),
 UINT32_C(0x5005713c),UINT32_C(0x270241aa),UINT32_C(0xbe0b1010),UINT32_C(0xc90c2086),UINT32_C(0x5768b525),UINT32_C(0x206f85b3),UINT32_C(0xb966d409),UINT32_C(0xce61e49f),
 UINT32_C(0x5edef90e),UINT32_C(0x29d9c998),UINT32_C(0xb0d09822),UINT32_C(0xc7d7a8b4),UINT32_C(0x59b33d17),UINT32_C(0x2eb40d81),UINT32_C(0xb7bd5c3b),UINT32_C(0xc0ba6cad),
 UINT32_C(0xedb88320),UINT32_C(0x9abfb3b6),UINT32_C(0x03b6e20c),UINT32_C(0x74b1d29a),UINT32_C(0xead54739),UINT32_C(0x9dd277af),UINT32_C(0x04db2615),UINT32_C(0x73dc1683),
 UINT32_C(0xe3630b12),UINT32_C(0x94643b84),UINT32_C(0x0d6d6a3e),UINT32_C(0x7a6a5aa8),UINT32_C(0xe40ecf0b),UINT32_C(0x9309ff9d),UINT32_C(0x0a00ae27),UINT32_C(0x7d079eb1),
 UINT32_C(0xf00f9344),UINT32_C(0x8708a3d2),UINT32_C(0x1e01f268),UINT32_C(0x6906c2fe),UINT32_C(0xf762575d),UINT32_C(0x806567cb),UINT32_C(0x196c3671),UINT32_C(0x6e6b06e7),
 UINT32_C(0xfed41b76),UINT32_C(0x89d32be0),UINT32_C(0x10da7a5a),UINT32_C(0x67dd4acc),UINT32_C(0xf9b9df6f),UINT32_C(0x8ebeeff9),UINT32_C(0x17b7be43),UINT32_C(0x60b08ed5),
 UINT32_C(0xd6d6a3e8),UINT32_C(0xa1d1937e),UINT32_C(0x38d8c2c4),UINT32_C(0x4fdff252),UINT32_C(0xd1bb67f1),UINT32_C(0xa6bc5767),UINT32_C(0x3fb506dd),UINT32_C(0x48b2364b),
 UINT32_C(0xd80d2bda),UINT32_C(0xaf0a1b4c),UINT32_C(0x36034af6),UINT32_C(0x41047a60),UINT32_C(0xdf60efc3),UINT32_C(0xa867df55),UINT32_C(0x316e8eef),UINT32_C(0x4669be79),
 UINT32_C(0xcb61b38c),UINT32_C(0xbc66831a),UINT32_C(0x256fd2a0),UINT32_C(0x5268e236),UINT32_C(0xcc0c7795),UINT32_C(0xbb0b4703),UINT32_C(0x220216b9),UINT32_C(0x5505262f),
 UINT32_C(0xc5ba3bbe),UINT32_C(0xb2bd0b28),UINT32_C(0x2bb45a92),UINT32_C(0x5cb36a04),UINT32_C(0xc2d7ffa7),UINT32_C(0xb5d0cf31),UINT32_C(0x2cd99e8b),UINT32_C(0x5bdeae1d),
 UINT32_C(0x9b64c2b0),UINT32_C(0xec63f226),UINT32_C(0x756aa39c),UINT32_C(0x026d930a),UINT32_C(0x9c0906a9),UINT32_C(0xeb0e363f),UINT32_C(0x72076785),UINT32_C(0x05005713),
 UINT32_C(0x95bf4a82),UINT32_C(0xe2b87a14),UINT32_C(0x7bb12bae),UINT32_C(0x0cb61b38),UINT32_C(0x92d28e9b),UINT32_C(0xe5d5be0d),UINT32_C(0x7cdcefb7),UINT32_C(0x0bdbdf21),
 UINT32_C(0x86d3d2d4),UINT32_C(0xf1d4e242),UINT32_C(0x68ddb3f8),UINT32_C(0x1fda836e),UINT32_C(0x81be16cd),UINT32_C(0xf6b9265b),UINT32_C(0x6fb077e1),UINT32_C(0x18b74777),
 UINT32_C(0x88085ae6),UINT32_C(0xff0f6a70),UINT32_C(0x66063bca),UINT32_C(0x11010b5c),UINT32_C(0x8f659eff),UINT32_C(0xf862ae69),UINT32_C(0x616bffd3),UINT32_C(0x166ccf45),
 UINT32_C(0xa00ae278),UINT32_C(0xd70dd2ee),UINT32_C(0x4e048354),UINT32_C(0x3903b3c2),UINT32_C(0xa7672661),UINT32_C(0xd06016f7),UINT32_C(0x4969474d),UINT32_C(0x3e6e77db),
 UINT32_C(0xaed16a4a),UINT32_C(0xd9d65adc),UINT32_C(0x40df0b66),UINT32_C(0x37d83bf0),UINT32_C(0xa9bcae53),UINT32_C(0xdebb9ec5),UINT32_C(0x47b2cf7f),UINT32_C(0x30b5ffe9),
 UINT32_C(0xbdbdf21c),UINT32_C(0xcabac28a),UINT32_C(0x53b39330),UINT32_C(0x24b4a3a6),UINT32_C(0xbad03605),UINT32_C(0xcdd70693),UINT32_C(0x54de5729),UINT32_C(0x23d967bf),
 UINT32_C(0xb3667a2e),UINT32_C(0xc4614ab8),UINT32_C(0x5d681b02),UINT32_C(0x2a6f2b94),UINT32_C(0xb40bbe37),UINT32_C(0xc30c8ea1),UINT32_C(0x5a05df1b),UINT32_C(0x2d02ef8d),
};
RECORD_HOT uint32_t s9_crc32_update(uint32_t c,const uint8_t *p,size_t n){
 while(n--)c=crc32Tab[(c^*p++)&255u]^(c>>8);
 return c;
}
RECORD_HOT uint32_t s9_crc32(const uint8_t *p,size_t n){return ~s9_crc32_update(UINT32_C(0xffffffff),p,n);}

int s9_decode(const uint8_t *b, size_t n, s9_message *m) {
    if(!b || !m || n<S9_HEADER_BYTES+S9_CRC_BYTES || n>S9_MAX_MESSAGE) return S9_E_LENGTH;
    if(memcmp(b,"S9AP",4) || b[4]!=S9_VERSION || b[5]>S9_CH_STATUS || b[7] || b[30] || b[31]) return S9_E_FORMAT;
    unsigned length=s9_get16(b+28);
    if(length>S9_MAX_PAYLOAD || n!=S9_HEADER_BYTES+length+S9_CRC_BYTES) return S9_E_LENGTH;
    if(b[5]<S9_CH_FILE && n>S9_MAX_CONTROL_MESSAGE) return S9_E_LENGTH;
    if(s9_crc32(b,n-4)!=s9_get32(b+n-4)) return S9_E_CRC;
    if(!s9_get64(b+8) || !s9_get64(b+16)) return S9_E_SESSION;
    if(s9_get32(b+24)==0) return S9_E_SEQUENCE;
    m->channel=b[5];m->opcode=b[6];m->session=b+8;m->sequence=s9_get32(b+24);
    m->length=(uint16_t)length;m->payload=b+32;
    return S9_OK;
}
static int zeros(const uint8_t *p, unsigned n) { while(n--) if(*p++) return 0; return 1; }
int s9_validate_request(const s9_message *m) {
    const uint8_t *p=m->payload; unsigned n=m->length;
    if(m->channel==S9_CH_RT) {
        if(m->opcode!=S9_OP_EVENTS || !n || n%S9_EVENT_BYTES || n>S9_MAX_EVENTS*S9_EVENT_BYTES) return S9_E_FORMAT;
        for(unsigned i=0;i<n;i+=S9_EVENT_BYTES) {
            const uint8_t *r=p+i; unsigned kind=r[8],key=r[9],note=r[10],value=r[11];
            if(!zeros(r+12,4) || kind<1 || kind>4 || note>127) return S9_E_RANGE;
            if(kind==4) { if(s9_get64(r)!=0 || key!=255 || note) return S9_E_RANGE; }
            else {
                if(!s9_get64(r) || key>=S9_KEY_COUNT) return S9_E_RANGE;
                if(kind==1 && value==0) return S9_E_RANGE;
                if(kind==2 && (note || value)) return S9_E_RANGE;
            }
        }
        return S9_OK;
    }
    if(m->channel==S9_CH_CFG) {
        switch(m->opcode) {
        case ENS_START:{ens_config c;return n==8?ens_decode_config(p,&c):S9_E_LENGTH;}
        case ENS_STOP:case ENS_STATUS:case ENS_METRICS:return n==0?S9_OK:S9_E_LENGTH;
        case S9_OP_HELLO: case S9_OP_KEEPALIVE: case S9_OP_DISCONNECT:
            return n==0?S9_OK:S9_E_LENGTH;
        case S9_OP_QUERY_RESULT:
            return n==5 && p[0]<=S9_CH_FILE && s9_get32(p+1)!=0?S9_OK:S9_E_RANGE;
        case S9_OP_BARRIER:
            return n==8 && p[0]<=S9_CH_CFG && p[1]>=S9_PHASE_COMMITTED && p[1]<=S9_PHASE_TARGET_REACHED && zeros(p+2,2) && s9_get32(p+4)!=0?S9_OK:S9_E_RANGE;
        case LL_APP_BEGIN: return n==1&&p[0]<=5?S9_OK:S9_E_RANGE;
        case LL_APP_END: case LL_APP_UNDO: case LL_APP_STOP: case LL_APP_CLEAR: case LL_APP_STATUS: case LL_APP_PLAY: return n==0?S9_OK:S9_E_LENGTH;
        case S9_OP_TIMBRE: return n==1 && p[0]<=S9_MAX_TIMBRE?S9_OK:S9_E_RANGE;
        case S9_OP_GLIDE: return n==1 && p[0]<=S9_MAX_GLIDE?S9_OK:S9_E_RANGE;
        case S9_OP_PAN:
            return n==16 && s9_get64(p)!=0 && s9_get16(p+10)<=S9_MAX_PAN && zeros(p+12,4)?S9_OK:S9_E_RANGE;
        case S9_OP_GAIN:
            return n==8 && s9_get16(p)<=S9_UNITY_GAIN && s9_get16(p+2)<=S9_UNITY_GAIN && p[4]<=3 && zeros(p+5,3)?S9_OK:S9_E_RANGE;
        case S9_OP_KEYMAP:
            if(n!=S9_KEYMAP_COUNT) return S9_E_LENGTH;
            for(unsigned i=0;i<n;i++) if(p[i]<S9_KEYMAP_MIN || p[i]>S9_KEYMAP_MAX) return S9_E_RANGE;
            return S9_OK;
        case S9_OP_INSTANCE:
            return n==9 && p[0]<S9_KEY_COUNT && s9_get64(p+1)!=0?S9_OK:S9_E_RANGE;
        case S9_OP_PLAY:
            return n==8 && p[0]>=1 && p[0]<=6 && p[0]!=2 && zeros(p+2,6) &&
                ((p[0]==1 && p[1]<=3) || (p[0]==6 && p[1]<=1) || ((p[0]==3 || p[0]==4 || p[0]==5) && p[1]==0))?S9_OK:S9_E_RANGE;
        case S11_APP_FIELD_TEST:
            return n==8&&zeros(p+2,6)&&((p[0]==1&&(p[1]==1||p[1]==8||p[1]==16||p[1]==32))||(p[0]==2&&p[1]==0))?S9_OK:S9_E_RANGE;
        case S9_OP_EFFECTS: {
            if(n!=44) return S9_E_LENGTH;
            uint32_t w[11]; for(unsigned i=0;i<11;i++) w[i]=s9_get32(p+4*i);
            if(w[0]>127 || w[1]<S9_DELAY_MIN || w[1]>S9_DELAY_MAX || w[2]>S9_DELAY_FEEDBACK_MAX ||
               w[3]<S9_CHORUS_BASE_MIN || w[3]>S9_CHORUS_BASE_MAX || w[4]>S9_CHORUS_DEPTH_MAX ||
               w[3]<w[4]+2 || w[3]+w[4]>S9_CHORUS_ADDRESS_MAX ||
               (w[5]!=0 && (w[5]<S9_CHORUS_STEP_MIN || w[5]>S9_CHORUS_STEP_MAX)) ||
               w[6]>S9_FDN_COEFFICIENT_MAX || w[7]>S9_FDN_COEFFICIENT_MAX ||
               w[8]>S9_WET_GAIN_MAX || w[9]>S9_WET_GAIN_MAX || w[10]>S9_WET_GAIN_MAX) return S9_E_RANGE;
            return S9_OK;
        }
        default: return S9_E_FORMAT;
        }
    }
    if(m->channel==S9_CH_FILE) {
        switch(m->opcode) {
        case S11_APP_START:return n==16&&s9_get64(p)&&p[8]&&p[8]<=3&&zeros(p+9,7)?S9_OK:S9_E_RANGE;
        case S11_APP_STOP:case S11_APP_STATUS:case S11_APP_DOWNLOAD_CANCEL:case S11_APP_EXPORT:return n==8&&s9_get64(p)?S9_OK:S9_E_RANGE;
        case S11_APP_DOWNLOAD:return n==20&&s9_get64(p)&&s9_get64(p+8)<=S11_MAX_PCM_BYTES+512ull&&s9_get16(p+16)>0&&s9_get16(p+16)<=480&&(p[18]==1||p[18]==2)&&!p[19]?S9_OK:S9_E_RANGE;
        case S9_OP_UPLOAD_BEGIN:
            return n==16 && s9_get32(p)>=1024 && s9_get32(p)<=S9_MAX_SCORE_BYTES && s9_get32(p)%512==0 && zeros(p+8,8)?S9_OK:S9_E_RANGE;
        case S9_OP_UPLOAD_DATA:
            if(n<=12 || n>512 || s9_get64(p)>S9_MAX_SCORE_BYTES || (uint64_t)(n-12)>S9_MAX_SCORE_BYTES-s9_get64(p)) return S9_E_RANGE;
            return s9_crc32(p+12,n-12)==s9_get32(p+8)?S9_OK:S9_E_CRC;
        case S9_OP_UPLOAD_COMMIT: case S9_OP_UPLOAD_CANCEL: return n==0?S9_OK:S9_E_LENGTH;
        default: return S9_E_FORMAT;
        }
    }
    return S9_E_FORMAT;
}
int s9_encode(uint8_t *out, size_t cap, uint8_t ch, uint8_t op, const uint8_t sid[16], uint32_t seq, const uint8_t *p, uint16_t n) {
    size_t count=(size_t)n+S9_HEADER_BYTES+S9_CRC_BYTES;
    if(!out || !sid || (!p && n) || n>S9_MAX_PAYLOAD || cap<count || ch>S9_CH_STATUS || (ch<S9_CH_FILE && count>S9_MAX_CONTROL_MESSAGE)) return S9_E_LENGTH;
    memset(out,0,32);memcpy(out,"S9AP",4);out[4]=S9_VERSION;out[5]=ch;out[6]=op;
    memcpy(out+8,sid,16);s9_put32(out+24,seq);s9_put16(out+28,n);
    if(n) memcpy(out+32,p,n);
    s9_put32(out+32+n,s9_crc32(out,32+n));return (int)count;
}
void s9_reassembly_reset(s9_reassembly *r) { r->active=0;r->used=0; }
int s9_fragment_push(s9_reassembly *r, uint8_t ch, const uint8_t *f, size_t count, uint32_t now, uint16_t *complete) {
    if(!r || !f || !complete || ch>S9_CH_FILE || count<S9_FRAGMENT_HEADER) return S9_E_LENGTH;
    *complete=0;
    uint32_t seq=s9_get32(f); unsigned offset=s9_get16(f+4), n=s9_get16(f+6);
    unsigned limit=ch==S9_CH_FILE?S9_MAX_MESSAGE:S9_MAX_CONTROL_MESSAGE;
    if(!seq || !n || count!=S9_FRAGMENT_HEADER+n || offset>limit || n>limit-offset) return S9_E_LENGTH;
    uint32_t idle=ch==S9_CH_FILE?S9_FILE_IDLE_MS:S9_CONTROL_IDLE_MS;
    uint32_t total=ch==S9_CH_FILE?S9_FILE_TOTAL_MS:S9_CONTROL_TOTAL_MS;
    if(r->active && ((uint32_t)(now-r->progress_ms)>=idle || (uint32_t)(now-r->started_ms)>=total)) {
        s9_reassembly_reset(r);return S9_E_TIMEOUT;
    }
    if(!r->active) {
        if(offset) return S9_E_SEQUENCE;
        r->active=1;r->used=0;r->message_sequence=seq;r->started_ms=now;r->progress_ms=now;
    }
    if(r->message_sequence!=seq) return S9_E_BUSY;
    if(offset>r->used) return S9_E_SEQUENCE;
    if(offset<r->used) {
        if(offset+n>r->used || memcmp(r->bytes+offset,f+8,n)) return S9_E_CONFLICT;
    } else {
        memcpy(r->bytes+offset,f+8,n);r->used=(uint16_t)(offset+n);r->progress_ms=now;
    }
    if(r->used>=32) {
        unsigned expected=32u+s9_get16(r->bytes+28)+4u;
        if(expected>limit || r->used>expected) { s9_reassembly_reset(r);return S9_E_LENGTH; }
        if(r->used==expected) {
            s9_message m;int result=s9_decode(r->bytes,r->used,&m);
            if(result!=S9_OK) { s9_reassembly_reset(r);return result; }
            if(m.channel!=ch || m.sequence!=seq) { s9_reassembly_reset(r);return S9_E_SEQUENCE; }
            *complete=r->used;return S9_COMPLETE;
        }
    }
    return S9_MORE;
}
