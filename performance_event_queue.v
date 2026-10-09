// Fall-through synchronous packet FIFO. Empty + ready transfers immediately.
// Captures only when needed, supports simultaneous full pop/push, no sample_tick.
module performance_event_queue #(
    parameter integer WIDTH=329, DEPTH=4,
    parameter integer PTR_W=(DEPTH<=2)?1:$clog2(DEPTH),
    parameter integer COUNT_W=$clog2(DEPTH+1)
) (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire [WIDTH-1:0] s_data,
    output wire m_valid,
    input wire m_ready,
    output wire [WIDTH-1:0] m_data,
    output reg [COUNT_W-1:0] occupancy
);
    reg [WIDTH-1:0] memory [0:DEPTH-1];
    reg [PTR_W-1:0] rd_ptr, wr_ptr;
    wire empty = occupancy==0;
    wire pop_stored = !empty && m_ready && !rst;
    wire push_stored = s_valid && s_ready && (!empty || !m_ready);
    assign s_ready = !rst && ((occupancy<DEPTH) || m_ready);
    assign m_valid = !rst && (!empty || s_valid);
    assign m_data = empty ? s_data : memory[rd_ptr];
    always @(posedge clk) begin
        if (rst) begin occupancy<=0; rd_ptr<=0; wr_ptr<=0; end
        else begin
            if (push_stored) begin
                memory[wr_ptr]<=s_data;
                wr_ptr <= (wr_ptr==DEPTH-1) ? 0 : wr_ptr+1'b1;
            end
            if (pop_stored) rd_ptr <= (rd_ptr==DEPTH-1) ? 0 : rd_ptr+1'b1;
            case ({push_stored,pop_stored})
                2'b10: occupancy<=occupancy+1'b1;
                2'b01: occupancy<=occupancy-1'b1;
                default: occupancy<=occupancy;
            endcase
        end
    end
    // synthesis translate_off
    initial if (DEPTH<2) $fatal(1,"Event FIFO DEPTH must be >=2");
    // synthesis translate_on
endmodule

