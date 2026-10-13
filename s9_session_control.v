// Session identity / lease boundary. All time arithmetic is unsigned modulo32.
// Only phone-source close is driven; no audio reset or global panic exists here.
module s9_session_control #(parameter integer LEASE_MS=500, PREDICTIVE_LEASE=0)(
 input wire clk,rst,input wire[31:0] now_ms,
 input wire [31:0] now_ms_next,
 input wire management_valid,output wire management_ready,
 input wire[7:0] management_op,input wire[127:0] management_session,
 input wire phone_open_ready,phone_active,phone_close_done,
 output reg phone_open,phone_close,flush,
 output reg[127:0] session_id,output reg[2:0] link_state,
 output wire session_ready,
 output reg management_done,output reg signed[15:0] management_error,
 output reg[31:0] opened_count,closed_count,expired_count,rejected_count
);
 localparam DOWN=0,OPENING=1,READY=2,CLOSING=3;
 reg[31:0] renewed_ms;
 wire reference_expired=link_state==READY&&(now_ms-renewed_ms>=LEASE_MS);
 wire prepared_ready;
 wire lease_expired=PREDICTIVE_LEASE?(link_state==READY&&!prepared_ready):reference_expired;
 assign session_ready=PREDICTIVE_LEASE?prepared_ready:(link_state==READY&&!lease_expired);
 // Predict the post-edge state and time together. The original producer
 // supplies exactly the now_ms value it will publish on this same edge.
 // This is not a delayed expiration check: expiry and renewal edges stay exact.
 generate if(PREDICTIVE_LEASE)begin: prepare_lease
  reg ready_r;reg [2:0] next_link;reg [31:0] next_renewed;
  always @*begin
   next_link=link_state;next_renewed=renewed_ms;
   if(link_state==OPENING&&phone_active)begin next_link=READY;next_renewed=now_ms;end
   if(link_state==CLOSING&&phone_close_done)next_link=DOWN;
   if(lease_expired)next_link=CLOSING;
   if(management_valid&&management_ready)begin
    if(management_op==8'h80)begin end
    else if(management_session[63:0]==0||management_session[127:64]==0)begin end
    else if(management_op==8'h90)begin
     if(link_state==DOWN&&phone_open_ready&&
       (management_session[63:0]!=session_id[63:0]||management_session[127:64]>session_id[127:64]))next_link=OPENING;
     else if(management_session==session_id&&(link_state==READY||link_state==OPENING)&&!lease_expired)next_renewed=now_ms;
    end else if(management_session!=session_id)begin end
    else if(management_op==8'h91&&link_state==READY&&!lease_expired)next_renewed=now_ms;
    else if(management_op==8'h92&&(link_state==READY||link_state==OPENING))next_link=CLOSING;
   end
  end
  always @(posedge clk)if(rst)ready_r<=0;
   else ready_r<=next_link==READY&&(now_ms_next-next_renewed<LEASE_MS);
  assign prepared_ready=ready_r;
  // synthesis translate_off
  reg [31:0] promised_ms;
  always @(posedge clk)promised_ms<=rst?32'd0:now_ms_next;
  always @(negedge clk)if(!rst)begin
   if(now_ms!==promised_ms)$fatal(1,"CFG_LEASE_TIME_PREDICTION");
   if(ready_r!==(link_state==READY&&!reference_expired))$fatal(1,"CFG_LEASE_READY_REFERENCE");
  end
  // synthesis translate_on
 end else begin: ordinary_lease
  assign prepared_ready=1'b0;
 end endgenerate
 assign management_ready=!rst;
 always @(posedge clk)begin
  if(rst)begin
   phone_open<=0;phone_close<=0;flush<=0;session_id<=0;link_state<=DOWN;renewed_ms<=0;
   management_done<=0;management_error<=0;opened_count<=0;closed_count<=0;expired_count<=0;rejected_count<=0;
  end else begin
   phone_open<=0;phone_close<=0;flush<=0;management_done<=0;
   if(link_state==OPENING&&phone_active)begin link_state<=READY;renewed_ms<=now_ms;end
   if(link_state==CLOSING&&phone_close_done)begin link_state<=DOWN;closed_count<=closed_count+1'b1;end
   if(lease_expired)begin
    phone_close<=1;flush<=1;link_state<=CLOSING;expired_count<=expired_count+1'b1;
   end
   if(management_valid&&management_ready)begin
    management_done<=1;management_error<=0;
    if(management_op==8'h80)begin end // status-only poll never renews lease
    else if(management_session[63:0]==0||management_session[127:64]==0)begin
     management_error<=-5;rejected_count<=rejected_count+1'b1;
    end else if(management_op==8'h90)begin
     if(link_state==DOWN&&phone_open_ready&&
        (management_session[63:0]!=session_id[63:0]||management_session[127:64]>session_id[127:64]))begin
      session_id<=management_session;phone_open<=1;flush<=1;link_state<=OPENING;
      opened_count<=opened_count+1'b1;
     end else if(management_session==session_id&&(link_state==READY||link_state==OPENING)&&!lease_expired)begin
      // Repeated OPEN acknowledges this same session, without touching ledger.
      renewed_ms<=now_ms;
     end else begin management_error<=-7;rejected_count<=rejected_count+1'b1;end
    end else if(management_session!=session_id)begin management_error<=-5;rejected_count<=rejected_count+1'b1;end
    else if(management_op==8'h91&&link_state==READY&&!lease_expired)renewed_ms<=now_ms;
    else if(management_op==8'h92&&(link_state==READY||link_state==OPENING))begin
     phone_close<=1;flush<=1;link_state<=CLOSING;
    end else if(management_op==8'h92&&(link_state==CLOSING||link_state==DOWN))begin end
    else begin management_error<=-10;rejected_count<=rejected_count+1'b1;end
   end
  end
 end
 // synthesis translate_off
 initial if(LEASE_MS<=0||LEASE_MS>=32'h80000000)$fatal(1,"S9_SESSION_LEASE_RANGE");
 always @(posedge clk)if(!rst)begin
  if((^{management_valid,phone_open_ready,phone_active,phone_close_done})===1'bx)$fatal(1,"S9_SESSION_CONTROL_XZ");
  if(management_valid&&(^({management_op,management_session}))===1'bx)$fatal(1,"S9_SESSION_PAYLOAD_XZ");
 end
 // synthesis translate_on
endmodule
