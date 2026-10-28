// Recorder-only 128k -> 48k rational FIR. Never drives the DAC or event clock.
// One 18x18 multiplier, one 1024x18 dual-port coefficient/history memory.
// Outputs carry the global48k index and capture ownership chosen at input time.
module rec48_downsample(
 input wire clk,rst,audio_reset,start_valid,stop_valid,
 input wire observe_load,input wire signed[15:0] observe_l,observe_r,
 input wire[63:0] observe_frame_id,
 output reg result_valid,output reg signed[15:0] result_l,result_r,
 output reg[63:0] result_index,output wire stop_retired,
 output reg source_fault,output wire owned_inflight
);
 localparam IDLE=0,WRITE_R=1,ISSUE=2,DRAIN=3,FINISH=4;
 reg[2:0] state;
 (* syn_ramstyle="block_ram" *) reg signed[17:0] memory[0:1023];
 initial $readmemh("src/rec48_ram.mem",memory);
 reg[6:0] write_pointer,job_pointer;
 reg[7:0] valid_history,job_history;
 reg signed[15:0] held_r;
 reg[7:0] issue_index;
 reg[1:0] job_phase;
 reg[2:0] source_mod8;
 reg[63:0] expected_native,next_index,job_index;
 reg capturing,job_owned,stop_pending;
 wire trigger=source_mod8==0||source_mod8==2||source_mod8==5;
 wire[1:0] trigger_phase=source_mod8==0?2'd0:source_mod8==2?2'd2:2'd1;
 wire input_good=observe_frame_id==expected_native;
 wire[6:0] tap=issue_index[7:1];
 wire channel=issue_index[0];
 wire[6:0] history_pointer=job_pointer-tap;
 wire write_left=observe_load&&state==IDLE&&!rst&&!audio_reset&&!source_fault;
 wire write_right=state==WRITE_R&&!rst&&!audio_reset;
 wire[9:0] coefficient_address={2'd0,tap,1'b0}+tap+job_phase;
 wire[9:0] address_a=write_left?{3'b100,write_pointer}:
   write_right?{3'b101,job_pointer}:coefficient_address;
 wire[9:0] address_b=channel?{3'b101,history_pointer}:{3'b100,history_pointer};
 wire signed[17:0] write_data=write_left?{{2{observe_l[15]}},observe_l}:{{2{held_r[15]}},held_r};
 reg signed[17:0] coefficient_q,sample_q;
 always @(posedge clk)begin
  // GW5AT DPX9B supports write-through/no-change, not read-before-write.
  // A-port read data during input writes is not owned by a multiply issue.
  if(write_left||write_right)begin memory[address_a]<=write_data;coefficient_q<=write_data;end
  else coefficient_q<=memory[address_a];
  sample_q<=memory[address_b];
 end
 reg read_valid,read_channel,read_present;
 reg multiply_valid,multiply_channel;
 reg signed[35:0] product;
 reg signed[39:0] accumulator_l,accumulator_r;
 wire signed[17:0] operand=read_present?sample_q:18'sd0;
 assign owned_inflight=job_owned&&state!=IDLE;
 // A result presented this cycle must reach the recorder before STOP.
 assign stop_retired=(stop_pending||stop_valid)&&!owned_inflight&&!result_valid;
 function signed[15:0] rounded_pcm(input signed[39:0] value);
  reg[39:0] magnitude;reg signed[40:0] rounded;
  begin
   magnitude=value[39]?-value:value;
   rounded=$signed({1'b0,((magnitude+40'd65536)>>17)});
   if(value[39])rounded=-rounded;
   if(rounded>32767)rounded_pcm=16'sh7fff;
   else if(rounded< -32768)rounded_pcm=16'sh8000;
   else rounded_pcm=rounded[15:0];
  end
 endfunction
 always @(posedge clk)begin
  if(rst||audio_reset)begin
   state<=IDLE;write_pointer<=0;job_pointer<=0;valid_history<=0;job_history<=0;
   held_r<=0;issue_index<=0;job_phase<=0;source_mod8<=0;
   expected_native<=0;next_index<=0;job_index<=0;
   capturing<=0;job_owned<=0;stop_pending<=0;source_fault<=0;
   result_valid<=0;result_l<=0;result_r<=0;result_index<=0;
   read_valid<=0;read_channel<=0;read_present<=0;multiply_valid<=0;multiply_channel<=0;
   product<=0;accumulator_l<=0;accumulator_r<=0;
  end else begin
   result_valid<=0;
   read_valid<=state==ISSUE;
   if(state==ISSUE)begin read_channel<=channel;read_present<=tap<job_history;end
   multiply_valid<=read_valid;
   if(read_valid)begin product<=coefficient_q*operand;multiply_channel<=read_channel;end
   if(multiply_valid)begin
    if(multiply_channel)accumulator_r<=accumulator_r+{{4{product[35]}},product};
    else accumulator_l<=accumulator_l+{{4{product[35]}},product};
   end
   if(start_valid)capturing<=1;
   if(stop_valid)begin capturing<=0;stop_pending<=1;end
   if(stop_retired)stop_pending<=0;
   if(observe_load&&!source_fault)begin
    if(!input_good||state!=IDLE)begin source_fault<=1;capturing<=0;job_owned<=0;end
    else begin
     expected_native<=observe_frame_id+1'b1;source_mod8<=source_mod8+1'b1;
     write_pointer<=write_pointer+1'b1;job_pointer<=write_pointer;held_r<=observe_r;
     if(valid_history<128)valid_history<=valid_history+1'b1;
     job_history<=valid_history<128?valid_history+1'b1:8'd128;
     job_phase<=trigger_phase;job_index<=next_index;
     job_owned<=trigger&&capturing&&!start_valid&&!stop_valid;
     if(trigger)next_index<=next_index+1'b1;
     state<=WRITE_R;
    end
   end
   if(state==WRITE_R)begin
    if(source_mod8==1||source_mod8==3||source_mod8==6)begin
     accumulator_l<=0;accumulator_r<=0;issue_index<=0;state<=ISSUE;
    end else begin state<=IDLE;job_owned<=0;end
   end
   if(state==ISSUE)begin
    if(issue_index==223)state<=DRAIN;
    else issue_index<=issue_index+1'b1;
   end
   if(state==DRAIN&&!read_valid&&!multiply_valid)state<=FINISH;
   if(state==FINISH)begin
    result_l<=rounded_pcm(accumulator_l);result_r<=rounded_pcm(accumulator_r);
    result_index<=job_index;result_valid<=job_owned&&!source_fault;
    job_owned<=0;state<=IDLE;
   end
  end
 end
 // synthesis translate_off
 integer work_cycles;
 always @(posedge clk)begin
  if(rst||audio_reset||state==IDLE)work_cycles<=0;
  else begin work_cycles<=work_cycles+1;if(work_cycles>238)$fatal(1,"REC48_SCHEDULE_240");end
 end
 // synthesis translate_on
endmodule
