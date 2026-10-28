#include "s9_protocol.h"
#include "live_loop_wire.h"
#include "ensemble.h"
#include "s11_protocol.h"
#include <string.h>

uint16_t s9_get16(const uint8_t *p) { return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1] << 8); }
uint32_t s9_get32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
uint64_t s9_get64(const uint8_t *p) { return (uint64_t)s9_get32(p) | (uint64_t)s9_get32(p+4)<<32; }
void s9_put16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
void s9_put32(uint8_t *p, uint32_t v) { for (unsigned i=0;i<4;i++) p[i]=(uint8_t)(v>>(8*i)); }
void s9_put64(uint8_t *p, uint64_t v) { for (unsigned i=0;i<8;i++) p[i]=(uint8_t)(v>>(8*i)); }
uint32_t s9_crc32(const uint8_t *p, size_t n) {
    uint32_t c=UINT32_C(0xffffffff);
    while(n--) { c^=*p++; for(unsigned i=0;i<8;i++) c=(c>>1)^((c&1)?UINT32_C(0xedb88320):0); }
    return c^UINT32_C(0xffffffff);
}
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
