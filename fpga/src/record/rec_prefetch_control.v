// The production controller is also used by the independent clear/reset and
// faulty-response fixture. It never drives ready, write-enable or done.
module rec_prefetch_control #(parameter integer VARIABLE_RESPONSE=0)(
 input wire clk,rst,clear_valid,batch_accept,request_valid,
 input wire [1:0] request_owner,input wire [5:0] request_index,
 input wire response_pulse,input wire [1:0] response_owner,input wire [5:0] response_index,
 input wire [15:0] response_epoch,
 input wire consume_valid,input wire [1:0] consume_owner,input wire [5:0] consume_index,
 input wire [255:0] consume_cell,
 output wire [15:0] request_epoch,output reg [15:0] active_epoch
);
 reg cached_response_valid,request_due;
 reg [1:0] cached_owner,due_owner;
 reg [5:0] cached_index,due_index;
 reg [15:0] cached_epoch,due_epoch;
 assign request_epoch=batch_accept?active_epoch+16'd1:active_epoch;
 always @(posedge clk)begin
  if(rst)begin active_epoch<=0;cached_response_valid<=0;request_due<=0;
   cached_owner<=0;cached_index<=0;cached_epoch<=0;due_owner<=0;due_index<=0;due_epoch<=0;end
  else begin
   if(batch_accept)active_epoch<=active_epoch+1'b1;
   if(clear_valid)begin cached_response_valid<=0;request_due<=0;end
   else begin
    if(VARIABLE_RESPONSE)begin
     if(response_pulse)request_due<=0;
     if(request_valid)request_due<=1;
    end else request_due<=request_valid;
    if(request_valid)begin due_owner<=request_owner;due_index<=request_index;due_epoch<=request_epoch;end
    if(response_pulse)begin cached_response_valid<=1;cached_owner<=response_owner;cached_index<=response_index;cached_epoch<=response_epoch;end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&!clear_valid)begin
  if((VARIABLE_RESPONSE?response_pulse:request_due)&&(!response_pulse||!request_due||{response_owner,response_index,response_epoch}!=={due_owner,due_index,due_epoch}))
   $fatal(1,"PREFETCH_WRONG_OR_STALE_RESPONSE");
  if(consume_valid)begin
   if(response_pulse)begin
    if({response_owner,response_index,response_epoch}!=={consume_owner,consume_index,active_epoch})$fatal(1,"PREFETCH_CONSUMER_TAG");
   end else if(!cached_response_valid||{cached_owner,cached_index,cached_epoch}!=={consume_owner,consume_index,active_epoch})
    $fatal(1,"PREFETCH_CONSUMER_NOT_READY");
   if($isunknown(consume_cell))$fatal(1,"PREFETCH_CONSUMER_DATA_XZ");
  end
 end
 // synthesis translate_on
endmodule
