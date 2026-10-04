// EVR ring: 1024 x 32-bit words, two 512 x 32 SDP BSRAM blocks.
// A 256-bit cell is written in eight words; atomic visibility waits for all.
// tx_ready reserves a complete atomic transaction. Producer MUST hold cells
// until tx_done; there is no second copy bank. Only the final RAM write makes
// the complete transaction available to the transport.
module s11_event_recorder #(
    parameter integer CAPACITY=128,
    parameter integer MAX_TRANSACTION=40
) (
    input wire clk,rst,
    input wire start_valid,stop_valid,clear_valid,
    input wire [63:0] start_record_id,
    output wire start_ready,
    output reg active,incomplete,
    output reg [7:0] error_code,
    output reg [63:0] record_id,
    input wire tx_valid,
    input wire [5:0] tx_count,
    input wire [10239:0] tx_cells,
    output wire tx_ready,
    output reg tx_done,
    input wire fault_valid,
    input wire [7:0] fault_code,
    output reg [63:0] captured_cells,retired_cells,discarded_cells,
    output reg [8:0] buffered_cells,
    output reg [31:0] aborted_transaction_cells,
    input wire block_request,
    output reg block_valid,
    output reg [31:0] block_sequence,
    output reg [63:0] block_first_frame,
    output reg [15:0] block_cell_count,
    input wire [8:0] peek_byte_address,
    output reg [7:0] peek_byte_data,
    input wire ack_valid,
    input wire [63:0] ack_record_id,
    input wire [31:0] ack_block_sequence,
    output reg [31:0] stale_ack_count,rejected_start_count
);
    localparam integer PTR_W=$clog2(CAPACITY);
    reg [31:0] cell_ram[0:CAPACITY*8-1];
    reg [PTR_W-1:0] read_pointer,write_pointer,reserved_start;
    reg writer_busy;
    reg [5:0] write_index,reserved_count;
    reg [2:0] write_word;
    reg block_meta_pending;
    reg [31:0] peek_word;
    integer peek_index;
    wire accepted_ack=ack_valid && block_valid &&
        ack_record_id==record_id && ack_block_sequence==block_sequence;
    wire [8:0] ack_count=accepted_ack?block_cell_count:9'd0;
    wire commit=writer_busy && write_word==7 && write_index+1'b1==reserved_count && !clear_valid;
    wire [255:0] current_tx_cell=tx_cells[write_index*256+:256];
    wire [31:0] file_cell_sequence=captured_cells[31:0]+write_index;
    wire [31:0] current_tx_word=write_word==1 ? file_cell_sequence :
        current_tx_cell[write_word*32+:32];
    assign start_ready=!rst && !active && !writer_busy && buffered_cells==0 && !block_valid;
    assign tx_ready=!rst && record_id!=0 && !incomplete && !writer_busy &&
        tx_count!=0 && tx_count<=MAX_TRANSACTION &&
        buffered_cells-ack_count+tx_count<=CAPACITY && !clear_valid && !fault_valid;
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
            writer_busy<=0;write_index<=0;write_word<=0;reserved_count<=0;tx_done<=0;block_meta_pending<=0;
            block_valid<=0;block_sequence<=0;block_first_frame<=0;
            block_cell_count<=0;peek_byte_data<=0;stale_ack_count<=0;
            rejected_start_count<=0;
        end else begin
            tx_done<=0;peek_byte_data<=0;
            if(block_valid && peek_byte_address<block_cell_count*32)begin
                peek_index=read_pointer*8+(peek_byte_address>>2);
                if(peek_index>=CAPACITY*8)peek_index=peek_index-CAPACITY*8;
                peek_word=cell_ram[peek_index];
                peek_byte_data<=peek_word[peek_byte_address[1:0]*8 +:8];
            end
            buffered_cells<=buffered_cells-ack_count+(commit?reserved_count:0);
            if(ack_valid && !accepted_ack)stale_ack_count<=stale_ack_count+1'b1;
            if(accepted_ack)begin
                read_pointer<=advance(read_pointer,block_cell_count);
                retired_cells<=retired_cells+block_cell_count;
                block_valid<=0;block_sequence<=block_sequence+1'b1;
                block_cell_count<=0;peek_byte_data<=0;
            end
            if(tx_valid && tx_ready)begin
                writer_busy<=1;reserved_start<=write_pointer;
                reserved_count<=tx_count;write_index<=0;write_word<=0;
            end
            if(writer_busy && !clear_valid)begin
                cell_ram[advance(reserved_start,write_index)*8+write_word]<=current_tx_word;
                if(commit)begin
                    writer_busy<=0;tx_done<=1;
                    write_pointer<=advance(reserved_start,reserved_count);
                    captured_cells<=captured_cells+reserved_count;
                end else if(write_word==7)begin write_index<=write_index+1'b1;write_word<=0;end
                else write_word<=write_word+1'b1;
            end
            if(tx_valid && !writer_busy && !incomplete && record_id!=0 &&
               (tx_count==0 || tx_count>MAX_TRANSACTION ||
                buffered_cells-ack_count+tx_count>CAPACITY))begin
                active<=0;incomplete<=1;error_code<=8'd2;
            end
            if(fault_valid)begin active<=0;incomplete<=1;error_code<=fault_code;end
            if(stop_valid)active<=0;
            if(block_request && !block_valid && !block_meta_pending && buffered_cells!=0 && !clear_valid)begin
                block_meta_pending<=1;
                block_cell_count<=(buffered_cells>=16)?16:buffered_cells;
                block_first_frame[31:0]<=cell_ram[read_pointer*8+2];
            end
            if(block_meta_pending && !clear_valid)begin
                block_first_frame[63:32]<=cell_ram[read_pointer*8+3];
                block_meta_pending<=0;block_valid<=1;
            end
            if(start_valid)begin
                if(start_ready && start_record_id!=0 && !stop_valid && !clear_valid && !fault_valid)begin
                    active<=1;incomplete<=0;error_code<=0;record_id<=start_record_id;
                    captured_cells<=0;retired_cells<=0;discarded_cells<=0;
                    aborted_transaction_cells<=0;write_pointer<=0;read_pointer<=0;
                    block_sequence<=0;peek_byte_data<=0;
                end else rejected_start_count<=rejected_start_count+1'b1;
            end
            if(clear_valid)begin
                discarded_cells<=discarded_cells+buffered_cells-ack_count;
                if(writer_busy)aborted_transaction_cells<=aborted_transaction_cells+reserved_count;
                active<=0;writer_busy<=0;buffered_cells<=0;block_meta_pending<=0;write_word<=0;
                block_valid<=0;block_cell_count<=0;write_pointer<=0;
                read_pointer<=0;peek_byte_data<=0;tx_done<=0;
                if(active || writer_busy)begin incomplete<=1;error_code<=8'd9;end
            end
        end
    end
    // synthesis translate_off
    initial if(CAPACITY!=128 || MAX_TRANSACTION>40)$fatal(1,"S11_EVENT_CONFIGURATION");
    always @(posedge clk)if(!rst)begin
        if($isunknown({start_valid,stop_valid,clear_valid,tx_valid,fault_valid,
                       block_request,ack_valid}))$fatal(1,"S11_EVENT_CONTROL_XZ");
        if(tx_valid && $isunknown({tx_count,tx_cells}))$fatal(1,"S11_EVENT_PAYLOAD_XZ");
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
