// Legacy two-source output has priority at each free boundary. A stalled
// choice is immutable. Disabled phone input is an exact combinational bypass.
module s9_event_arbiter (
    input wire clk,rst,
    input wire legacy_valid,phone_valid,
    input wire [904:0] legacy_packet,phone_packet,
    output wire legacy_ready,phone_ready,
    output wire out_valid,
    output wire [904:0] out_packet,
    input wire out_ready
);
    reg locked,locked_phone;
    wire phone=locked?locked_phone:(!legacy_valid&&phone_valid);
    assign out_valid=!rst&&(phone?phone_valid:legacy_valid);
    assign out_packet=phone?phone_packet:legacy_packet;
    assign legacy_ready=!rst&&!phone&&out_ready;
    assign phone_ready=!rst&&phone&&out_ready;
    always @(posedge clk) begin
        if(rst)begin locked<=0;locked_phone<=0;end
        else if(out_valid&&out_ready)locked<=0;
        else if(out_valid)begin locked<=1;locked_phone<=phone;end
    end
    // synthesis translate_off
    always @(posedge clk)if(!rst)begin
        if((^{legacy_valid,phone_valid,out_ready})===1'bx)$fatal(1,"S9_ARBITER_CONTROL_XZ");
        if(legacy_valid&&(^legacy_packet)===1'bx)$fatal(1,"S9_ARBITER_LEGACY_XZ");
        if(phone_valid&&(^phone_packet)===1'bx)$fatal(1,"S9_ARBITER_PHONE_XZ");
    end
    // synthesis translate_on
endmodule
