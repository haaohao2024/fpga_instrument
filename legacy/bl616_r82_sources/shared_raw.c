#include "shared_raw.h"
#include "s9_protocol.h"
#include <string.h>
int raw_request(uint8_t out[548],unsigned command,uint32_t epoch,uint32_t sequence,const uint8_t page[512]){
 if(!out||!epoch||(command!=RAW_OPEN&&command!=RAW_PAGE&&command!=RAW_CLOSE&&command!=RAW_POLL)||(command==RAW_PAGE?!page:sequence!=0))return -1;
 unsigned n=command==RAW_PAGE?512:0;memset(out,0,548);memcpy(out,"S7PK",4);out[4]=2;out[5]=(uint8_t)command;
 s9_put64(out+8,epoch);s9_put32(out+16,sequence);s9_put16(out+20,(uint16_t)n);if(n)memcpy(out+32,page,n);
 s9_put32(out+32+n,s9_crc32(out,32+n));return (int)(36+n);
}
int raw_decode(const uint8_t in[32],raw_status *s){
 if(!in||!s)return -1;
 if(memcmp(in,"S7ST",4)||in[4]!=2)return -2;
 if(s9_get32(in+28)!=s9_crc32(in,28))return -3;
 if(in[5]>6||(in[6]&~31u)||in[7]>4)return -4;
 *s=(raw_status){s9_get32(in+8),s9_get32(in+12),s9_get32(in+16),s9_get32(in+20),s9_get32(in+24),in[5],in[6],in[7]};return 0;
}
void raw_page_begin(uint8_t p[512],uint32_t sequence){memset(p,0,512);s9_put32(p,sequence);}
int raw_head(uint8_t h[16],uint32_t target,unsigned owner,unsigned timbre,unsigned teach,unsigned n,int last){
 if(!h||!n||n>9||(owner!=1&&owner!=3)||timbre>5||teach>1||(owner==1&&timbre)||(owner==3&&teach))return -1;
 memset(h,0,16);s9_put32(h,target);s9_put32(h+12,0x52480000u|teach<<4|(last!=0)<<5|owner<<6|timbre<<8|n<<11);return 0;
}
int raw_event(uint8_t q[16],const raw_item *a,int commit){
 unsigned source=a?a->word>>28:0,kind=a?(a->word>>24)&15u:0;
 if(!q||!a||!a->token||(a->word&1u)||(source!=1&&source!=3)||kind<1||kind>3||(source==1&&((a->word>>16)&255u)>=32))return -1;
 memset(q,0,16);s9_put32(q,a->word);s9_put64(q+4,a->token);s9_put32(q+12,commit!=0);return 0;
}
int raw_page_cell(uint8_t p[512],const uint8_t c[16]){unsigned n=s9_get16(p+4);if(n>=30)return -1;memcpy(p+16+n*16,c,16);s9_put16(p+4,(uint16_t)(n+1));return 0;}
int raw_page_row(uint8_t p[512],uint32_t target,unsigned owner,unsigned timbre,unsigned teach,const raw_item *a,unsigned n,int last){
 unsigned used=s9_get16(p+4);if(!a||!n||n>9||used+n+1>30||(owner!=1&&owner!=3)||timbre>5||teach>1||(owner==1&&timbre)||(owner==3&&teach))return -1;
 for(unsigned i=0;i<n;i++)if(!a[i].token||(a[i].word&1u)||(a[i].word>>28)!=owner||((a[i].word>>24)&15u)<1||((a[i].word>>24)&15u)>3||(owner==1&&((a[i].word>>16)&255u)>=32))return -1;
 uint8_t *h=p+16+used*16;raw_head(h,target,owner,timbre,teach,n,last);
 for(unsigned i=0;i<n;i++){uint8_t *q=h+16*(i+1);s9_put32(q,a[i].word);s9_put64(q+4,a[i].token);s9_put32(q+12,last&&i+1==n?1:0);}
 s9_put16(p+4,(uint16_t)(used+n+1));return 0;
}
int raw_page_barrier(uint8_t p[512],uint32_t target,uint32_t id,unsigned sources,int all,uint16_t rev,int guide){
 unsigned used=s9_get16(p+4);if(used==30||!id||sources>3||all<0||all>1||guide<0||guide>1||(guide&&!(sources&1))||
 ((sources&2)?(all?rev!=0:rev==0):(all||rev))||(!sources&&(all||rev||guide)))return -1;
 uint8_t *h=p+16+used*16;s9_put32(h,target);s9_put32(h+4,sources|(unsigned)all<<2|(uint32_t)rev<<3|(unsigned)guide<<19);s9_put32(h+8,id);s9_put32(h+12,0x52480021u);
 s9_put16(p+4,(uint16_t)(used+1));return 0;
}
void raw_page_finish(uint8_t p[512]){s9_put32(p+508,s9_crc32(p,508));}