// Shared ownership of the last ingress queue and allocator packet storage.
// DEPTH includes the active allocator batch: four waiting plus one active.
// Producer holds its packet until all nine words are stored; ready is the
// atomic commit edge. The claimed head remains immutable until retirement.
module performance_indexed_event_queue #(parameter integer DEPTH=5)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,input wire [904:0] s_data,
    output wire m_valid,input wire m_ready,output wire [904:0] m_data,
    input wire retire,input wire [3:0] item_index,output reg [95:0] item_data,
    output reg [2:0] occupancy
);
    reg [95:0] words[0:DEPTH*9-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [44:0] descriptors[0:DEPTH-1] /* synthesis syn_ramstyle="distributed_ram" */;
    reg [2:0] read_pointer,write_pointer;
    reg [5:0] read_base,write_base;
    reg writing,owned;
    // One empty-queue head can be captured and claimed on the same edge.
    // It occupies the SAME ring position/count as a RAM head, never a sixth
    // entry. Later queued batches retain the compact RAM representation.
    reg fast_head;
    reg [904:0] fast_packet;
    wire fast_ready=!rst && !writing && occupancy==0;
    wire fast_capture=fast_ready && s_valid;
    reg [3:0] write_index;
    reg [44:0] incoming_descriptor;
    wire [5:0] write_address=write_base+(writing?write_index:4'd0);
    wire [5:0] read_address=read_base+(item_index<9?item_index:4'd0);
    wire begin_write=!writing && s_valid && occupancy!=0 && occupancy<DEPTH;
    wire commit_write=writing && write_index==8 && s_valid;
    wire release_head=owned && retire;
    reg [95:0] selected_write_word;
    always @*begin
        selected_write_word=0;
        for(integer w=0;w<9;w++)if((writing?write_index:4'd0)==w)
            selected_write_word=s_data[w*96+:96];
    end
    wire [44:0] head_descriptor=occupancy==0?
        {s_data[904:864],s_data[31:28]}:
        (fast_head?{fast_packet[904:864],fast_packet[31:28]}:descriptors[read_pointer]);
    reg [95:0] selected_fast_word;
    always @*begin
        selected_fast_word=0;
        for(integer f=0;f<9;f++)if((item_index<9?item_index:4'd0)==f)
            selected_fast_word=fast_capture?s_data[f*96+:96]:fast_packet[f*96+:96];
    end
    assign s_ready=fast_ready || (!rst && writing && write_index==8);
    assign m_valid=!rst && !owned && (occupancy!=0 || (!writing && s_valid));
    // The only pre-accept body consumer is source classification in core7.
    // All actual item fields are read by the indexed allocator below.
    assign m_data={head_descriptor[44:4],832'd0,head_descriptor[3:0],28'd0};
    always @(posedge clk)begin
        if(!rst && (begin_write || (writing && s_valid)))
            words[write_address]<=selected_write_word;
        if(!rst && commit_write)descriptors[write_pointer]<=incoming_descriptor;
        if(!rst && (fast_capture || (occupancy!=0 && fast_head)))item_data<=selected_fast_word;
        else if(!rst && occupancy!=0)item_data<=words[read_address];
        if(!rst && fast_capture)fast_packet<=s_data;
        if(rst)begin
            read_pointer<=0;write_pointer<=0;read_base<=0;write_base<=0;writing<=0;owned<=0;
            write_index<=0;incoming_descriptor<=0;occupancy<=0;item_data<=0;fast_head<=0;
        end else begin
            if(fast_capture)begin
                fast_head<=1;
                write_pointer<=write_pointer==DEPTH-1?0:write_pointer+1'b1;
                write_base<=write_pointer==DEPTH-1?0:write_base+6'd9;
            end
            if(begin_write)begin
                writing<=1;write_index<=1;incoming_descriptor<={s_data[904:864],s_data[31:28]};
            end else if(writing && s_valid)begin
                if(commit_write)begin
                    writing<=0;write_index<=0;
                    write_pointer<=write_pointer==DEPTH-1?0:write_pointer+1'b1;
                    write_base<=write_pointer==DEPTH-1?0:write_base+6'd9;
                end else write_index<=write_index+1'b1;
            end
            if(m_valid && m_ready)owned<=1;
            if(release_head)begin
                owned<=0;fast_head<=0;read_pointer<=read_pointer==DEPTH-1?0:read_pointer+1'b1;
                read_base<=read_pointer==DEPTH-1?0:read_base+6'd9;
            end
            case({(commit_write || fast_capture),release_head})
                2'b10:occupancy<=occupancy+1'b1;
                2'b01:occupancy<=occupancy-1'b1;
                default:occupancy<=occupancy;
            endcase
        end
    end
    // synthesis translate_off
    reg [904:0] held_packet;
    always @(posedge clk)begin
        if(rst)held_packet<=0;
        else begin
            if(begin_write)held_packet<=s_data;
            if(writing && (!s_valid || s_data!==held_packet))$fatal(1,"INDEXED_QUEUE_PRODUCER_HOLD");
            if(occupancy>DEPTH || (owned && occupancy==0))$fatal(1,"INDEXED_QUEUE_OWNERSHIP");
            if(writing && occupancy==DEPTH)$fatal(1,"INDEXED_QUEUE_OVERWRITE");
        end
    end
    initial if(DEPTH!=5)$fatal(1,"INDEXED_QUEUE_CAPACITY_CONTRACT");
    // synthesis translate_on
endmodule

// Eight local packets, stored as 72 96-bit words. A prefetched head is a
// cache of the still-owned ring entry, not another independently counted
// packet. Input and output owners advance only on their own handshakes.
module performance_serial_packet_queue(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,input wire [904:0] s_data,
    output wire m_valid,input wire m_ready,output reg [904:0] m_data,
    output reg [3:0] occupancy
);
    reg [95:0] words[0:71] /* synthesis syn_ramstyle="block_ram" */;
    reg [40:0] headers[0:7] /* synthesis syn_ramstyle="distributed_ram" */;
    reg [2:0] rd_pointer,wr_pointer;
    reg [6:0] rd_base,wr_base;
    reg [3:0] wr_index,rd_index;
    reg writing,reading,read_pending,loaded;
    reg [40:0] incoming_header;
    reg [95:0] read_data;
    wire begin_write=!writing && s_valid && occupancy<8;
    wire commit_write=writing && wr_index==8 && s_valid;
    wire pop=m_valid && m_ready;
    wire [6:0] write_address=wr_base+(writing?wr_index:4'd0);
    wire [6:0] read_address=rd_base+(rd_index<9?rd_index:4'd0);
    reg [95:0] selected_write_word;
    always @*begin
        selected_write_word=0;
        for(integer w=0;w<9;w++)if((writing?wr_index:4'd0)==w)
            selected_write_word=s_data[w*96+:96];
    end
    assign s_ready=!rst && writing && wr_index==8;
    assign m_valid=!rst && loaded;
    always @(posedge clk)begin
        if(!rst && (begin_write || (writing && s_valid)))
            words[write_address]<=selected_write_word;
        if(!rst && commit_write)headers[wr_pointer]<=incoming_header;
        if(!rst && occupancy!=0)read_data<=words[read_address];
        if(rst)begin
            rd_pointer<=0;wr_pointer<=0;rd_base<=0;wr_base<=0;
            wr_index<=0;rd_index<=0;writing<=0;reading<=0;
            read_pending<=0;loaded<=0;incoming_header<=0;
            occupancy<=0;m_data<=0;
        end else begin
            if(begin_write)begin writing<=1;wr_index<=1;incoming_header<=s_data[904:864];end
            else if(writing && s_valid)begin
                if(commit_write)begin
                    writing<=0;wr_index<=0;wr_pointer<=wr_pointer+1'b1;
                    wr_base<=wr_pointer==7?0:wr_base+7'd9;
                end else wr_index<=wr_index+1'b1;
            end
            if(!loaded && !reading && occupancy!=0)begin
                reading<=1;rd_index<=0;read_pending<=0;m_data[904:864]<=headers[rd_pointer];
            end else if(reading)begin
                read_pending<=1;rd_index<=rd_index+1'b1;
                if(read_pending)m_data[863:0]<={read_data,m_data[863:96]};
                if(rd_index==9)begin loaded<=1;reading<=0;read_pending<=0;rd_index<=0;end
            end
            if(pop)begin
                loaded<=0;rd_pointer<=rd_pointer+1'b1;
                rd_base<=rd_pointer==7?0:rd_base+7'd9;
            end
            case({commit_write,pop})
                2'b10:occupancy<=occupancy+1'b1;
                2'b01:occupancy<=occupancy-1'b1;
                default:occupancy<=occupancy;
            endcase
        end
    end
    // synthesis translate_off
    reg [904:0] held_input,held_output;reg output_stalled;
    always @(posedge clk)begin
        if(rst)begin held_input<=0;held_output<=0;output_stalled<=0;end
        else begin
            if(begin_write)held_input<=s_data;
            if(writing && (!s_valid || s_data!==held_input))$fatal(1,"SERIAL_QUEUE_PRODUCER_HOLD");
            if(output_stalled && (!m_valid || m_data!==held_output))$fatal(1,"SERIAL_QUEUE_CONSUMER_HOLD");
            held_output<=m_data;output_stalled<=m_valid && !m_ready;
            if(occupancy>8 || (loaded && occupancy==0))$fatal(1,"SERIAL_QUEUE_CAPACITY");
        end
    end
    // synthesis translate_on
endmodule

// Local adapter emits one-cycle events and cannot wait for serialization.
// Preserve the complete eight-entry, one-cycle, fall-through queue contract.
// Fall-through synchronous packet FIFO. Empty + ready transfers immediately.
// Captures only when needed, supports simultaneous full pop/push, no sample_tick.
module performance_local_packet_queue #(
    parameter integer WIDTH=905, DEPTH=8,
    parameter integer PTR_W=(DEPTH<=2)?1:$clog2(DEPTH),
    parameter integer COUNT_W=$clog2(DEPTH+1)
) (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire [WIDTH-1:0] s_data,
    output wire m_valid,
    input wire m_ready,
    output wire [WIDTH-1:0] m_data,
    output reg [COUNT_W-1:0] occupancy
);
    reg [WIDTH-1:0] memory [0:DEPTH-1] /* synthesis syn_ramstyle="distributed_ram" */;
    reg [PTR_W-1:0] rd_ptr, wr_ptr;
    wire empty = occupancy==0;
    wire pop_stored = !empty && m_ready && !rst;
    wire push_stored = s_valid && s_ready && (!empty || !m_ready);
    assign s_ready = !rst && ((occupancy<DEPTH) || m_ready);
    assign m_valid = !rst && (!empty || s_valid);
    assign m_data = empty ? s_data : memory[rd_ptr];
    always @(posedge clk) begin
        if (rst) begin occupancy<=0; rd_ptr<=0; wr_ptr<=0; end
        else begin
            if (push_stored) begin
                memory[wr_ptr]<=s_data;
                wr_ptr <= (wr_ptr==DEPTH-1) ? 0 : wr_ptr+1'b1;
            end
            if (pop_stored) rd_ptr <= (rd_ptr==DEPTH-1) ? 0 : rd_ptr+1'b1;
            case ({push_stored,pop_stored})
                2'b10: occupancy<=occupancy+1'b1;
                2'b01: occupancy<=occupancy-1'b1;
                default: occupancy<=occupancy;
            endcase
        end
    end
    // synthesis translate_off
    initial if (DEPTH<2) $fatal(1,"Event FIFO DEPTH must be >=2");
    // synthesis translate_on
endmodule

