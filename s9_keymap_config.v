`include "s9_constants.vh"
// Atomic configuration shadow; only already-effective mapping survives disconnect.
// Old pending application and a same-edge new request have explicit distinct
// outcomes: old applies if idle, otherwise it is superseded/cancelled.
module s9_keymap_config(
 input wire clk,rst,disconnect,
 input wire cfg_valid,input wire[63:0] cfg_notes,input wire[31:0] cfg_sequence,input wire[2:0] cfg_slot,
 input wire[7:0] local_gate,input wire local_pending,
 output reg[55:0] active_notes,output reg[31:0] version,
 output reg accepted,output reg rejected,
 output reg applied,output reg[31:0] applied_sequence,output reg[2:0] applied_slot,
 output reg cancelled,output reg[31:0] cancelled_sequence,output reg[2:0] cancelled_slot,
 output reg pending
);
 localparam[55:0] DEFAULT_NOTES={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
 reg[55:0] shadow;reg[31:0] pending_sequence;reg[2:0] pending_slot;
 reg legal;integer k;
 wire idle=local_gate==0&&!local_pending;
 always @*begin legal=1;for(integer j=0;j<8;j=j+1)if(cfg_notes[j*8+:8]<`S9_KEYMAP_MIN||cfg_notes[j*8+:8]>`S9_KEYMAP_MAX)legal=0;end
 always @(posedge clk)begin
  if(rst)begin
   active_notes<=DEFAULT_NOTES;shadow<=DEFAULT_NOTES;version<=0;pending<=0;pending_sequence<=0;pending_slot<=0;
   accepted<=0;rejected<=0;applied<=0;applied_sequence<=0;applied_slot<=0;cancelled<=0;cancelled_sequence<=0;cancelled_slot<=0;
  end else begin
   accepted<=0;rejected<=0;applied<=0;cancelled<=0;
   if(disconnect)begin
    if(pending)begin cancelled<=1;cancelled_sequence<=pending_sequence;cancelled_slot<=pending_slot;end
    pending<=0;
   end else begin
    if(pending&&idle)begin
     active_notes<=shadow;pending<=0;version<=version+1'b1;
     applied<=1;applied_sequence<=pending_sequence;applied_slot<=pending_slot;
    end
    if(cfg_valid)begin
     if(!legal)rejected<=1;
     else begin
      accepted<=1;pending<=1;pending_sequence<=cfg_sequence;pending_slot<=cfg_slot;
      for(k=0;k<8;k=k+1)shadow[k*7+:7]<=cfg_notes[k*8+:7];
      if(pending&&!idle)begin cancelled<=1;cancelled_sequence<=pending_sequence;cancelled_slot<=pending_slot;end
     end
    end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if((^{cfg_valid,disconnect,local_pending,local_gate})===1'bx)$fatal(1,"S9_KEYMAP_CONTROL_XZ");
  if(cfg_valid&&(^({cfg_notes,cfg_sequence,cfg_slot}))===1'bx)$fatal(1,"S9_KEYMAP_CONFIG_XZ");
 end
 // synthesis translate_on
endmodule
