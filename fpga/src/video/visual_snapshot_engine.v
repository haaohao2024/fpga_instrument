// Observer only: no signal from this module is connected to an audio ready/reset.
// RAM total here (including FFT/ROM): 15 BSRAM; pixel font adds the 16th.
module visual_snapshot_engine #(
 parameter COS_FILE="src/video/visual_cos_q16.mem",BOUNDS_FILE="src/video/visual_band_bounds.mem"
)(
 input wire clk,pixel_clk,rst,pixel_rst,input wire audio_rst,
 input wire sample_valid,input wire signed [15:0] sample_l,sample_r,input wire [63:0] sample_id,
 input wire [511:0] status,input wire [1:0] display_scale,
 input wire vblank,
 input wire wave_read_enable,xy_read_enable,spectrum_read_enable,
 input wire [9:0] wave_read_address,xy_read_address,input wire [7:0] spectrum_read_address,
 output wire [15:0] wave_read_data,xy_read_data,spectrum_read_data,
 output wire front_valid,output wire [1023:0] front_metadata,
 output reg [63:0] observed,captured,skipped,
 output reg [31:0] completed_windows,output wire [31:0] published,presented,
 output reg [63:0] waiting_cycles,output reg error,
 output reg [63:0] total_observed,total_captured,total_skipped,cancelled_samples,
 output reg [31:0] cancelled_windows,delivered_windows,
 output reg [12:0] outstanding_pairs,
 output reg [63:0] skipped_reset,skipped_processing,skipped_waiting,
 output wire [18:0] last_processing_cycles
);
 wire back_ready,back_bank,front_bank,pending;
 reg publish;reg [1023:0] metadata;
 wire req,ack;
 visual_bank_exchange exchange(.process_clk(clk),.pixel_clk(pixel_clk),.process_rst(rst),.pixel_rst(pixel_rst),
  .publish(publish),.metadata(metadata),.back_ready(back_ready),.back_bank(back_bank),.vblank(vblank),
  .front_valid(front_valid),.front_bank(front_bank),.front_metadata(front_metadata),
  .published_count(published),.presented_count(presented),.pending(pending),.observe_req(req),.observe_ack(ack));
 reg [2:0] state;
 reg [9:0] clear_address;
 reg [11:0] capture_index;
 reg [63:0] first_id,previous_id;
 reg fft_start;
 // status[511] selects the field-test spectrum view for a whole window.
 reg linear_q;
 wire fft_ready,fft_capturing,fft_busy,fft_done,fft_error,sv,sr;
 wire [11:0] bin;wire signed [17:0] lr,li,rr,ri;
 wire [36:0] lp,rp;wire [18:0] processing_cycles;
 visual_fft4096 #(.ROM_FILE(COS_FILE)) fft(.clk(clk),.rst(rst),.start(fft_start),.rectangular(linear_q),
  .sample_valid(sample_valid&&state==3),.sample_l(sample_l),.sample_r(sample_r),.sample_ready(fft_ready),
  .capturing(fft_capturing),.busy(fft_busy),.spectrum_valid(sv),.spectrum_ready(sr),.spectrum_bin(bin),
  .left_real(lr),.left_imag(li),.right_real(rr),.right_imag(ri),.left_power(lp),.right_power(rp),
  .done(fft_done),.error(fft_error),.processing_cycles(processing_cycles),.last_processing_cycles(last_processing_cycles));
 wire spectrum_we,bars_done;wire [7:0] spectrum_column,dc_l,dc_r;wire [15:0] spectrum_data;
 visual_spectrum_bars #(.BOUNDS_FILE(BOUNDS_FILE)) bars(.clk(clk),.rst(rst),.start(fft_start),.linear(linear_q),.spectrum_valid(sv),
  .spectrum_ready(sr),.bin(bin),.left_power(lp),.right_power(rp),.write_enable(spectrum_we),
  .write_column(spectrum_column),.write_data(spectrum_data),.done(bars_done),.dc_left(dc_l),.dc_right(dc_r));
 reg wave_we,xy_we;reg [9:0] wave_address,xy_address,xy_process_address;
 reg [15:0] wave_data,xy_data;
 wire [15:0] xy_previous;
 wire xy_write=(state==1)||xy_we;
 wire [9:0] xy_write_address=state==1?clear_address:xy_address;
 wire [15:0] xy_write_data=state==1?16'd0:xy_data;
 visual_plot_memory wave_ram(.process_clk(clk),.write_enable(wave_we&&!rst),.write_address({back_bank,wave_address}),.write_data(wave_data),
  .process_read_address(11'd0),.process_read_data(),.pixel_clk(pixel_clk),.read_enable(wave_read_enable&&front_valid),
  .read_address({front_bank,wave_read_address}),.read_data(wave_read_data));
 visual_plot_memory #(.PROCESS_RW_PORT(1)) xy_ram(.process_clk(clk),.write_enable(xy_write&&!rst),.write_address({back_bank,xy_write_address}),.write_data(xy_write_data),
  .process_read_address({back_bank,xy_process_address}),.process_read_data(xy_previous),.pixel_clk(pixel_clk),.read_enable(xy_read_enable&&front_valid),
  .read_address({front_bank,xy_read_address}),.read_data(xy_read_data));
 visual_plot_memory #(.ADDRESS_BITS(9)) spectrum_ram(.process_clk(clk),.write_enable(spectrum_we&&!rst),.write_address({back_bank,spectrum_column}),.write_data(spectrum_data),
  .process_read_address(9'd0),.process_read_data(),.pixel_clk(pixel_clk),.read_enable(spectrum_read_enable&&front_valid),
  .read_address({front_bank,spectrum_read_address}),.read_data(spectrum_read_data));
 reg [2:0] wave_state,xy_state;
 reg signed [15:0] first_l,first_r,min_l,max_l,min_r,max_r;
 reg [7:0] wave_column;
 reg [3:0] xy_bit;
 wire [15:0] unsigned_l=sample_l^16'h8000,unsigned_r=sample_r^16'h8000;
 // Screen Y increases downwards: negative R is above the center, per 8A.
 wire [13:0] xy_point={unsigned_r[15:9],unsigned_l[15:9]};
 wire take=state==3&&sample_valid&&fft_ready;
 // Lifetime diagnostics use audio reset only. Display reset cancels ownership,
 // but cannot erase the accounting of already observed/captured samples.
 // A delivered window means the full source-side four-phase handshake closed;
 // a window reset before that point is unconfirmed and counted as cancelled.
 always @(posedge clk)begin
  if(audio_rst)begin
   total_observed<=0;total_captured<=0;total_skipped<=0;cancelled_samples<=0;
   cancelled_windows<=0;delivered_windows<=0;outstanding_pairs<=0;
   skipped_reset<=0;skipped_processing<=0;skipped_waiting<=0;
  end else begin
   if(sample_valid)begin
    total_observed<=total_observed+1'b1;
    if(!rst&&take)total_captured<=total_captured+1'b1;
    else begin
     total_skipped<=total_skipped+1'b1;
     if(rst)skipped_reset<=skipped_reset+1'b1;
     else if(pending||!back_ready)skipped_waiting<=skipped_waiting+1'b1;
     else skipped_processing<=skipped_processing+1'b1;
    end
   end
   if(rst)begin
    if(outstanding_pairs!=0)begin
     cancelled_samples<=cancelled_samples+outstanding_pairs;
     cancelled_windows<=cancelled_windows+1'b1;
    end
    outstanding_pairs<=0;
   end else if(take)outstanding_pairs<=outstanding_pairs+1'b1;
   else if(state==7&&back_ready)begin
    delivered_windows<=delivered_windows+1'b1;outstanding_pairs<=0;
   end
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=0;publish<=0;metadata<=0;clear_address<=0;capture_index<=0;first_id<=0;previous_id<=0;
   fft_start<=0;observed<=0;captured<=0;skipped<=0;completed_windows<=0;waiting_cycles<=0;error<=0;
   wave_we<=0;xy_we<=0;wave_address<=0;xy_address<=0;xy_process_address<=0;wave_data<=0;xy_data<=0;
   wave_state<=0;xy_state<=0;first_l<=0;first_r<=0;min_l<=0;max_l<=0;min_r<=0;max_r<=0;wave_column<=0;xy_bit<=0;
  end else begin
   fft_start<=0;publish<=0;wave_we<=0;xy_we<=0;
   if(sample_valid)begin observed<=observed+1'b1;if(take)captured<=captured+1'b1;else skipped<=skipped+1'b1;end
   if(pending)waiting_cycles<=waiting_cycles+1'b1;
   if(fft_error)error<=1;
   case(state)
    0:if(back_ready)begin clear_address<=0;state<=1;end
    1:if(clear_address==1023)state<=2;else clear_address<=clear_address+1'b1;
    2:begin fft_start<=1;linear_q<=status[511];capture_index<=0;state<=3;end
    3:if(take)begin
     if(capture_index==0)first_id<=sample_id;
     else if(sample_id!=previous_id+1'b1)error<=1;
     previous_id<=sample_id;
     if(capture_index>=3584)begin
      if(!capture_index[0])begin first_l<=sample_l;first_r<=sample_r;end
      else begin
       if(wave_state!=0)error<=1;
       min_l<=sample_l<first_l?sample_l:first_l;max_l<=sample_l>first_l?sample_l:first_l;
       min_r<=sample_r<first_r?sample_r:first_r;max_r<=sample_r>first_r?sample_r:first_r;
       wave_column<=capture_index[8:1];wave_state<=1;
      end
     end
     if(capture_index>=3072)begin
      if(xy_state!=0)error<=1;
      xy_process_address<=xy_point[13:4];xy_address<=xy_point[13:4];xy_bit<=xy_point[3:0];xy_state<=1;
     end
     if(capture_index==4095)begin
      // All status inputs captured at the SAME last DAC load as the PCM window.
      metadata<={224'd0,cancelled_windows,status,skipped,14'd0,display_scale,16'd0,completed_windows,sample_id,first_id};
      state<=4;
     end else capture_index<=capture_index+1'b1;
    end
    // The height pipeline owns the final bin after the FFT releases it.
    // Publish only after its final column has reached spectrum RAM.
    4:if(bars_done)begin
     if(wave_state!=0||xy_state!=0)error<=1;
     metadata[175:160]<= {dc_l,dc_r};completed_windows<=completed_windows+1'b1;state<=5;
    end
    5:begin publish<=1;state<=6;end
    6:if(pending)state<=7;
    7:if(back_ready)state<=0;
   endcase
   case(wave_state)
    1:begin wave_we<=1;wave_address<={wave_column,2'd0};wave_data<=min_l;wave_state<=2;end
    2:begin wave_we<=1;wave_address<={wave_column,2'd1};wave_data<=max_l;wave_state<=3;end
    3:begin wave_we<=1;wave_address<={wave_column,2'd2};wave_data<=min_r;wave_state<=4;end
    4:begin wave_we<=1;wave_address<={wave_column,2'd3};wave_data<=max_r;wave_state<=0;end
   endcase
   case(xy_state)
    1:xy_state<=2;
    2:begin xy_data<=xy_previous|(16'b1<<xy_bit);xy_state<=3;end
    3:begin xy_we<=1;xy_state<=0;end
   endcase
  end
 end
endmodule
