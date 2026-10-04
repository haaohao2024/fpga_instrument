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
    output reg [904:0] event_packet,
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
    reg [63:0] press[0:31],token[0:31];
    reg [TOKEN_WIDTH-1:0] next_token,work_next;
    reg work_exhausted;
    reg [1151:0] records;
    reg [3:0] count,index;
    reg [5:0] cleanup_index;
    wire [127:0] record=records[index*128+:128];
    wire [63:0] new_press=record[63:0];
    wire [7:0] kind=record[71:64],key=record[79:72],note=record[87:80],value=record[95:88];
    wire invalid_common=record[127:96]!=0||kind<1||kind>4||note>127;
    wire invalid_vib=kind==4&&(new_press!=0||key!=255||note!=0);
    wire invalid_note=kind!=4&&(new_press==0||key>=32||
        (kind==1&&value==0)||(kind==2&&(note!=0||value!=0)));
    // A nine-record overlay supplies tentative state without a second 32-key
    // register bank. The real ledger changes only on packet acceptance.
    reg prior_held;
    reg [63:0] prior_press,prior_token;
    integer overlay;
    always @*begin
        prior_held=0;prior_press=0;prior_token=0;
        if(key<32)begin prior_held=held[key];prior_press=press[key];prior_token=token[key];end
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
    integer i;
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;active<=0;closing<=0;close_done<=0;
            held<=0;next_token<=1;work_next<=1;
            token_exhausted<=0;work_exhausted<=0;records<=0;count<=0;index<=0;cleanup_index<=0;
            command_done<=0;command_error<=0;command_cancelled<=0;event_packet<=0;
            accepted_commands<=0;rejected_commands<=0;cancelled_commands<=0;committed_commands<=0;cleanup_offs<=0;
            for(i=0;i<32;i=i+1)begin press[i]<=0;token[i]<=0;end
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
                        event_packet<=0;event_packet[904:873]<=sample_time;state<=VALIDATE;
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
                    event_packet[index*96+:32]<={4'd2,kind[3:0],key,note[6:0],value,1'b0};
                    event_packet[864+index]<=1;
                    if(kind==1)begin
                        event_packet[index*96+32+:64]<=allocated_token;
                        if(work_next=={TOKEN_WIDTH{1'b1}})work_exhausted<=1;
                        else work_next<=work_next+1'b1;
                    end else if(kind==4)event_packet[index*96+32+:64]<=0;
                    else begin
                        event_packet[index*96+32+:64]<=prior_token;
                    end
                    if(index+1'b1==count)state<=OFFER;else index<=index+1'b1;
                end
            end
            OFFER:if(event_ready)begin
                next_token<=work_next;token_exhausted<=work_exhausted;
                for(i=0;i<9;i=i+1)if(i<count)begin
                    if(records[i*128+64+:8]==1)begin
                        held[records[i*128+72+:8]]<=1;
                        press[records[i*128+72+:8]]<=records[i*128+:64];
                        token[records[i*128+72+:8]]<=event_packet[i*96+32+:64];
                    end else if(records[i*128+64+:8]==2)held[records[i*128+72+:8]]<=0;
                end
                state<=WAIT_PUBLISH;
            end
            WAIT_PUBLISH:if(dispatch_done)begin
                command_done<=1;command_error<=0;committed_commands<=committed_commands+1'b1;state<=IDLE;
            end
            CLEAN_FIND:begin
                if(cleanup_index==32)begin held<=0;active<=0;closing<=0;close_done<=1;state<=IDLE;end
                else if(held[cleanup_index])begin
                    event_packet<=0;event_packet[904:873]<=sample_time;event_packet[864]<=1;
                    event_packet[95:0]<={token[cleanup_index],4'd2,4'd2,2'd0,cleanup_index,7'd0,8'd0,1'b0};
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
        if((^{session_open,session_close,command_valid,event_ready,dispatch_done})===1'bx)$fatal(1,"S9_PHONE_CONTROL_XZ");
        if(command_valid&&(^({command_count,command_records}))===1'bx)$fatal(1,"S9_PHONE_PAYLOAD_XZ");
        if(dispatch_done&&state!=WAIT_PUBLISH&&state!=CLEAN_WAIT)$fatal(1,"S9_PHONE_UNOWNED_PUBLISH");
        if(committed_commands+rejected_commands+cancelled_commands>accepted_commands)$fatal(1,"S9_PHONE_CONSERVATION");
    end
    // synthesis translate_on
endmodule
