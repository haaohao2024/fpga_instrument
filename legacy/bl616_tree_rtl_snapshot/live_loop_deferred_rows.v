// Source3 owns indices into the EXISTING 16-row event body RAM. Source2
// does not enter this queue. Only its head has one 32-bit due comparator.
// No 905-bit event packet or per-voice identity is duplicated here.
module live_loop_deferred_rows #(parameter integer LEAD_SAMPLES=240)(
 input wire clk,rst,input wire[31:0] sample_time,
 input wire push_valid,output wire push_ready,input wire[3:0] push_row,
 input wire[31:0] push_time,input wire[2:0] push_timbre,input wire[15:0] push_revision,
 output wire due_valid,input wire due_ready,output wire[3:0] due_row,
 output wire[31:0] due_time,output wire[2:0] due_timbre,output wire[15:0] due_revision,
 input wire cancel_valid,output wire cancel_ready,input wire cancel_all,input wire[15:0] cancel_revision,
 output reg cancel_done,output reg free_valid,output reg[3:0] free_row,
 output reg[2:0] occupancy
);
 reg[54:0] descriptors[0:3] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[1:0] rd,wr,scan,kept;reg cancelling,all_q;reg[15:0] revision_q;
 reg[2:0] cancel_count;
 wire[54:0] head=descriptors[rd];
 wire signed[31:0] until_due=$signed(head[50:19]-sample_time);
 assign due_row=head[54:51];assign due_time=head[50:19];
 assign due_timbre=head[18:16];assign due_revision=head[15:0];
 assign due_valid=!rst&&!cancelling&&!cancel_valid&&occupancy!=0&&until_due<=LEAD_SAMPLES;
 wire pop=due_valid&&due_ready;
 assign push_ready=!rst&&!cancelling&&!cancel_valid&&(occupancy<4||pop);
 wire push=push_valid&&push_ready;
 assign cancel_ready=!rst&&!cancelling;
 wire[1:0] scan_address=rd+scan,write_address=rd+kept;
 wire[54:0] scan_word=descriptors[scan_address];
 wire remove=all_q||scan_word[15:0]==revision_q;
 always @(posedge clk)begin
  free_valid<=0;cancel_done<=0;
  if(rst)begin rd<=0;wr<=0;occupancy<=0;cancelling<=0;all_q<=0;revision_q<=0;scan<=0;kept<=0;cancel_count<=0;free_row<=0;end
  else if(cancel_valid&&cancel_ready)begin
   all_q<=cancel_all;revision_q<=cancel_revision;scan<=0;kept<=0;cancel_count<=occupancy;
   if(occupancy==0)cancel_done<=1;else cancelling<=1;
  end else if(cancelling)begin
   if(remove)begin free_valid<=1;free_row<=scan_word[54:51];end
   else descriptors[write_address]<=scan_word;
   if({1'b0,scan}+3'd1==cancel_count)begin
    occupancy<={1'b0,kept}+(remove?3'd0:3'd1);
    wr<=rd+kept+(remove?2'd0:2'd1);cancelling<=0;cancel_done<=1;
   end else begin scan<=scan+1'b1;if(!remove)kept<=kept+1'b1;end
  end else begin
   if(push)begin descriptors[wr]<={push_row,push_time,push_timbre,push_revision};wr<=wr+1'b1;end
   if(pop)rd<=rd+1'b1;
   case({push,pop})2'b10:occupancy<=occupancy+1'b1;2'b01:occupancy<=occupancy-1'b1;default:begin end endcase
  end
 end
 // synthesis translate_off
 reg[31:0] last_time;reg have_time;
 always @(posedge clk)begin
  if(rst)begin have_time<=0;last_time<=0;end
  else begin
   if(cancel_done&&occupancy==0)have_time<=0;
   if(push)begin
    if(have_time&&$signed(push_time-last_time)<0)$fatal(1,"LOOP_ROWS_ORDER");
    if($signed(push_time-sample_time)<0)$fatal(1,"LOOP_ROWS_LATE");
    if(push_revision==0||push_timbre>5)$fatal(1,"LOOP_ROWS_METADATA");
    last_time<=push_time;have_time<=1;
   end
   if(occupancy>4)$fatal(1,"LOOP_ROWS_CAPACITY");
  end
 end
 initial if(LEAD_SAMPLES<0||LEAD_SAMPLES>=32'h40000000)$fatal(1,"LOOP_ROWS_HORIZON");
 // synthesis translate_on
endmodule
