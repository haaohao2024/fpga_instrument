// Capture physical input changes as compact frames, then construct one event
// at a time. Independent key tokens live in a single addressed RAM.
module r28_local_adapter(
 input wire clk,rst,overflow_recover,input wire[31:0] sample_time,
 input wire[7:0] note_gate,note_trigger,vibrato_depth,
 input wire[63:0] pressure_value,input wire[55:0] note_code,
 output wire write_valid,input wire write_ready,output wire[3:0] write_index,output wire[95:0] write_data,
 output wire commit_valid,input wire commit_ready,output wire[40:0] commit_header,
 output reg overflow,output wire pending,output reg[3:0] occupancy
);
 localparam[55:0] BASE={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
 reg[7:0] previous_gate,previous_vibrato;reg[63:0] previous_pressure;reg[55:0] previous_notes;
 reg[63:0] token_counter;reg[63:0] key_tokens[0:7] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[7:0] token_initialized;
 // Thirteen consecutive input edges fit even before serialization catches
 // up: this preserves the old five global + eight local burst capacity.
 // RAM16 primitives already have sixteen physical rows.
 reg[176:0] frames[0:15] /* synthesis syn_ramstyle="distributed_ram" */;
 reg[3:0] read_pointer,write_pointer;reg[176:0] frame;
 reg[3:0] slot;reg[1:0] state;
 reg[15:0] kinds;reg[8:0] changed;
 always @*begin
  kinds=0;changed=0;
  for(integer s=0;s<8;s++)begin
   if(note_trigger[s]||(note_gate[s]&&!previous_gate[s]))kinds[s*2+:2]=1;
   else if(!note_gate[s]&&previous_gate[s])kinds[s*2+:2]=2;
   else if(note_gate[s]&&(pressure_value[s*8+:8]!=previous_pressure[s*8+:8]||note_code[s*7+:7]!=previous_notes[s*7+:7]))kinds[s*2+:2]=3;
   changed[s]=kinds[s*2+:2]!=0;
  end
  changed[8]=vibrato_depth!=previous_vibrato;
 end
 wire pop=!rst&&state==0&&occupancy!=0&&!overflow;
 wire push=!rst&&|changed&&!overflow&&(occupancy<13||pop);
 wire[1:0] kind=frame[128+slot*2+:2];
 wire[63:0] next_token=token_counter==64'hffffffffffffffff ?64'd1:token_counter+64'd1;
 wire[63:0] selected_token=kind==1?next_token:token_initialized[slot[2:0]]?key_tokens[slot[2:0]]:64'd0;
 wire enabled=slot==8?frame[144]:kind!=0;
 assign write_valid=!rst&&!overflow&&state==1&&enabled;
 assign write_index=slot;
 assign write_data=slot==8?{64'd0,4'd0,4'd4,8'hff,7'd0,frame[7:0],1'b0}:
  {selected_token,4'd0,2'd0,kind,4'd0,slot,frame[72+slot*7+:7],frame[8+slot*8+:8],1'b0};
 reg[8:0] frame_mask;
 assign commit_header={frame[176:145],frame_mask};
 assign commit_valid=!rst&&!overflow&&state==2;
 assign pending=state!=0||occupancy!=0;
 always @(posedge clk)begin
  if(push)frames[write_pointer]<={sample_time,changed[8],kinds,note_code,pressure_value,vibrato_depth};
  if(write_valid&&write_ready&&slot<8&&kind==1)key_tokens[slot[2:0]]<=next_token;
 end
 always @(posedge clk)begin
  if(rst)begin
   previous_gate<=0;previous_vibrato<=0;previous_pressure<=0;previous_notes<=BASE;
   token_counter<=0;token_initialized<=0;read_pointer<=0;write_pointer<=0;occupancy<=0;
   state<=0;slot<=0;frame<=0;frame_mask<=0;overflow<=0;
  end else begin
   previous_gate<=note_gate;previous_vibrato<=vibrato_depth;previous_pressure<=pressure_value;previous_notes<=note_code;
   if(push)write_pointer<=write_pointer+1'b1;
   if(pop)begin read_pointer<=read_pointer+1'b1;frame<=frames[read_pointer];state<=1;slot<=0;frame_mask<=0;end
   case({push,pop})
    2'b10:occupancy<=occupancy+1'b1;
    2'b01:occupancy<=occupancy-1'b1;
    default:begin end
   endcase
   if(state==1&&(!enabled||write_ready))begin
    if(enabled)begin
     frame_mask[slot]<=1;
     if(slot<8&&kind==1)begin token_counter<=next_token;token_initialized[slot[2:0]]<=1;end
    end
    if(slot==8)state<=2;else slot<=slot+1'b1;
   end
   if(commit_valid&&commit_ready)state<=0;
   if(|changed&&!overflow&&occupancy==13&&!pop)overflow<=1;
   if(overflow)begin
    state<=0;occupancy<=0;read_pointer<=0;write_pointer<=0;
    if(overflow_recover&&note_gate==0)overflow<=0;
   end
  end
 end
endmodule
