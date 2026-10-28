// Stage11 passive DAC-load recorder. The only stored audio is the 3072-pair
// ring; the pinned retransmission prefix remains in that ring until ACK.
// A START edge excludes a coincident load. STOP excludes a coincident load.
module s11_pcm_recorder #(
    parameter integer TRUSTED_ACK=0,CAPACITY=3072,
    parameter integer BLOCK_PAIRS=128
) (
    input wire clk, rst, audio_reset,
    input wire start_valid, stop_valid, clear_valid,
    input wire [63:0] start_record_id,
    output wire start_ready,
    input wire observe_load,
    input wire signed [15:0] observe_l, observe_r,
    input wire [63:0] observe_frame_id,
    output reg active, incomplete,
    output reg [7:0] error_code,
    output reg [63:0] record_id, first_frame_id, last_frame_id,
    output reg [63:0] captured_pairs, retired_pairs, discarded_pairs, first_missing_frame,
    output reg [12:0] buffered_pairs,
    input wire block_request,
    output reg block_valid,
    output reg [31:0] block_sequence,
    output reg [63:0] block_first_frame,
    output reg [15:0] block_pair_count,
    input wire [10:0] peek_byte_address,
    output wire [7:0] peek_byte_data,
    input wire ack_valid,ack_accepted,
    input wire [63:0] ack_record_id,
    input wire [31:0] ack_block_sequence,
    output reg [31:0] stale_ack_count, rejected_start_count
);
 wire r54_equal_0;

    localparam integer PTR_W=(CAPACITY<2)?1:$clog2(CAPACITY);
    reg [31:0] pcm_ram[0:CAPACITY-1];
    reg [PTR_W-1:0] write_pointer, read_pointer;
    reg [63:0] expected_frame;
    reg have_first;
    wire checked_ack=ack_valid && block_valid && ack_record_id==record_id && ack_block_sequence==block_sequence;
    wire accepted_ack=TRUSTED_ACK?ack_accepted:checked_ack;
    wire capture=active && observe_load && !stop_valid && !clear_valid &&
        !audio_reset;
    wire frame_matches=!have_first || r54_equal_0;
    wire has_space=(buffered_pairs<CAPACITY) || accepted_ack;
    wire store_pair=capture && frame_matches && has_space;
    wire [12:0] ack_count=accepted_ack?block_pair_count:13'd0;
    // One registered full-word RAM read preserves the original edge-visible
    // byte. The byte selector and ownership flag are registered on that same
    // edge; ACK/clear/START/reset still override the visible byte to zero.
    wire peek_enable=block_valid && peek_byte_address<block_pair_count*4;
    wire [PTR_W:0] peek_sum={1'b0,read_pointer}+(peek_byte_address>>2);
    wire [PTR_W-1:0] peek_pair_index=peek_sum>=CAPACITY?peek_sum-CAPACITY:peek_sum;
    reg [31:0] peek_word;
    reg [1:0] peek_byte_select;
    reg peek_owned;
    always @(posedge clk) if(!rst && peek_enable)begin
        peek_word<=pcm_ram[peek_pair_index];
        peek_byte_select<=peek_byte_address[1:0];
    end
    assign peek_byte_data=peek_owned?peek_word[peek_byte_select*8+:8]:8'd0;
    function [PTR_W-1:0] advance;
        input [PTR_W-1:0] ptr;
        input [15:0] amount;
        integer sum;
        begin sum=ptr+amount; if(sum>=CAPACITY)sum=sum-CAPACITY;
            advance=sum; end
    endfunction
    assign start_ready=!rst && !active && buffered_pairs==0 && !block_valid;
    always @(posedge clk) begin
        if(rst)begin
            active<=0;incomplete<=0;error_code<=0;record_id<=0;
            first_frame_id<=0;last_frame_id<=0;captured_pairs<=0;
            retired_pairs<=0;discarded_pairs<=0;first_missing_frame<=64'hffffffffffffffff;buffered_pairs<=0;
            write_pointer<=0;read_pointer<=0;expected_frame<=0;have_first<=0;
            block_valid<=0;block_sequence<=0;block_first_frame<=0;
            block_pair_count<=0;peek_owned<=0;stale_ack_count<=0;
            rejected_start_count<=0;
        end else begin
            // RAM is not reset. Its count/ownership fences make old bytes
            // unreachable after clear/start, including the registered read.
            peek_owned<=peek_enable;
            if(ack_valid && !accepted_ack)stale_ack_count<=stale_ack_count+1'b1;
            if(accepted_ack)begin
                read_pointer<=advance(read_pointer,block_pair_count);
                retired_pairs<=retired_pairs+block_pair_count;
                block_valid<=0;block_sequence<=block_sequence+1'b1;
                block_pair_count<=0;peek_owned<=0;
            end
            buffered_pairs<=buffered_pairs-ack_count+(store_pair?13'd1:13'd0);
            if(store_pair)begin
                pcm_ram[write_pointer]<={observe_r,observe_l};
                write_pointer<=advance(write_pointer,16'd1);
                captured_pairs<=captured_pairs+1'b1;
                last_frame_id<=observe_frame_id;expected_frame<=observe_frame_id+1'b1;
                if(!have_first)begin first_frame_id<=observe_frame_id;have_first<=1;end
            end
            if(capture && (!frame_matches || !has_space))begin
                active<=0;incomplete<=1;error_code<=frame_matches?8'd1:8'd2;
                first_missing_frame<=frame_matches?observe_frame_id:expected_frame;
            end
            if(stop_valid)active<=0;
            if(audio_reset && active)begin
                active<=0;incomplete<=1;error_code<=8'd3;
                first_missing_frame<=have_first?expected_frame:64'hffffffffffffffff;
            end
            if(block_request && !block_valid && buffered_pairs!=0 &&
               (buffered_pairs>=BLOCK_PAIRS || !active) && !clear_valid)begin
                block_valid<=1;
                block_pair_count<=(buffered_pairs>=BLOCK_PAIRS)?BLOCK_PAIRS:buffered_pairs;
                block_first_frame<=first_frame_id+retired_pairs;
            end
            if(start_valid)begin
                if(start_ready && start_record_id!=0 && !stop_valid && !clear_valid && !audio_reset)begin
                    active<=1;incomplete<=0;error_code<=0;record_id<=start_record_id;
                    first_frame_id<=0;last_frame_id<=0;captured_pairs<=0;
                    retired_pairs<=0;discarded_pairs<=0;first_missing_frame<=64'hffffffffffffffff;write_pointer<=0;
                    read_pointer<=0;expected_frame<=0;have_first<=0;
                    block_sequence<=0;peek_owned<=0;
                end else rejected_start_count<=rejected_start_count+1'b1;
            end
            if(clear_valid)begin
                discarded_pairs<=discarded_pairs+buffered_pairs-ack_count;
                active<=0;block_valid<=0;block_pair_count<=0;buffered_pairs<=0;
                write_pointer<=0;read_pointer<=0;peek_owned<=0;
                if(active)begin incomplete<=1;error_code<=8'd4;
                    first_missing_frame<=have_first?expected_frame:64'hffffffffffffffff;end
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk)if(!rst&&TRUSTED_ACK&&accepted_ack!==checked_ack)
        $fatal(1,"R54_PARENT_ACK_CONTRACT");
    initial if(CAPACITY<128 || CAPACITY>4096 || BLOCK_PAIRS<1 || BLOCK_PAIRS>512)
        $fatal(1,"S11_PCM_CONFIGURATION");
    always @(posedge clk)if(!rst)begin
        if($isunknown({start_valid,stop_valid,clear_valid,audio_reset,observe_load,
                       block_request,ack_valid}))$fatal(1,"S11_PCM_CONTROL_XZ");
        if(observe_load && $isunknown({observe_l,observe_r,observe_frame_id}))
            $fatal(1,"S11_PCM_LOAD_XZ");
        if(ack_valid && $isunknown({ack_record_id,ack_block_sequence}))
            $fatal(1,"S11_PCM_ACK_XZ");
        if(start_valid && $isunknown(start_record_id))$fatal(1,"S11_PCM_START_XZ");
        if(block_valid && $isunknown(peek_byte_address))$fatal(1,"S11_PCM_PEEK_XZ");
        if(buffered_pairs>CAPACITY)$fatal(1,"S11_PCM_COUNT");
        if(block_valid && (block_pair_count==0 || block_pair_count>buffered_pairs))
            $fatal(1,"S11_PCM_PINNED_PREFIX");
        if(captured_pairs!=retired_pairs+buffered_pairs+discarded_pairs && !clear_valid)
            $fatal(1,"S11_PCM_CONSERVATION");
    end
    // synthesis translate_on
 r54_full_equal #(.WIDTH(64)) r54_equal_0_tree(.a(observe_frame_id),.b(expected_frame),.equal(r54_equal_0));
endmodule
