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


// Stage B: one canonical body for each queued batch. Local promotion transfers
// a row number; it never copies 905 bits into another queue. Producers still
// have their original capture interfaces while later stages migrate writers.
module r26_event_pool #(parameter integer SHARED_SCORE=0,SHARED_PHONE=0,VALIDATE=0,DISCARD_LOCAL=0)(
 input wire phone_write_valid,input wire[3:0] phone_write_index,input wire[95:0] phone_write_data,
 output wire phone_write_ready,input wire phone_write_abort,
 input wire score_write_valid,input wire[3:0] score_write_index,input wire[95:0] score_write_data,output wire score_write_ready,
 input wire discard_local,output wire discarded,
 output wire rejected,
 input wire clk,rst,
 input wire local_valid,output wire local_ready,input wire[904:0] local_packet,
 input wire score_valid,output wire score_ready,input wire[904:0] score_packet,
 input wire phone_valid,output wire phone_ready,input wire[904:0] phone_packet,
 input wire score_urgent,
 output wire event_valid,input wire event_ready,output wire[40:0] event_header,
 output wire[3:0] event_source,input wire retire,
 input wire[3:0] item_index,output reg[95:0] item_data,
 output reg[3:0] local_occupancy,output reg[2:0] occupancy
);
 reg[15:0] free_rows;
 reg[3:0] local_rows[0:7],global_rows[0:4];
 reg[2:0] local_read,local_write,global_read,global_write;
 reg owned;reg score_has_row,phone_has_row;reg[3:0] score_row,phone_row;
 reg[40:0] headers[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[3:0] sources[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[3:0] free_row;reg free_found;
 always @*begin
  free_row=0;free_found=0;
  for(integer i=15;i>=0;i--)if(free_rows[i])begin free_row=4'(i);free_found=1;end
 end
 function bad_item(input[95:0] w);
  begin bad_item=w[0] || w[27:24]<1 || w[27:24]>4 ||
   (w[27:24]==4 && (w[23:16]!=255 || w[15:9]!=0)) || (w[27:24]!=4 && w[95:32]==0);end
 endfunction
 wire[8:0] bad_words;
 wire bad_header=event_header[8:0]==0 || |(bad_words & event_header[8:0]);
 assign rejected=VALIDATE && !rst && occupancy!=0 && !owned && bad_header;
 assign discarded=DISCARD_LOCAL && !rst && discard_local && occupancy!=0 && !owned && event_source==0;
 wire release_head=retire || rejected || discarded;
 wire local_wait=local_occupancy!=0;
 wire first_valid,first_ready,first_score;
 performance_event_arbiter #(.WIDTH(1)) first_choice(.clk(clk),.rst(rst),
  .s0_valid(local_wait||local_valid),.s0_data(1'b0),.s0_ready(),
  .s1_valid(score_valid),.s1_data(1'b1),.s1_ready(),
  .m_valid(first_valid),.m_ready(first_ready),.m_data(first_score));
 reg locked,locked_phone;
 wire choose_phone=locked?locked_phone:(!first_valid&&phone_valid&&!score_urgent);
 wire selected_valid=choose_phone?phone_valid:first_valid;
 wire space=occupancy<5||release_head;
 wire promote_local=!rst&&space&&selected_valid&&!choose_phone&&!first_score&&local_wait;
 // Local capture has the only body write port. Descriptor-only promotion
 // can occur concurrently. A stalled remote producer retains its packet.
 assign local_ready=!rst&&free_found&&(local_occupancy<8||promote_local);
 wire capture_local=local_valid&&local_ready;
 wire direct_local=!rst&&space&&selected_valid&&!choose_phone&&!first_score&&!local_wait&&capture_local;
 wire buffer_local=capture_local&&!direct_local;
 assign score_write_ready=SHARED_SCORE&&!rst&&!capture_local&&(score_has_row||free_found);
 wire write_score=SHARED_SCORE&&score_write_valid&&score_write_ready;
 assign phone_write_ready=SHARED_PHONE&&!rst&&!capture_local&&!write_score&&(phone_has_row||free_found)&&!phone_write_abort;
 wire write_phone=SHARED_PHONE&&phone_write_valid&&phone_write_ready;
 wire reserve_phone=write_phone&&!phone_has_row;
 wire abort_phone=SHARED_PHONE&&phone_write_abort&&phone_has_row;
 wire reserve_score=write_score&&!score_has_row;
 wire score_complete=!SHARED_SCORE||(score_has_row&&!score_write_valid);
 wire admit_remote=!rst&&space&&selected_valid&&(choose_phone||first_score)&&!capture_local&&(choose_phone?(SHARED_PHONE&&phone_has_row?!phone_write_valid&&!phone_write_abort:!write_score&&!write_phone&&free_found):(!SHARED_SCORE?!write_score&&!write_phone&&free_found:score_complete));
 wire admitted=promote_local||direct_local||admit_remote;
 assign first_ready=admitted&&!choose_phone;
 assign score_ready=first_ready&&first_score;
 assign phone_ready=admit_remote&&choose_phone;
 wire write_packet=capture_local||(admit_remote&&(choose_phone?!SHARED_PHONE||!phone_has_row:!SHARED_SCORE));
 wire allocating=write_packet||reserve_score||reserve_phone;
 wire[3:0] admitted_row=SHARED_PHONE&&admit_remote&&choose_phone&&phone_has_row?phone_row:promote_local?local_rows[local_read]:(SHARED_SCORE&&admit_remote&&!choose_phone)?score_row:free_row;
 wire[3:0] head=global_rows[global_read];
 wire[904:0] input_packet=capture_local?local_packet:choose_phone?phone_packet:score_packet;
 assign event_valid=!rst&&occupancy!=0&&!owned&&!rejected&&!discarded;
 assign event_header=occupancy!=0?headers[head]:41'd0;
 assign event_source=occupancy!=0?sources[head]:4'd0;
 wire[95:0] read_words[0:8];
 for(genvar w=0;w<9;w++)begin:body
  reg bad[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
  reg[95:0] memory[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
  wire word_write=write_packet||(write_score&&score_write_index==w)||(write_phone&&phone_write_index==w);
  wire[3:0] word_address=write_packet?free_row:write_phone?(phone_has_row?phone_row:free_row):(score_has_row?score_row:free_row);
  wire[95:0] word_data=write_packet?input_packet[w*96+:96]:write_phone?phone_write_data:score_write_data;
  always @(posedge clk)if(word_write)begin memory[word_address]<=word_data;bad[word_address]<=bad_item(word_data);end
  assign bad_words[w]=bad[head];
  assign read_words[w]=memory[head];
 end
 reg[95:0] selected_word;
 always @*begin
  selected_word=0;
  for(integer i=0;i<9;i++)if(item_index==i)selected_word=read_words[i];
 end
 always @(posedge clk)begin
  if(rst)begin
   phone_has_row<=0;phone_row<=0;score_has_row<=0;score_row<=0;free_rows<=16'hffff;local_read<=0;local_write<=0;global_read<=0;global_write<=0;
   local_occupancy<=0;occupancy<=0;owned<=0;locked<=0;locked_phone<=0;item_data<=0;
  end else begin
   item_data<=occupancy!=0?selected_word:96'd0;
   if(admitted)locked<=0;
   else if(selected_valid)begin locked<=1;locked_phone<=choose_phone;end
   if(reserve_phone)begin phone_has_row<=1;phone_row<=free_row;end
   if(abort_phone || (SHARED_PHONE&&phone_ready))phone_has_row<=0;
   if(reserve_score)begin score_has_row<=1;score_row<=free_row;end
   if(SHARED_SCORE&&score_ready)score_has_row<=0;
   if(write_packet||(SHARED_SCORE&&score_ready)||(SHARED_PHONE&&phone_ready&&phone_has_row))begin
    headers[write_packet?free_row:choose_phone?phone_row:score_row]<=write_packet?input_packet[904:864]:choose_phone?phone_packet[904:864]:score_packet[904:864];
    sources[write_packet?free_row:choose_phone?phone_row:score_row]<=write_packet?(capture_local?4'd0:choose_phone?4'd2:4'd1):choose_phone?4'd2:4'd1;
   end
   free_rows<=(free_rows|(release_head?(16'h1<<head):16'd0)|(abort_phone?(16'h1<<phone_row):16'd0))&~(allocating?(16'h1<<free_row):16'd0);
   if(buffer_local)begin local_rows[local_write]<=free_row;local_write<=local_write+1'b1;end
   if(promote_local)local_read<=local_read+1'b1;
   case({buffer_local,promote_local})
    2'b10:local_occupancy<=local_occupancy+1'b1;
    2'b01:local_occupancy<=local_occupancy-1'b1;
    default:local_occupancy<=local_occupancy;
   endcase
   if(admitted)begin
    global_rows[global_write]<=admitted_row;
    global_write<=global_write==4?0:global_write+1'b1;
   end
   if(event_valid&&event_ready)owned<=1;
   if(release_head)begin owned<=0;global_read<=global_read==4?0:global_read+1'b1;end
   case({admitted,release_head})
    2'b10:occupancy<=occupancy+1'b1;
    2'b01:occupancy<=occupancy-1'b1;
    default:occupancy<=occupancy;
   endcase
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(occupancy>5||local_occupancy>8)$fatal(1,"R26_POOL_CAPACITY");
  if(retire&&(!owned||occupancy==0))$fatal(1,"R26_POOL_RETIRE_WITHOUT_OWNER");
  if(allocating&&!free_rows[free_row])$fatal(1,"R26_POOL_ROW_OVERWRITE");
  if(occupancy!=0&&free_rows[head])$fatal(1,"R26_POOL_FREE_HEAD");
  if(write_score&&score_write_index>=9)$fatal(1,"R26_POOL_SCORE_INDEX");
  if(owned&&item_index>=9)$fatal(1,"R26_POOL_INDEX");
 end
 // synthesis translate_on
endmodule
