// 4096-byte physical organization: one 1024x32 RAM, four words/record.
// Partial groups remain hidden until their END_GROUP record is stored.
module score_record_fifo(
 input wire clk,rst,clear,input wire s_valid,output wire s_ready,input wire [127:0] s_record,
 output reg m_valid,input wire m_ready,output reg [127:0] m_record,
 output wire [8:0] occupancy,visible_records,output reg [31:0] inserted,consumed,
 output reg preview_valid,output reg [63:0] preview_time,output reg [127:0] preview_notes
);
 reg [31:0] memory[0:1023];
 reg [31:0] committed;reg [8:0] open_count;
 reg [7:0] wr_slot,rd_slot;reg writing;reg [1:0] wi;reg [127:0] write_record;
 reg [2:0] read_state;reg [1:0] ri;reg [31:0] ram_read_data;
  reg [3:0] peek_state;reg [7:0] peek_slot;reg [8:0] peek_count;
  reg [127:0] peek_notes;reg [63:0] peek_time;reg peek_group_first;
 // One physical synchronous read port, multiplexed before RAM. Preview is
 // only eligible while the normal front record is already held (read_state=0).
  wire peek_read=m_valid&&!m_ready&&!preview_valid&&
   (peek_state==1||peek_state==3||peek_state==5||peek_state==7);
  wire [1:0] peek_word=(peek_state==1)?2'd0:(peek_state==3)?2'd1:(peek_state==5)?2'd2:2'd3;
  wire [9:0] ram_read_addr=peek_read?{peek_slot,peek_word}:{rd_slot,ri};
 always @(posedge clk)ram_read_data<=memory[ram_read_addr];
 assign occupancy=inserted-consumed;
 assign visible_records=committed-consumed;
 assign s_ready=!rst&&!clear&&!writing&&occupancy<256;
 always @(posedge clk)begin
  if(rst||clear)begin
   wr_slot<=0;rd_slot<=0;writing<=0;wi<=0;read_state<=0;ri<=0;
   m_valid<=0;inserted<=0;consumed<=0;committed<=0;open_count<=0;m_record<=0;write_record<=0;
    preview_valid<=0;preview_time<=0;preview_notes<=0;peek_state<=0;peek_notes<=0;peek_slot<=0;peek_count<=0;peek_time<=0;peek_group_first<=1;
  end else begin
   if(s_valid&&s_ready)begin writing<=1;wi<=0;write_record<=s_record;end
   if(writing)begin
    memory[{wr_slot,wi}]<=write_record[wi*32+:32];
    if(wi==3)begin
     writing<=0;wr_slot<=wr_slot+1'b1;inserted<=inserted+1;
     if(write_record[96])begin committed<=inserted+1;open_count<=0;end
     else open_count<=open_count+1;
    end else wi<=wi+1;
   end
   if(m_valid&&m_ready)begin m_valid<=0;consumed<=consumed+1;rd_slot<=rd_slot+1'b1;preview_valid<=0;peek_state<=0;end
   // Borrow the otherwise idle read port while the front record is held.
   // Consumption cancels preview; it never delays a scheduler read.
   if(m_valid&&!m_ready&&!preview_valid)case(peek_state)
     0:begin peek_slot<=rd_slot;peek_count<=0;peek_notes<=0;peek_group_first<=1;peek_state<=1;end
     1:begin peek_state<=2;end
     2:begin if(peek_group_first)peek_time[31:0]<=ram_read_data;peek_state<=3;end
     3:begin peek_state<=4;end
     4:begin if(peek_group_first)peek_time[63:32]<=ram_read_data;peek_state<=5;end
     5:begin peek_state<=6;end
     6:begin if(ram_read_data[7:0]==1&&ram_read_data[23:16]<128)peek_notes[ram_read_data[22:16]]<=1;peek_state<=7;end
     7:begin peek_state<=8;end
     8:begin
      peek_group_first<=ram_read_data[0];
      if(ram_read_data[0]&&peek_notes!=0)begin
       preview_valid<=1;preview_notes<=peek_notes;preview_time<=peek_time;peek_state<=0;
      end else if(peek_count+9'd1<visible_records)begin
       peek_slot<=peek_slot+1'b1;peek_count<=peek_count+1'b1;peek_state<=1;
      end else peek_state<=9;
     end
     // No ON in the committed prefix yet. Wait for another complete group;
     // never scan an uncommitted record, and never contend with normal reads.
     9:if(peek_count+9'd1<visible_records)begin
      peek_slot<=peek_slot+1'b1;peek_count<=peek_count+1'b1;peek_state<=1;
     end
   endcase
   case(read_state)
    0: if(!m_valid&&committed!=consumed)begin ri<=0;read_state<=1;end
    1: begin read_state<=2;end
    2: begin
     m_record[ri*32+:32]<=ram_read_data;
     if(ri==3)begin m_valid<=1;read_state<=0;end
     else begin ri<=ri+1;read_state<=1;end
    end
   endcase
  end
 end
endmodule
