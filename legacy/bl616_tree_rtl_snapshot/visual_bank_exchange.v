// Four-phase bundled-data exchange. Metadata and offered bank stay stable until
// ack returns low. Pixel switch is allowed only after the read pipeline drains.
module visual_bank_exchange(
 input wire process_clk,pixel_clk,process_rst,pixel_rst,
 input wire publish,input wire [1023:0] metadata,
 output wire back_ready,output reg back_bank,
 input wire vblank,
 output reg front_valid,front_bank,output reg [1023:0] front_metadata,
 output reg [31:0] published_count,presented_count,
 output wire pending,output wire observe_req,observe_ack
);
 reg req,ack,source_up,pixel_up;
 reg [1023:0] held_metadata;
 reg offered_bank;
 reg [1:0] source_state,pixel_state;
 (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,req_sync,pixel_up_sync,source_up_sync;
 reg [2:0] blank_age;
 assign back_ready=source_up&&pixel_up_sync[1]&&source_state==0;
 assign pending=source_state!=0;
 assign observe_req=req;assign observe_ack=ack;
 always @(posedge process_clk or posedge process_rst)begin
  if(process_rst)begin
   source_up<=0;ack_sync<=0;pixel_up_sync<=0;req<=0;source_state<=0;
   back_bank<=1;held_metadata<=0;offered_bank<=1;published_count<=0;
  end else begin
   source_up<=1;ack_sync<={ack_sync[0],ack};pixel_up_sync<={pixel_up_sync[0],pixel_up};
   case(source_state)
    0:if(publish&&back_ready)begin held_metadata<=metadata;offered_bank<=back_bank;req<=1;source_state<=1;published_count<=published_count+1'b1;end
    1:if(ack_sync[1])begin req<=0;back_bank<=~offered_bank;source_state<=2;end
    2:if(!ack_sync[1])source_state<=0;
    default:source_state<=0;
   endcase
  end
 end
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)begin
   pixel_up<=0;source_up_sync<=0;req_sync<=0;ack<=0;pixel_state<=0;
   blank_age<=0;front_valid<=0;front_bank<=0;front_metadata<=0;presented_count<=0;
  end else begin
   pixel_up<=1;source_up_sync<={source_up_sync[0],source_up};req_sync<={req_sync[0],req};
   if(!vblank)blank_age<=0;else if(blank_age!=7)blank_age<=blank_age+1'b1;
   case(pixel_state)
    0:if(source_up_sync[1]&&req_sync[1])pixel_state<=1;
    // Extra stable cycle for held bundled bus; do not acknowledge early.
    1:pixel_state<=2;
    2:if(vblank&&blank_age>=3)begin
      front_bank<=offered_bank;front_metadata<=held_metadata;front_valid<=1;
      ack<=1;presented_count<=presented_count+1'b1;pixel_state<=3;
     end
    3:if(!req_sync[1])begin ack<=0;pixel_state<=0;end
   endcase
  end
 end
endmodule
