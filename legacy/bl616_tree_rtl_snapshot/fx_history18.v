// One synchronous read port, one write port; RAM contents are NEVER reset.
// wr_ptr points to the next write. lag=1 is the preceding written sample.
module fx_history18 #(
    parameter integer DEPTH=2048, LENGTH=2048, AW=11
)(
    input wire clk,rst,clear,
    input wire read_en,
    input wire [14:0] read_lag,
    output reg signed [17:0] read_data,
    output reg read_valid,
    input wire write_en,
    input wire signed [17:0] write_data
);

    reg [AW-1:0] wr_ptr;
    reg [14:0] filled;
    wire signed [17:0] read_pipe;
    reg pipe_valid,pipe_known;
    wire [15:0] address_wide = ({1'b0,wr_ptr}>=read_lag) ?
        ({1'b0,wr_ptr}-read_lag) : ({1'b0,wr_ptr}+LENGTH-read_lag);
    r32_ram18_sdp #(.AW(AW)) storage(.clk(clk),
        .we(write_en && !rst && !clear),.wa(wr_ptr),.di(write_data),
        .re(read_en),.ra(address_wide[AW-1:0]),.q(read_pipe));
    always @(posedge clk) begin
        if(rst || clear) begin
            wr_ptr<=0;filled<=0;pipe_valid<=0;pipe_known<=0;
            read_data<=0;read_valid<=0;
        end else begin
            pipe_valid<=read_en;
            pipe_known<=read_en && read_lag>=1 && read_lag<=filled && read_lag<=LENGTH;
            read_valid<=pipe_valid;
            read_data<=pipe_known ? read_pipe : 18'sd0;
            if(write_en) begin
                wr_ptr<=(wr_ptr==LENGTH-1)?0:wr_ptr+1'b1;
                if(filled<LENGTH)filled<=filled+1'b1;
            end
        end
    end
endmodule

// Native 1024 x 18 banks. Select follows the synchronous read, not its request.
module r32_ram18_sdp #(parameter AW=11)(
 input wire clk,we,re,input wire[AW-1:0] wa,ra,
 input wire[17:0] di,output wire[17:0] q);
 localparam BANKS=1<<(AW-10);
 reg[AW-11:0] selected;
 wire[17:0] bank_q[0:BANKS-1];
 always @(posedge clk)if(re)selected<=ra[AW-1:10];
 assign q=bank_q[selected];
 for(genvar b=0;b<BANKS;b=b+1)begin: banks
  wire[35:0] data_out;
  assign bank_q[b]=data_out[17:0];
  SDPX9B #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.READ_MODE(0)) ram(
   .CLKA(clk),.CLKB(clk),.CEA(we && wa[AW-1:10]==b),.CEB(re && ra[AW-1:10]==b),
   .ADA({wa[9:0],4'b0011}),.ADB({ra[9:0],4'b0000}),.DI({18'd0,di}),.DO(data_out),
   .BLKSELA(3'd0),.BLKSELB(3'd0),.OCE(1'b1),.RESET(1'b0));
 end
endmodule

module r32_ram18_dp #(parameter AW=12)(
 input wire clk,ea,eb,wea,web,input wire[AW-1:0] aa,ab,
 input wire[17:0] da,db,output wire[17:0] qa,qb);
 localparam BANKS=1<<(AW-10);
 reg[AW-11:0] selected_a,selected_b;
 wire[17:0] bank_a[0:BANKS-1],bank_b[0:BANKS-1];
 always @(posedge clk)begin
  if(ea && !wea)selected_a<=aa[AW-1:10];
  if(eb && !web)selected_b<=ab[AW-1:10];
 end
 assign qa=bank_a[selected_a];assign qb=bank_b[selected_b];
 for(genvar b=0;b<BANKS;b=b+1)begin: banks
  DPX9B #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.READ_MODE0(0),.READ_MODE1(0),
   .WRITE_MODE0(0),.WRITE_MODE1(0)) ram(
   .CLKA(clk),.CLKB(clk),.CEA(ea && aa[AW-1:10]==b),.CEB(eb && ab[AW-1:10]==b),
   .WREA(wea),.WREB(web),.ADA({aa[9:0],4'b0011}),.ADB({ab[9:0],4'b0011}),
   .DIA(da),.DIB(db),.DOA(bank_a[b]),.DOB(bank_b[b]),.BLKSELA(3'd0),.BLKSELB(3'd0),
   .OCEA(1'b1),.OCEB(1'b1),.RESETA(1'b0),.RESETB(1'b0));
 end
endmodule

// Four disjoint rings, 7492 words in eight native 1024 x 18 banks.
// Original schedule: read pairs 0/1 at 55 and 2/3 at 56;
// write pairs at 68 and 69. No memory access is delayed.
module r32_reverb_history(
 input wire clk,rst,clear,input wire[3:0] read_en,write_en,
 input wire[71:0] write_data,output reg[71:0] read_data,output reg[3:0] read_valid);
 wire[12:0] address[0:3];
 reg[3:0] full,pipe_valid,pipe_known;
 wire[17:0] qa,qb;
 wire second=read_en[2] || write_en[2];
 wire any_write=|write_en;
 wire[12:0] aa=second?address[2]:address[0];
 wire[12:0] ab=second?address[3]:address[1];
 r32_ram18_dp #(.AW(13)) memory(.clk(clk),
  .ea((|read_en)||((|write_en)&&!rst&&!clear)),
  .eb((|read_en)||((|write_en)&&!rst&&!clear)),
  .wea(any_write&&!rst&&!clear),.web(any_write&&!rst&&!clear),.aa(aa),.ab(ab),
  .da(second?write_data[53:36]:write_data[17:0]),
  .db(second?write_data[71:54]:write_data[35:18]),.qa(qa),.qb(qb));
 for(genvar g=0;g<4;g=g+1)begin: ring
  localparam N=(g==0)?1567:(g==1)?1789:(g==2)?1999:2137;
  localparam OFFSET=(g==0)?0:(g==1)?1567:(g==2)?3356:5355;
  localparam AW=(g==3)?12:11;
  reg[AW-1:0] pointer;
  assign address[g]=13'(OFFSET)+pointer;
  always @(posedge clk)begin
   if(rst||clear)begin
    pointer<=0;full[g]<=0;pipe_valid[g]<=0;pipe_known[g]<=0;
    read_valid[g]<=0;read_data[g*18+:18]<=0;
   end else begin
    pipe_valid[g]<=read_en[g];pipe_known[g]<=read_en[g]&&full[g];
    read_valid[g]<=pipe_valid[g];
    read_data[g*18+:18]<=pipe_known[g]?((g%2==0)?qa:qb):18'd0;
    if(write_en[g])begin
     if(pointer==N-1)begin pointer<=0;full[g]<=1;end
     else pointer<=pointer+1'b1;
    end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&!clear)begin
  if((|read_en)&&(|write_en))$fatal(1,"REVERB_READ_WRITE_COLLISION");
  if(read_en!=0&&read_en!=4'b0011&&read_en!=4'b1100)$fatal(1,"REVERB_READ_PAIR");
  if(write_en!=0&&write_en!=4'b0011&&write_en!=4'b1100)$fatal(1,"REVERB_WRITE_PAIR");
  if((|read_en)||(|write_en))if(aa==ab)$fatal(1,"REVERB_PARTITION_COLLISION");
 end
 // synthesis translate_on
endmodule
