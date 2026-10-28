// EVR ring: 1024 x 32-bit words, one write and one shared synchronous read.
// A 256-bit cell is written in eight words; atomic visibility waits for all.
// tx_ready reserves a complete atomic transaction. Producer MUST hold cells
// until tx_done; there is no second copy bank. Only the final RAM write makes
// the complete transaction available to the transport.
module s11_event_recorder #(
    parameter integer TRUSTED_ACK=0,VARIABLE_RESPONSE=0,CAPACITY=128,
    parameter integer MAX_TRANSACTION=40
) (
    input wire tx_response_valid,
    input wire clk,rst,
    input wire start_valid,stop_valid,clear_valid,
    input wire [63:0] start_record_id,
    output wire start_ready,
    output reg active,incomplete,
    output reg [7:0] error_code,
    output reg [63:0] record_id,
    input wire tx_valid,
    input wire [5:0] tx_count,
    input wire [255:0] tx_cell,output wire [5:0] tx_index,
    output wire tx_ready,
    output wire prefetch_req_valid,output wire [5:0] prefetch_req_index,
    output wire observe_write_enable,
    output reg tx_done,
    input wire fault_valid,
    input wire [7:0] fault_code,
    output reg [63:0] captured_cells,retired_cells,discarded_cells,
    output reg [8:0] buffered_cells,
    output reg [31:0] aborted_transaction_cells,
    input wire block_request,
    output reg block_valid,
    output reg [31:0] block_sequence,
    output wire [63:0] block_first_frame,
    output reg [15:0] block_cell_count,
    input wire [8:0] peek_byte_address,
    output wire [7:0] peek_byte_data,
    input wire ack_valid,ack_accepted,
    input wire [63:0] ack_record_id,
    input wire [31:0] ack_block_sequence,
    output reg [31:0] stale_ack_count,rejected_start_count
);
    localparam integer PTR_W=$clog2(CAPACITY);
    reg [31:0] cell_ram[0:CAPACITY*8-1];
    reg [PTR_W-1:0] read_pointer,write_pointer,reserved_start;
    reg writer_busy,writer_wait;
    wire cell_available=!VARIABLE_RESPONSE||!writer_wait||tx_response_valid;
    reg [5:0] write_index,reserved_count;
    reg [2:0] write_word;
    reg block_meta_pending;
    // Metadata phases and published-prefix reads are mutually exclusive.
    // Expose a read on its original edge, then retain it when the port moves.
    wire meta_low=block_request && !block_valid && !block_meta_pending &&
        buffered_cells!=0 && !clear_valid;
    wire meta_high=block_meta_pending && !clear_valid;
    wire peek_enable=block_valid && peek_byte_address<block_cell_count*32;
    wire [PTR_W+3:0] peek_sum={1'b0,read_pointer,3'b000}+(peek_byte_address>>2);
    wire [PTR_W+2:0] peek_index=peek_sum>=CAPACITY*8?peek_sum-CAPACITY*8:peek_sum;
    wire [PTR_W+2:0] read_address=meta_low?{read_pointer,3'b010}:
        meta_high?{read_pointer,3'b011}:peek_index;
    reg [31:0] read_word,held_frame_low,held_frame_high;
    reg [1:0] read_kind,peek_byte_select;
    reg peek_owned;
    always @(posedge clk)if(!rst && (meta_low || meta_high || peek_enable))
        read_word<=cell_ram[read_address];
    always @(posedge clk)begin
        if(rst)begin read_kind<=0;held_frame_low<=0;held_frame_high<=0;peek_byte_select<=0;end
        else begin
            read_kind<=meta_low?2'd1:meta_high?2'd2:peek_enable?2'd3:2'd0;
            if(read_kind==1)held_frame_low<=read_word;
            if(read_kind==2)held_frame_high<=read_word;
            if(peek_enable)peek_byte_select<=peek_byte_address[1:0];
        end
    end
    assign block_first_frame={read_kind==2?read_word:held_frame_high,
                              read_kind==1?read_word:held_frame_low};
    assign peek_byte_data=peek_owned?read_word[peek_byte_select*8+:8]:8'd0;
    wire checked_ack=ack_valid && block_valid && ack_record_id==record_id && ack_block_sequence==block_sequence;
    wire accepted_ack=TRUSTED_ACK?ack_accepted:checked_ack;
    wire [8:0] ack_count=accepted_ack?block_cell_count:9'd0;
    // Evaluate both capacity cases in parallel. The late command/snapshot
    // path selects an already-computed decision, never drives the adder.
    // Explicit 32-bit unsigned intermediates preserve original expression
    // width and wrap behavior, including invalid-input negative tests.
    wire [31:0] requested_without_ack={23'd0,buffered_cells}+{26'd0,tx_count};
    wire [31:0] requested_with_ack={23'd0,buffered_cells}-{23'd0,block_cell_count[8:0]}+{26'd0,tx_count};
    wire space_available=accepted_ack?(requested_with_ack<=CAPACITY):(requested_without_ack<=CAPACITY);
    // synthesis translate_off
    always @(posedge clk)if(!rst)
      if(space_available !== (buffered_cells-ack_count+tx_count<=CAPACITY))
        $fatal(1,"ACK_CAPACITY_DECISION_MISMATCH");
    // synthesis translate_on

    wire commit=writer_busy && cell_available && write_word==7 && write_index+1'b1==reserved_count && !clear_valid;
    // The producer holds the accepted batch until tx_done; only the read
    // index changes during its original eight-clock-per-cell write cadence.
    assign tx_index=writer_busy?write_index:6'd0;
    // Accept reads cell 0 on the same edge; word 7 reads the next cell.
    // No ready, write enable, counter, commit or done equation is gated.
    assign prefetch_req_valid=!rst&&!clear_valid &&
        ((tx_valid&&tx_ready) || (writer_busy&&cell_available&&write_word==7&&write_index+1'b1<reserved_count));
    assign prefetch_req_index=writer_busy?write_index+1'b1:6'd0;
    wire [255:0] current_tx_cell=tx_cell;
    wire [31:0] file_cell_sequence=captured_cells[31:0]+write_index;
    wire [31:0] current_tx_word=write_word==1 ? file_cell_sequence :
        current_tx_cell[write_word*32+:32];
    wire ram_write_enable=!rst&&writer_busy&&cell_available&&!clear_valid;
    assign observe_write_enable=ram_write_enable;
    wire [PTR_W+2:0] ram_write_address=advance(reserved_start,write_index)*8+write_word;
    wire [31:0] ram_write_data=current_tx_word;
    assign start_ready=!rst && !active && !writer_busy && buffered_cells==0 && !block_valid;
    assign tx_ready=!rst && record_id!=0 && !incomplete && !writer_busy &&
        tx_count!=0 && tx_count<=MAX_TRANSACTION &&
        space_available && !clear_valid && !fault_valid;
    function [PTR_W-1:0] advance;
        input [PTR_W-1:0] ptr;
        input [15:0] amount;
        integer sum;
        begin sum=ptr+amount; if(sum>=CAPACITY)sum=sum-CAPACITY;advance=sum;end
    endfunction
    always @(posedge clk)begin
        if(rst)begin
            active<=0;incomplete<=0;error_code<=0;record_id<=0;
            captured_cells<=0;retired_cells<=0;discarded_cells<=0;
            buffered_cells<=0;aborted_transaction_cells<=0;
            read_pointer<=0;write_pointer<=0;reserved_start<=0;
            writer_wait<=0;writer_busy<=0;write_index<=0;write_word<=0;reserved_count<=0;tx_done<=0;block_meta_pending<=0;
            block_valid<=0;block_sequence<=0;
            block_cell_count<=0;peek_owned<=0;stale_ack_count<=0;
            rejected_start_count<=0;
        end else begin
            tx_done<=0;peek_owned<=peek_enable;
            buffered_cells<=buffered_cells-ack_count+(commit?reserved_count:0);
            if(ack_valid && !accepted_ack)stale_ack_count<=stale_ack_count+1'b1;
            if(accepted_ack)begin
                read_pointer<=advance(read_pointer,block_cell_count);
                retired_cells<=retired_cells+block_cell_count;
                block_valid<=0;block_sequence<=block_sequence+1'b1;
                block_cell_count<=0;peek_owned<=0;
            end
            if(tx_valid && tx_ready)begin
                writer_busy<=1;writer_wait<=1;reserved_start<=write_pointer;
                reserved_count<=tx_count;write_index<=0;write_word<=0;
            end
            if(writer_busy && !clear_valid && cell_available)begin
                writer_wait<=0;
                cell_ram[ram_write_address]<=ram_write_data;
                if(commit)begin
                    writer_busy<=0;tx_done<=1;
                    write_pointer<=advance(reserved_start,reserved_count);
                    captured_cells<=captured_cells+reserved_count;
                end else if(write_word==7)begin writer_wait<=1;write_index<=write_index+1'b1;write_word<=0;end
                else write_word<=write_word+1'b1;
            end
            if(tx_valid && !writer_busy && !incomplete && record_id!=0 &&
               (tx_count==0 || tx_count>MAX_TRANSACTION ||
                !space_available))begin
                active<=0;incomplete<=1;error_code<=8'd2;
            end
            if(fault_valid)begin active<=0;incomplete<=1;error_code<=fault_code;end
            if(stop_valid)active<=0;
            if(block_request && !block_valid && !block_meta_pending && buffered_cells!=0 && !clear_valid)begin
                block_meta_pending<=1;
                block_cell_count<=(buffered_cells>=16)?16:buffered_cells;
            end
            if(block_meta_pending && !clear_valid)begin
                block_meta_pending<=0;block_valid<=1;
            end
            if(start_valid)begin
                if(start_ready && start_record_id!=0 && !stop_valid && !clear_valid && !fault_valid)begin
                    active<=1;incomplete<=0;error_code<=0;record_id<=start_record_id;
                    captured_cells<=0;retired_cells<=0;discarded_cells<=0;
                    aborted_transaction_cells<=0;write_pointer<=0;read_pointer<=0;
                    block_sequence<=0;peek_owned<=0;
                end else rejected_start_count<=rejected_start_count+1'b1;
            end
            if(clear_valid)begin
                discarded_cells<=discarded_cells+buffered_cells-ack_count;
                if(writer_busy)aborted_transaction_cells<=aborted_transaction_cells+reserved_count;
                active<=0;writer_busy<=0;writer_wait<=0;buffered_cells<=0;block_meta_pending<=0;write_word<=0;
                block_valid<=0;block_cell_count<=0;write_pointer<=0;
                read_pointer<=0;peek_owned<=0;tx_done<=0;
                if(active || writer_busy)begin incomplete<=1;error_code<=8'd9;end
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk)if(!rst&&TRUSTED_ACK&&accepted_ack!==checked_ack)
        $fatal(1,"R54_PARENT_ACK_CONTRACT");
    initial if(CAPACITY!=128 || MAX_TRANSACTION>40)$fatal(1,"S11_EVENT_CONFIGURATION");
    always @(posedge clk)if(!rst)begin
        if(block_valid && block_meta_pending)$fatal(1,"S11_EVENT_READ_PHASE_OVERLAP");
        if((meta_low && meta_high) || ((meta_low || meta_high) && peek_enable))
            $fatal(1,"S11_EVENT_READ_PORT_OVERLAP");
        if(peek_owned && read_kind!=3)$fatal(1,"S11_EVENT_PEEK_RESPONSE_KIND");
        if($isunknown({start_valid,stop_valid,clear_valid,tx_valid,fault_valid,
                       block_request,ack_valid}))$fatal(1,"S11_EVENT_CONTROL_XZ");
        if((tx_valid && $isunknown(tx_count)) ||
           (ram_write_enable && $isunknown(tx_cell)))$fatal(1,"S11_EVENT_PAYLOAD_XZ");
        if(ack_valid && $isunknown({ack_record_id,ack_block_sequence}))$fatal(1,"S11_EVENT_ACK_XZ");
        if(start_valid && $isunknown(start_record_id))$fatal(1,"S11_EVENT_START_XZ");
        if(block_valid && $isunknown(peek_byte_address))$fatal(1,"S11_EVENT_PEEK_XZ");
        if(buffered_cells>CAPACITY)$fatal(1,"S11_EVENT_COUNT");
        if(block_valid && (block_cell_count==0 || block_cell_count>buffered_cells))
            $fatal(1,"S11_EVENT_PINNED_PREFIX");
        if(captured_cells!=retired_cells+buffered_cells+discarded_cells && !clear_valid)
            $fatal(1,"S11_EVENT_CONSERVATION");
    end
    // synthesis translate_on
endmodule
