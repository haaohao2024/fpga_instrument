// Validated logical phone commands -> frozen Performance Event packets.
// Session/CRC/sequence deduplication is upstream. One packet may be outstanding
// until allocator publication; close drains offered work then releases source2.
module s9_phone_events # (parameter integer TOKEN_WIDTH=64) (
    input wire clk,rst,
    input wire session_open,session_close,
    output wire open_ready,
    output reg active,closing,
    output reg close_done,
    input wire command_valid,
    output wire command_ready,
    input wire [3:0] command_count,
    input wire [1151:0] command_records,
    input wire [31:0] sample_time,
    output reg command_done,
    output reg signed [15:0] command_error,
    output reg command_cancelled,
    output wire event_valid,
    input wire event_ready,
    output wire [904:0] event_packet,
    input wire dispatch_done,
    output wire [31:0] held_keys,
    output wire [2047:0] held_press_ids,held_tokens,
    output wire [575:0] event_press_ids,
    output reg token_exhausted,
    output reg [31:0] accepted_commands,rejected_commands,cancelled_commands,
    output reg [31:0] committed_commands,cleanup_offs
);
    localparam IDLE=0,VALIDATE=1,OFFER=2,WAIT_PUBLISH=3,CLEAN_FIND=4,CLEAN_OFFER=5,CLEAN_WAIT=6;
    reg [2:0] state;
    reg [31:0] held;
    wire [63:0] press[0:31],token[0:31];
    reg [127:0] ledger[0:63];
    reg [31:0] ledger_initial,ledger_select,ledger_dirty;
    reg [95:0] packet_items[0:8];reg [8:0] packet_mask;reg [31:0] packet_sample;
    wire [863:0] packed_items;
    assign event_packet={packet_sample,packet_mask,packed_items};
    reg [TOKEN_WIDTH-1:0] next_token,work_next;
    reg work_exhausted;
    reg [1151:0] records;
    reg [3:0] count,index;
    reg [5:0] cleanup_index;
    wire [127:0] record_words[0:8];
    generate for(genvar r=0;r<9;r=r+1)begin: fixed_record_word
        assign record_words[r]=records[r*128+:128];assign packed_items[r*96+:96]=packet_items[r];
    end endgenerate
    wire [127:0] record=record_words[index];
    wire [63:0] new_press=record[63:0];
    wire [7:0] kind=record[71:64],key=record[79:72],note=record[87:80],value=record[95:88];
    wire invalid_common=record[127:96]!=0||kind<1||kind>4||note>127;
    wire invalid_vib=kind==4&&(new_press!=0||key!=255||note!=0);
    wire invalid_note=kind!=4&&(new_press==0||key>=32||
        (kind==1&&value==0)||(kind==2&&(note!=0||value!=0)));
    // A nine-record overlay supplies tentative state without a second 32-key
    // register bank. The real ledger changes only on packet acceptance.
    reg prefetch_enable;reg [4:0] prefetch_key;
    reg [127:0] ledger_read;
    reg prefetch_initial,prefetch_valid;reg [4:0] response_key;
    wire [127:0] prefetched_ledger=prefetch_initial?128'd0:ledger_read;
    reg prior_held;
    reg [63:0] prior_press,prior_token;
    integer overlay;
    always @*begin
        prior_held=0;prior_press=0;prior_token=0;
        if(key<32)begin prior_held=held[key];prior_press=prefetched_ledger[127:64];prior_token=prefetched_ledger[63:0];end
        for(overlay=0;overlay<9;overlay=overlay+1)
            if(overlay<index&&records[overlay*128+72+:8]==key)begin
                if(records[overlay*128+64+:8]==1)begin
                    prior_held=1;prior_press=records[overlay*128+:64];prior_token=event_packet[overlay*96+32+:64];
                end else if(records[overlay*128+64+:8]==2)prior_held=0;
            end
    end
    wire bad_identity=(key<32)&&((kind==1&&prior_held)||
        ((kind==2||kind==3)&&(!prior_held||prior_press!=new_press)));
    wire [63:0] allocated_token={{(64-TOKEN_WIDTH){1'b0}},work_next};
    assign command_ready=!rst&&active&&!closing&&!session_close&&state==IDLE;
    assign open_ready=!rst&&!active&&!closing&&state==IDLE&&!token_exhausted;
    assign event_valid=!rst&&(state==OFFER||state==CLEAN_OFFER);
    assign held_keys=held;
    genvar g;
    generate for(g=0;g<32;g=g+1)begin:observe
        assign held_press_ids[g*64+:64]=press[g];
        assign held_tokens[g*64+:64]=token[g];
    end endgenerate
    generate for(g=0;g<9;g=g+1)begin: event_identity
        assign event_press_ids[g*64+:64]=records[g*128+:64];
    end endgenerate
    wire begin_packet=state==IDLE && command_valid && command_ready && command_count!=0 && command_count<=9;
    // Read in the existing preceding clock; validation and cleanup never stall.
    always @*begin
        prefetch_enable=0;prefetch_key=0;
        if(begin_packet)begin prefetch_enable=1;prefetch_key=command_records[76:72];end
        else if(state==VALIDATE && index<8)begin
            prefetch_enable=1;prefetch_key=record_words[index+1'b1][76:72];
        end else if(state==IDLE && active && (closing||session_close))begin
            prefetch_enable=1;prefetch_key=0;
        end else if((state==CLEAN_FIND && cleanup_index<32 && !held[cleanup_index]) ||
                    (state==CLEAN_WAIT && dispatch_done))begin
            prefetch_enable=1;prefetch_key=cleanup_index[4:0]+1'b1;
        end
    end
    always @(posedge clk)begin
        if(prefetch_enable)ledger_read<=ledger[{ledger_select[prefetch_key],prefetch_key}];
        if(rst)begin prefetch_valid<=0;prefetch_initial<=1;response_key<=0;end
        else begin
            prefetch_valid<=prefetch_enable;
            if(prefetch_enable)begin prefetch_initial<=ledger_initial[prefetch_key];response_key<=prefetch_key;end
        end
    end
    wire validated_item=state==VALIDATE && !(closing||session_close||invalid_common||invalid_vib||invalid_note||bad_identity||(kind==1&&work_exhausted));
    wire accept_packet=state==OFFER && event_ready;
    wire cleanup_packet=state==CLEAN_FIND && cleanup_index!=32 && held[cleanup_index];
    wire [95:0] validated_packet_item={kind==1?allocated_token:kind==4?64'd0:prior_token,4'd2,kind[3:0],key,note[6:0],value,1'b0};
    reg [31:0] committed_held;integer commit_key,commit_record;
    always @*begin
        committed_held=held;
        for(commit_key=0;commit_key<32;commit_key=commit_key+1)
            for(commit_record=0;commit_record<9;commit_record=commit_record+1)
                if(commit_record<count && record_words[commit_record][79:72]==commit_key)begin
                    if(record_words[commit_record][71:64]==1)committed_held[commit_key]=1;
                    else if(record_words[commit_record][71:64]==2)committed_held[commit_key]=0;
                end
    end
    always @(posedge clk)begin
        if(rst)begin ledger_initial<=32'hffffffff;ledger_select<=0;ledger_dirty<=0;packet_mask<=0;packet_sample<=0;end
        else begin
            if(begin_packet)begin ledger_dirty<=0;packet_mask<=0;packet_sample<=sample_time;end
            if(validated_item)begin
                packet_mask[index]<=1;
                if(kind==1)ledger_dirty[key[4:0]]<=1;
            end
            if(accept_packet)begin ledger_initial<=ledger_initial&~ledger_dirty;ledger_select<=ledger_select^ledger_dirty;ledger_dirty<=0;end
            if(cleanup_packet)begin packet_mask<=9'd1;packet_sample<=sample_time;end
        end
    end
    always @(posedge clk)if(!rst && validated_item && kind==1)begin
        ledger[{~ledger_select[key[4:0]],key[4:0]}]<={new_press,allocated_token};
    end
    generate for(genvar k=0;k<32;k=k+1)begin: committed_ledger
        wire [127:0] published=ledger[ledger_select[k]*32+k];
        assign press[k]=ledger_initial[k]?64'd0:published[127:64];
        assign token[k]=ledger_initial[k]?64'd0:published[63:0];
    end
    for(genvar k=0;k<9;k=k+1)begin: packet_item_storage
        always @(posedge clk)begin
            if(rst)packet_items[k]<=0;
            else begin
                if(begin_packet)packet_items[k]<=0;
                if(validated_item && index==k)packet_items[k]<=validated_packet_item;
                if(cleanup_packet)begin
                    if(k==0)packet_items[k]<={prefetched_ledger[63:0],4'd2,4'd2,2'd0,cleanup_index,7'd0,8'd0,1'b0};
                    else packet_items[k]<=0;
                end
            end
        end
    end endgenerate
    integer i;
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;active<=0;closing<=0;close_done<=0;
            held<=0;next_token<=1;work_next<=1;
            token_exhausted<=0;work_exhausted<=0;records<=0;count<=0;index<=0;cleanup_index<=0;
            command_done<=0;command_error<=0;command_cancelled<=0;
            accepted_commands<=0;rejected_commands<=0;cancelled_commands<=0;committed_commands<=0;cleanup_offs<=0;
        end else begin
            command_done<=0;command_cancelled<=0;close_done<=0;
            if(session_close&&active)closing<=1;
            if(session_open&&open_ready)active<=1;
            case(state)
            IDLE:begin
                if(active&&(closing||session_close))begin cleanup_index<=0;state<=CLEAN_FIND;end
                else if(command_valid&&command_ready)begin
                    accepted_commands<=accepted_commands+1'b1;
                    if(command_count==0||command_count>9)begin
                        command_done<=1;command_error<=-4;rejected_commands<=rejected_commands+1'b1;
                    end else begin
                        records<=command_records;count<=command_count;index<=0;
                        work_next<=next_token;work_exhausted<=token_exhausted;
                        state<=VALIDATE;
                    end
                end
            end
            VALIDATE:begin
                if(closing||session_close)begin
                    command_done<=1;command_error<=0;command_cancelled<=1;
                    cancelled_commands<=cancelled_commands+1'b1;state<=IDLE;
                end else if(invalid_common||invalid_vib||invalid_note||bad_identity||(kind==1&&work_exhausted))begin
                    command_done<=1;command_error<=(kind==1&&work_exhausted)?-6:(bad_identity?-11:-4);
                    rejected_commands<=rejected_commands+1'b1;state<=IDLE;
                end else begin
                    if(kind==1)begin
                        if(work_next=={TOKEN_WIDTH{1'b1}})work_exhausted<=1;
                        else work_next<=work_next+1'b1;
                    end
                    if(index+1'b1==count)state<=OFFER;else index<=index+1'b1;
                end
            end
            OFFER:if(event_ready)begin
                next_token<=work_next;token_exhausted<=work_exhausted;
                held<=committed_held;
                state<=WAIT_PUBLISH;
            end
            WAIT_PUBLISH:if(dispatch_done)begin
                command_done<=1;command_error<=0;committed_commands<=committed_commands+1'b1;state<=IDLE;
            end
            CLEAN_FIND:begin
                if(cleanup_index==32)begin held<=0;active<=0;closing<=0;close_done<=1;state<=IDLE;end
                else if(held[cleanup_index])begin
                    state<=CLEAN_OFFER;
                end else cleanup_index<=cleanup_index+1'b1;
            end
            CLEAN_OFFER:if(event_ready)state<=CLEAN_WAIT;
            CLEAN_WAIT:if(dispatch_done)begin
                held[cleanup_index]<=0;cleanup_offs<=cleanup_offs+1'b1;
                cleanup_index<=cleanup_index+1'b1;state<=CLEAN_FIND;
            end
            default:state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if(TOKEN_WIDTH<1||TOKEN_WIDTH>64)$fatal(1,"S9_TOKEN_WIDTH");
    always @(posedge clk)if(!rst)begin
        if(state==VALIDATE && key<32 && !(closing||session_close) && (!prefetch_valid||response_key!=key[4:0]))$fatal(1,"S9_PHONE_PREFETCH_RECORD_TAG");
        if(cleanup_packet && (!prefetch_valid||response_key!=cleanup_index[4:0]))$fatal(1,"S9_PHONE_PREFETCH_CLEAN_TAG");
        if((^{session_open,session_close,command_valid,event_ready,dispatch_done})===1'bx)$fatal(1,"S9_PHONE_CONTROL_XZ");
        if(command_valid&&(^({command_count,command_records}))===1'bx)$fatal(1,"S9_PHONE_PAYLOAD_XZ");
        if(dispatch_done&&state!=WAIT_PUBLISH&&state!=CLEAN_WAIT)$fatal(1,"S9_PHONE_UNOWNED_PUBLISH");
        if(committed_commands+rejected_commands+cancelled_commands>accepted_commands)$fatal(1,"S9_PHONE_CONSERVATION");
    end
    // synthesis translate_on
endmodule
