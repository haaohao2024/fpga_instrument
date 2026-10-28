#include "audio_timebase.h"
#include "live_loop_core.h"
#include <string.h>
_Static_assert(sizeof(ll_record)==16,"live loop arena record layout");
static uint8_t kind(uint32_t w){return (uint8_t)((w>>24)&15u);}
static uint64_t modulo(uint64_t value,uint64_t length){
    /* Release L<=16 seconds (1536000 samples at96k) and ordinary capture offsets fit32 bits:
     * use one hardware REMU instead of libgcc's generic64-bit routine. */
    if(value<=UINT32_MAX&&length<=UINT32_MAX)return (uint32_t)value%(uint32_t)length;
    return value%length;
}
/* Byte encoding avoids padding and unaligned word accesses on RV32. */
static uint32_t cache_get(const ll_core *c,uint16_t r){
 const uint8_t *p=c->phase_cache+3u*r;
 return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16);
}
static void cache_put(ll_core *c,uint16_t r,uint32_t value){
 uint8_t *p=c->phase_cache+3u*r;p[0]=(uint8_t)value;p[1]=(uint8_t)(value>>8);p[2]=(uint8_t)(value>>16);
}
static uint64_t phase(const ll_core *c,uint16_t r){
    if(c->phase_cache&&c->cache_length==c->length)return cache_get(c,r);
    return modulo(c->records[r].offset,c->length);
}
static uint64_t origin_phase(const ll_core *c,const ll_layer *l){return c->length<=UINT32_MAX?l->phase_base:modulo(l->play_start,c->length);}
static uint64_t global_phase(const ll_core *c,const ll_layer *l,uint16_t r){
    uint64_t origin=origin_phase(c,l),p=phase(c,r),room=c->length-origin;
    return p>=room?p-room:p+origin;
}
int ll_attach_phase_cache(ll_core *c,uint8_t *cache,uint16_t capacity){
    if(!c||!cache||capacity<c->capacity)return LL_E_ARGUMENT;
    c->phase_cache=cache;c->cache_length=0;return LL_OK;
}
int ll_prepare_phase_cache(ll_core *c,uint64_t length){
    if(!c||!length)return LL_E_ARGUMENT;
    if(!c->phase_cache)return LL_OK;
    if(length>UINT32_C(0x1000000))return LL_E_TIME;
    if(c->cache_length==length)return LL_OK;
    for(unsigned n=0;n<LL_LAYERS;n++)for(uint16_t r=c->layer[n].first;r!=LL_NONE;r=c->records[r].next)cache_put(c,r,(uint32_t)modulo(c->records[r].offset,length));
    c->cache_length=length;return LL_OK;
}
static int before(const ll_core *c,uint16_t a,uint16_t b){
    uint64_t pa=phase(c,a),pb=phase(c,b);
    if(pa!=pb)return pa<pb;
    /* Older occurrences at this phase precede newer ones. At the SAME
     * original timestamp preserve capture order, including ON then OFF.
     * Arena addresses are allocation identities, never event order. */
    return c->records[a].offset>c->records[b].offset;
}
static void release_layer(ll_core *c,unsigned n){
    ll_layer *l=&c->layer[n];uint16_t r=l->first;
    while(r!=LL_NONE){uint16_t next=c->records[r].next;c->records[r].next=c->free_head;c->free_head=r;c->used--;r=next;}
    memset(l,0,sizeof *l);l->first=l->last=l->cursor=LL_NONE;
    for(unsigned k=0;k<LL_INPUTS;k++)if(c->owner[k].valid&&c->owner[k].layer==n)c->owner[k].valid=0;
    if(c->recording==n)c->recording=UINT8_MAX;
    unsigned remains=0;
    for(unsigned i=0;i<LL_LAYERS;i++)if(c->layer[i].state==LL_COMMITTED||c->layer[i].state==LL_TAIL)remains++;
    if(!remains){c->length=c->anchor=c->cache_length=0;c->running=0;}
}
static int fail_new(ll_core *c,unsigned n,int error){
    /* Only the currently uncommitted layer can fail on recording/admission.
     * Existing committed layers and their immutable event lists survive. */
    c->last_failed_revision=c->layer[n].revision;
    release_layer(c,n);c->layer[n].state=LL_FAILED;c->error=error;return error;
}
void ll_init(ll_core *c,ll_record *arena,uint16_t capacity,ll_budget b){
    memset(c,0,sizeof *c);c->records=arena;c->capacity=capacity;c->budget=b;
    c->free_head=capacity?0:LL_NONE;c->recording=UINT8_MAX;c->next_revision=1;
    for(unsigned i=0;i<capacity;i++)arena[i].next=i+1u<capacity?(uint16_t)(i+1u):LL_NONE;
    for(unsigned i=0;i<LL_LAYERS;i++)c->layer[i].first=c->layer[i].last=c->layer[i].cursor=LL_NONE;
}
int ll_begin(ll_core *c,uint64_t start,uint8_t timbre,uint8_t *number){
    if(!c||!number||!c->records||!c->capacity||timbre>5)return LL_E_ARGUMENT;
    if(c->recording!=UINT8_MAX)return LL_E_STATE;
    if(!c->next_revision)return LL_E_ID;
    unsigned n=0;while(n<LL_LAYERS&&c->layer[n].state!=LL_EMPTY&&c->layer[n].state!=LL_FAILED)n++;
    if(n==LL_LAYERS)return LL_E_CAPACITY;
    ll_layer *l=&c->layer[n];memset(l,0,sizeof *l);l->first=l->last=l->cursor=LL_NONE;
    l->start=start;l->state=LL_CAPTURE;l->timbre=timbre;l->next_gesture=1;
    l->revision=c->next_revision++;c->recording=(uint8_t)n;c->error=0;*number=(uint8_t)n;
    return LL_OK;
}
static void insert(ll_core *c,ll_layer *l,uint16_t r){
    if(l->last==LL_NONE){l->first=l->last=r;c->records[r].next=LL_NONE;l->count++;return;}
    /* Captured first-cycle timestamps are naturally ordered. Preserve
     * stable same-sample order with O(1) append, including before L is known. */
    if(!c->length||!before(c,r,l->last)){
        c->records[l->last].next=r;c->records[r].next=LL_NONE;l->last=r;l->count++;return;
    }
    uint16_t *p=&l->first;
    while(*p!=LL_NONE&&!before(c,r,*p))p=&c->records[*p].next;
    c->records[r].next=*p;*p=r;l->count++;
}
static int due_for(const ll_core *c,const ll_layer *l,uint16_t r,uint32_t cycle,uint64_t *due){
    uint64_t p=phase(c,r),carry=c->records[r].offset/c->length;
    if(carry>cycle)return LL_IGNORED;
    if(cycle&&c->length>(UINT64_MAX-l->play_start)/cycle)return LL_E_TIME;
    uint64_t base=l->play_start+(uint64_t)cycle*c->length;
    if(p>UINT64_MAX-base)return LL_E_TIME;
    *due=base+p;return LL_OK;
}
static int seek(ll_core *c,ll_layer *l){
    /* Every recorded gesture starts before stop, so a nonempty valid layer
     * always has at least one carry-zero ON. At most two list passes. */
    for(uint32_t tries=0;tries<=l->count*2u;tries++){
        if(l->cursor==LL_NONE){if(l->cycle==UINT32_MAX)return LL_E_TIME;l->cycle++;l->cursor=l->first;}
        int r=due_for(c,l,l->cursor,l->cycle,&l->next_due);
        if(r==LL_OK)return LL_OK;
        if(r<0)return r;
        l->cursor=c->records[l->cursor].next;
    }
    return LL_E_STATE;
}
typedef struct {
    uint16_t cursor[LL_LAYERS];
    uint32_t remaining[LL_LAYERS];
    uint64_t at[LL_LAYERS];
} ll_scan;
typedef struct {uint64_t at;uint32_t events,rows;} ll_group;
static void scan_init(const ll_core *c,ll_scan *s){
    /* Rotate the FOUR phase-sorted lists at their absolute-origin wrap. */
    for(unsigned i=0;i<LL_LAYERS;i++)if(c->layer[i].state==LL_COMMITTED||c->layer[i].state==LL_TAIL){
        const ll_layer *l=&c->layer[i];
        uint64_t origin=origin_phase(c,l),threshold=origin?c->length-origin:0;
        s->cursor[i]=l->first;s->remaining[i]=l->count;
        for(uint16_t r=l->first;r!=LL_NONE;r=c->records[r].next)if(phase(c,r)>=threshold){s->cursor[i]=r;break;}
        s->at[i]=s->remaining[i]?global_phase(c,l,s->cursor[i]):UINT64_MAX;
    }else{s->cursor[i]=LL_NONE;s->remaining[i]=0;s->at[i]=UINT64_MAX;}
}
static int scan_group(const ll_core *c,ll_scan *s,ll_group *g){
    g->at=UINT64_MAX;g->events=g->rows=0;
    for(unsigned i=0;i<LL_LAYERS;i++)if(s->remaining[i]&&s->at[i]<g->at)g->at=s->at[i];
    if(g->at==UINT64_MAX)return 0;
    for(unsigned i=0;i<LL_LAYERS;i++){
        uint32_t count=0;
        while(s->remaining[i]&&s->at[i]==g->at){
            count++;s->remaining[i]--;s->cursor[i]=c->records[s->cursor[i]].next;
            if(s->cursor[i]==LL_NONE)s->cursor[i]=c->layer[i].first;
            s->at[i]=s->remaining[i]?global_phase(c,&c->layer[i],s->cursor[i]):UINT64_MAX;
        }
        g->events+=count;g->rows+=(count+8u)/9u;
    }
    return 1;
}
typedef struct {uint16_t cursor[LL_LAYERS],left[LL_LAYERS];uint32_t at[LL_LAYERS];} ll_scan32;
typedef struct {uint32_t at,events,rows;} ll_group32;
static void scan32_init(const ll_core *c,ll_scan32 *s){
    uint32_t length=(uint32_t)c->length;
    for(unsigned i=0;i<LL_LAYERS;i++){
        const ll_layer *l=&c->layer[i];s->left[i]=0;s->at[i]=UINT32_MAX;
        if(l->state!=LL_COMMITTED&&l->state!=LL_TAIL)continue;
        uint32_t base=l->phase_base,threshold=base?length-base:0;
        s->cursor[i]=l->first;s->left[i]=(uint16_t)l->count;
        for(uint16_t r=l->first;r!=LL_NONE;r=c->records[r].next)if(cache_get(c,r)>=threshold){s->cursor[i]=r;break;}
        if(s->left[i]){uint32_t p=cache_get(c,s->cursor[i]),room=length-base;s->at[i]=p>=room?p-room:p+base;}
    }
}
static int scan32_group(const ll_core *c,ll_scan32 *s,ll_group32 *g){
    g->at=UINT32_MAX;g->events=g->rows=0;
    for(unsigned i=0;i<LL_LAYERS;i++)if(s->left[i]&&s->at[i]<g->at)g->at=s->at[i];
    if(g->at==UINT32_MAX)return 0;
    for(unsigned i=0;i<LL_LAYERS;i++){
        uint32_t count=0;
        while(s->left[i]&&s->at[i]==g->at){
            count++;s->left[i]--;uint16_t r=c->records[s->cursor[i]].next;
            if(r==LL_NONE)r=c->layer[i].first;
            s->cursor[i]=r;
            if(s->left[i]){uint32_t p=cache_get(c,r),base=c->layer[i].phase_base,room=(uint32_t)c->length-base;s->at[i]=p>=room?p-room:p+base;}
        }
        if(count){
            if(count>12){g->events=13;g->rows=5;return 1;}
            g->events+=count;g->rows+=1u+(count>9u);
        }
    }
    return 1;
}
__attribute__((noinline)) static int analyze_ring(const ll_core *c,ll_analysis *a){
    /* Release's longer wire window admits at most4 rows, therefore at
     * most4 distinct target groups. One forward merge and this tiny ring
     * evaluate BOTH windows; invalid fifth groups reject immediately. */
    ll_scan32 initial,head;ll_group32 ring[4],g;unsigned first=0,count=0;uint32_t wire_rows=0;
    uint32_t length=(uint32_t)c->length,window=c->budget.wire_window_samples;
    scan32_init(c,&initial);
    for(unsigned pass=0;pass<2;pass++){
        head=initial;
        while(scan32_group(c,&head,&g)){
            if(pass&&g.at>=window)break;
            if(!pass){a->rows_per_period+=g.rows;if(g.events>a->peak_same_sample)a->peak_same_sample=g.events;}
            g.at+=pass?length:0;
            while(count&&g.at-ring[first].at>=window){wire_rows-=ring[first].rows;first=(first+1u)&3u;count--;}
            wire_rows+=g.rows;
            if(wire_rows>a->peak_wire_window_rows)a->peak_wire_window_rows=wire_rows;
            if(wire_rows>c->budget.max_wire_window_rows)return LL_E_ADMISSION;
            ring[(first+count)&3u]=g;count++;
            uint32_t events=0,groups=0,rows=0;
            for(unsigned i=0;i<count;i++){
                const ll_group32 *q=&ring[(first+i)&3u];
                if(g.at-q->at<c->budget.window_samples){events+=q->events;rows+=q->rows;groups++;}
            }
            if(events>a->peak_window_events)a->peak_window_events=events;
            if(rows>a->peak_window_rows)a->peak_window_rows=rows;
            if(groups>a->peak_window_groups)a->peak_window_groups=groups;
            if((c->budget.max_events_same_sample&&g.events>c->budget.max_events_same_sample)||
               (c->budget.max_window_events&&events>c->budget.max_window_events)||
               (c->budget.max_window_rows&&rows>c->budget.max_window_rows)||
               (c->budget.max_window_groups&&groups>c->budget.max_window_groups))return LL_E_ADMISSION;
        }
    }
    return LL_OK;
}
int ll_analyze(const ll_core *c,ll_analysis *a){
    if(!c||!a||!c->length)return LL_E_STATE;
    memset(a,0,sizeof *a);
    for(unsigned i=0;i<LL_LAYERS;i++)if(c->layer[i].state==LL_COMMITTED||c->layer[i].state==LL_TAIL)a->records+=c->layer[i].count;
#ifdef LL_ANALYSIS_ACCOUNT
    extern void ll_analysis_account(uint32_t records);
    ll_analysis_account(a->records);
#endif
    /* Merge twice with independent head/tail cursors for circular windows.
     * O(4*N), bounded metadata only: no N-sized index or quadratic scans. */
    int fast=c->phase_cache&&c->cache_length==c->length&&c->length<=UINT32_MAX/2u&&
        c->budget.window_samples&&c->budget.window_samples<=c->budget.wire_window_samples&&
        c->budget.wire_window_samples<=c->length&&c->budget.max_wire_window_rows&&c->budget.max_wire_window_rows<=4&&
        c->budget.max_window_events&&c->budget.max_window_events<=12;
    if(fast){int r=analyze_ring(c,a);if(r)return r;}
    else{
    ll_scan initial;scan_init(c,&initial);
    for(unsigned w=0;w<2;w++){
        uint64_t window=w?c->budget.wire_window_samples:c->budget.window_samples,tail_base=0;
        if(w&&!window)continue;
        if(window>c->length)return LL_E_ADMISSION;
        if(window&&c->length>UINT64_MAX-window)return LL_E_TIME;
        ll_scan head=initial,tail=initial;ll_group h,t;
        int tail_valid=scan_group(c,&tail,&t);
        uint32_t events=0,groups=0,rows_in_window=0;
        for(unsigned pass=0;pass<(window?2u:1u);pass++){
            if(pass)head=initial;
            while(scan_group(c,&head,&h)){
                if(pass&&h.at>=window)break;
                uint64_t at=h.at+(pass?c->length:0);
                if(!w&&!pass){a->rows_per_period+=h.rows;if(h.events>a->peak_same_sample)a->peak_same_sample=h.events;}
                if(!window)continue;
                events+=h.events;rows_in_window+=h.rows;groups++;
                while(tail_valid&&at-t.at>=window){
                    events-=t.events;rows_in_window-=t.rows;groups--;
                    tail_valid=scan_group(c,&tail,&t);
                    if(!tail_valid&&pass){tail_base+=c->length;tail=initial;tail_valid=scan_group(c,&tail,&t);}
                    if(tail_valid)t.at+=tail_base;
                }
                if(w){if(rows_in_window>a->peak_wire_window_rows)a->peak_wire_window_rows=rows_in_window;}
                else{
                    if(events>a->peak_window_events)a->peak_window_events=events;
                    if(groups>a->peak_window_groups)a->peak_window_groups=groups;
                    if(rows_in_window>a->peak_window_rows)a->peak_window_rows=rows_in_window;
                }
            }
        }
    }
    }
    uint64_t rate=((uint64_t)a->records*INSTRUMENT_AUDIO_HZ+c->length-1u)/c->length;
    if(rate>UINT32_MAX)return LL_E_ADMISSION;
    a->events_per_second=(uint32_t)rate;
    uint64_t rows=((uint64_t)a->rows_per_period*INSTRUMENT_AUDIO_HZ+c->length-1u)/c->length;
    if(rows>UINT32_MAX)return LL_E_ADMISSION;
    a->rows_per_second=(uint32_t)rows;
    if((c->budget.max_events_per_second&&rate>c->budget.max_events_per_second)||
       (c->budget.max_events_same_sample&&a->peak_same_sample>c->budget.max_events_same_sample)||
       (c->budget.max_rows_per_second&&rows>c->budget.max_rows_per_second)||
       (c->budget.max_window_events&&a->peak_window_events>c->budget.max_window_events)||
       (c->budget.max_window_groups&&a->peak_window_groups>c->budget.max_window_groups)||
       (c->budget.max_window_rows&&a->peak_window_rows>c->budget.max_window_rows)||
       (c->budget.max_wire_window_rows&&a->peak_wire_window_rows>c->budget.max_wire_window_rows))return LL_E_ADMISSION;
    return LL_OK;
}
int ll_capture_owner(ll_core *c,unsigned owner_index,uint64_t frame,uint64_t token,uint32_t w){
    if(!c)return LL_E_ARGUMENT;
    uint8_t source=(uint8_t)(w>>28),k=(uint8_t)(w>>16),op=kind(w);
    if(!((source==0&&k<LL_LOCAL_KEYS)||(source==2&&k<LL_PHONE_KEYS))||op<1||op>3)return LL_IGNORED;
    if(!token||w&1u||owner_index>=LL_INPUTS)return LL_E_ARGUMENT;
    ll_owner *o=&c->owner[owner_index];unsigned n;
    if(op==1){
        if(c->recording==UINT8_MAX)return LL_IGNORED;
        n=c->recording;ll_layer *l=&c->layer[n];
        if(l->state!=LL_CAPTURE||frame<l->start||(c->length&&frame-l->start>=c->length))return LL_IGNORED;
        if(o->valid)return fail_new(c,n,LL_E_ID);
        if(!l->next_gesture)return fail_new(c,n,LL_E_ID);
    }else{
        if(!o->valid||o->token!=token)return LL_IGNORED;
        n=o->layer;
        /* A sealed layer keeps its notes; late pressure only adds wire load. */
        if(op==3&&c->layer[n].state==LL_TAIL)return LL_IGNORED;
    }
    ll_layer *l=&c->layer[n];
    if(frame<l->start)return fail_new(c,n,LL_E_TIME);
    uint16_t r=c->free_head;if(r==LL_NONE)return fail_new(c,n,LL_E_CAPACITY);
    c->free_head=c->records[r].next;c->used++;
    if(op==1){o->token=token;o->gesture=l->next_gesture++;o->layer=(uint8_t)n;o->valid=1;l->held++;}
    c->records[r]=(ll_record){frame-l->start,w,LL_NONE,o->gesture};
    if(c->phase_cache&&c->cache_length)cache_put(c,r,(uint32_t)modulo(frame-l->start,c->cache_length));
    insert(c,l,r);
    if(op==2){o->valid=0;l->held--;}
    if(l->state==LL_TAIL){
        if(c->budget.max_events_per_second||c->budget.max_events_same_sample||c->budget.max_rows_per_second||c->budget.window_samples||c->budget.wire_window_samples){
            if(c->capture_batch){c->pending_admission_layer=(uint8_t)n;c->pending_admission_revision=l->revision;}
            else{ll_analysis a;int result=ll_analyze(c,&a);if(result)return fail_new(c,n,result);}
        }
        /* Insertion can place a newly received cross-boundary OFF/EXPR
         * before the pending cursor. Its first eligible occurrence is
         * still in the future: play_start is later than capture start. */
        uint64_t carry=c->records[r].offset/c->length,due;
        if(carry>UINT32_MAX)return fail_new(c,n,LL_E_TIME);
        uint32_t cyc=l->cycle;if(cyc<carry)cyc=(uint32_t)carry;
        if(due_for(c,l,r,cyc,&due)==LL_OK){
            if(c->cursor_watch&&(!l->pending_insert_valid||due<l->pending_insert_due||(due==l->pending_insert_due&&before(c,r,l->pending_insert_record)))){
                l->pending_insert_valid=1;l->pending_insert_record=r;l->pending_insert_cycle=cyc;l->pending_insert_due=due;
            }
            if(due<l->next_due||(due==l->next_due&&before(c,r,l->cursor))){
                if(l->emitted&&due<=l->last_due)return fail_new(c,n,LL_E_TIME);
                l->cursor=r;l->cycle=cyc;l->next_due=due;
            }
        }
        if(!l->held){l->state=LL_COMMITTED;c->recording=UINT8_MAX;}
    }
    return LL_OK;
}
int ll_capture_batch_begin(ll_core *c){
    if(!c||c->capture_batch)return LL_E_STATE;
    c->capture_batch=1;c->pending_admission_revision=0;return LL_OK;
}
int ll_capture_batch_end(ll_core *c){
    if(!c||!c->capture_batch)return LL_E_STATE;
    c->capture_batch=0;unsigned n=c->pending_admission_layer;uint16_t revision=c->pending_admission_revision;c->pending_admission_revision=0;
    if(!revision||n>=LL_LAYERS||c->layer[n].revision!=revision)return LL_OK;
    ll_analysis a;int r=ll_analyze(c,&a);return r?fail_new(c,n,r):LL_OK;
}
void ll_cursor_watch(ll_core *c,int active){
    c->cursor_watch=(uint8_t)!!active;if(active)for(unsigned i=0;i<LL_LAYERS;i++)c->layer[i].pending_insert_valid=0;
}
int ll_commit_cursor(ll_core *c,unsigned n,const ll_layer *queued){
    if(n>=LL_LAYERS||c->layer[n].revision!=queued->revision)return LL_E_STATE;
    ll_layer *l=&c->layer[n];uint16_t r=l->pending_insert_record;uint64_t due=l->pending_insert_due;uint32_t cycle=l->pending_insert_cycle;unsigned pending=l->pending_insert_valid;
    if(pending&&queued->emitted&&due<=queued->last_due)return fail_new(c,n,LL_E_TIME);
    l->cursor=queued->cursor;l->cycle=queued->cycle;l->next_due=queued->next_due;l->last_due=queued->last_due;l->emitted=queued->emitted;l->pending_insert_valid=0;
    if(pending&&(due<l->next_due||(due==l->next_due&&before(c,r,l->cursor)))){l->cursor=r;l->cycle=cycle;l->next_due=due;}
    return LL_OK;
}
int ll_refresh_cursor(const ll_core *c,unsigned n,ll_layer *q){
    if(n>=LL_LAYERS||!c->length||c->layer[n].revision!=q->revision)return LL_E_STATE;
#ifdef LL_ANALYSIS_ACCOUNT
    extern void ll_analysis_account(uint32_t records);
    ll_analysis_account(c->layer[n].count);
#endif
    uint64_t base_cycle=q->emitted?(q->last_due-q->play_start)/c->length:0,best=UINT64_MAX;uint16_t record=LL_NONE;uint32_t chosen=0;
    for(uint16_t r=c->layer[n].first;r!=LL_NONE;r=c->records[r].next){
        uint64_t carry=c->records[r].offset/c->length,cycle=base_cycle;if(cycle<carry)cycle=carry;
        uint64_t p=phase(c,r);if(p>UINT64_MAX-q->play_start||cycle>(UINT64_MAX-q->play_start-p)/c->length)return LL_E_TIME;
        uint64_t due=q->play_start+cycle*c->length+p;
        if(q->emitted&&due<=q->last_due){if(cycle==UINT32_MAX||due>UINT64_MAX-c->length)return LL_E_TIME;cycle++;due+=c->length;}
        if(cycle>UINT32_MAX)return LL_E_TIME;
        if(due<best){best=due;record=r;chosen=(uint32_t)cycle;}
    }
    if(record==LL_NONE)return LL_E_STATE;
    q->cursor=record;q->cycle=chosen;q->next_due=best;return LL_OK;
}
int ll_capture(ll_core *c,uint64_t frame,uint64_t token,uint32_t w){
    unsigned source=w>>28,key=(w>>16)&255u;
    return ll_capture_owner(c,(source==2?LL_LOCAL_KEYS:0u)+key,frame,token,w);
}
unsigned ll_drop_expression(ll_core *c,unsigned n){
    if(!c||n>=LL_LAYERS)return 0;
    ll_layer *l=&c->layer[n];uint16_t *p=&l->first,last=LL_NONE;unsigned dropped=0;
    while(*p!=LL_NONE){
        uint16_t r=*p;
        if(kind(c->records[r].original_word)==3){*p=c->records[r].next;c->records[r].next=c->free_head;c->free_head=r;c->used--;l->count--;dropped++;}
        else{last=r;p=&c->records[r].next;}
    }
    l->last=last;return dropped;
}
int ll_close(ll_core *c,uint64_t stop,uint64_t play_start){
    if(!c||c->recording==UINT8_MAX)return LL_E_STATE;
    unsigned n=c->recording;ll_layer *l=&c->layer[n];
    if(l->state!=LL_CAPTURE||stop<=l->start||play_start<stop)return LL_E_TIME;
    if(c->capture_watermark<stop)return LL_E_STATE;
    if(c->length&&stop-l->start!=c->length)return LL_E_TIME;
    if(c->budget.max_length_samples&&stop-l->start>c->budget.max_length_samples)return fail_new(c,n,LL_E_ADMISSION);
    if(!l->count)return fail_new(c,n,LL_E_STATE);
    if(!c->length){c->length=stop-l->start;c->anchor=play_start;}
    l->end=stop;l->play_start=play_start;l->phase_base=(uint32_t)modulo(play_start,c->length);l->state=LL_TAIL;
    int cache_result=ll_prepare_phase_cache(c,c->length);if(cache_result)return fail_new(c,n,cache_result);
    /* Before first close the list was chronological. Reinsert into phase
     * order so OFF exactly at length precedes the next iteration's ON. */
    uint16_t old=l->first;l->first=l->last=LL_NONE;l->count=0;
    while(old!=LL_NONE){uint16_t next=c->records[old].next;insert(c,l,old);old=next;}
    ll_analysis a;int result=ll_analyze(c,&a);
    if(result==LL_E_ADMISSION&&ll_drop_expression(c,n))result=ll_analyze(c,&a);
    if(result)return fail_new(c,n,result);
    l->cursor=l->first;l->cycle=0;l->scheduled=1;c->running=1;
    result=seek(c,l);if(result)return fail_new(c,n,result);
    if(!l->held){l->state=LL_COMMITTED;c->recording=UINT8_MAX;}
    return LL_OK;
}
int ll_peek(ll_core *c,uint64_t through,ll_delivery *out){
    if(!c||!out)return LL_E_ARGUMENT;
    if(!c->running)return LL_IGNORED;
    unsigned best=LL_LAYERS;
    for(unsigned n=0;n<LL_LAYERS;n++){
        ll_layer *l=&c->layer[n];if(!l->scheduled||l->cursor==LL_NONE||l->next_due>through)continue;
        if(l->state==LL_TAIL){
            uint64_t delay=l->play_start-l->start;
            if(c->capture_watermark>UINT64_MAX-delay)return LL_E_TIME;
            if(l->next_due>c->capture_watermark+delay)continue;
        }
        if(best==LL_LAYERS||l->next_due<c->layer[best].next_due)best=n;
    }
    if(best==LL_LAYERS||c->layer[best].next_due>through)return LL_IGNORED;
    ll_layer *l=&c->layer[best];ll_record *r=&c->records[l->cursor];
    uint64_t carry=r->offset/c->length;if(carry>l->cycle)return LL_E_STATE;
    uint64_t token=((uint64_t)l->revision<<48)|((uint64_t)(l->cycle-(uint32_t)carry)<<16)|r->gesture;
    unsigned original_key=(uint8_t)(r->original_word>>16),original_source=r->original_word>>28;
    uint32_t w=(r->original_word&0x0f00ffffu)|0x30000000u|((uint32_t)(best*64u+(original_source==2?32u:0u)+original_key)<<16);
    *out=(ll_delivery){l->next_due,token,w,l->cursor,l->revision,(uint8_t)best,l->timbre};
    return LL_OK;
}
int ll_pop(ll_core *c,const ll_delivery *d){
    if(!c||!d||d->layer>=LL_LAYERS)return LL_E_ARGUMENT;
    ll_layer *l=&c->layer[d->layer];
    if(!c->running||!l->scheduled||d->revision!=l->revision||d->record!=l->cursor||d->due!=l->next_due)return LL_E_ID;
    l->last_due=d->due;l->emitted=1;
    l->cursor=c->records[l->cursor].next;int result=seek(c,l);
    if(result){c->running=0;c->error=result;}return result;
}
int ll_undo(ll_core *c,uint16_t *revision){
    if(!c||!revision)return LL_E_ARGUMENT;
    for(unsigned n=LL_LAYERS;n>0;n--)if(c->layer[n-1].state!=LL_EMPTY&&c->layer[n-1].state!=LL_FAILED){
        *revision=c->layer[n-1].revision;release_layer(c,n-1);return LL_OK;
    }
    return LL_E_STATE;
}
void ll_stop(ll_core *c){
    if(!c)return;
    c->running=0;
    if(c->recording!=UINT8_MAX)release_layer(c,c->recording);
}
int ll_resume(ll_core *c,uint64_t play_start){
    if(!c||!c->length||c->recording!=UINT8_MAX)return LL_E_STATE;
    unsigned count=0;
    for(unsigned n=0;n<LL_LAYERS;n++)if(c->layer[n].state==LL_COMMITTED)count++;
    if(!count)return LL_E_STATE;
    if(!c->next_revision||count>65536u-c->next_revision)return LL_E_ID;
    for(unsigned n=0;n<LL_LAYERS;n++)if(c->layer[n].state==LL_COMMITTED){
        uint64_t old=c->layer[n].play_start%c->length,anchor=c->anchor%c->length;
        uint64_t relative=old>=anchor?old-anchor:c->length-(anchor-old);
        if(relative>UINT64_MAX-play_start)return LL_E_TIME;
    }
    for(unsigned n=0;n<LL_LAYERS;n++)if(c->layer[n].state==LL_COMMITTED){
        ll_layer *l=&c->layer[n];uint64_t old=l->play_start%c->length,anchor=c->anchor%c->length;
        uint64_t relative=old>=anchor?old-anchor:c->length-(anchor-old);
        l->revision=c->next_revision++;l->play_start=play_start+relative;l->phase_base=(uint32_t)modulo(l->play_start,c->length);
        l->cursor=l->first;l->cycle=0;l->emitted=0;l->scheduled=1;
        int result=seek(c,l);if(result){c->running=0;c->error=result;return result;}
    }
    c->anchor=play_start;c->running=1;return LL_OK;
}
int ll_disconnect(ll_core *c,uint16_t *revision){
    if(!c||!revision)return LL_E_ARGUMENT;
    *revision=0;
    if(c->recording==UINT8_MAX)return LL_OK;
    unsigned n=c->recording;*revision=c->layer[n].revision;release_layer(c,n);return LL_OK;
}
void ll_clear(ll_core *c){
    if(!c)return;
    for(unsigned n=0;n<LL_LAYERS;n++)release_layer(c,n);
    c->length=c->anchor=0;c->running=0;c->error=0;c->capture_watermark=0;
    /* next_revision deliberately survives undo/clear: audible old tails
     * can never match a new layer's ON/OFF identity. */
}
int ll_extend_sample(uint64_t previous,uint32_t sample,uint64_t *extended){
    uint32_t delta=sample-(uint32_t)previous;
    if(!extended||delta>=0x80000000u||previous>UINT64_MAX-delta)return LL_E_TIME;
    *extended=previous+delta;return LL_OK;
}
int ll_watermark(ll_core *c,uint64_t through){
    if(!c||through<c->capture_watermark)return LL_E_TIME;
    c->capture_watermark=through;return LL_OK;
}
