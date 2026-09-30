// Local Q8 + external PCM Q16 -> signed64 numerator, common L/R valid.
// Exactly seven clocks from input acceptance to out_valid. No backpressure.
module stereo_master_mixer #(
    parameter integer MIX_SHIFT=5
) (
    input wire clk,rst,in_valid,
    input wire signed [31:0] local_l,local_r,external_l,external_r,
    input wire [15:0] local_gain,external_gain,
    input wire [31:0] in_frame,
    output reg signed [63:0] out_l,out_r,
    output reg out_valid,
    output reg [31:0] out_frame,
    output reg protocol_error
);
    localparam integer SCALE=23+MIX_SHIFT;
    reg busy;reg [2:0] age;
    reg signed [31:0] ll,lr,el,er;
    reg [15:0] gl,ge;
    reg [31:0] tag;
    reg signed [48:0] mul_l,mul_r,local_product_l,local_product_r,external_product_l,external_product_r;
    reg signed [63:0] external_integer_l,external_integer_r,sum_l,sum_r;
    function signed [63:0] trunc_external;
        input signed [48:0] x;
        reg signed [63:0] wide;
        begin
            wide={{15{x[48]}},x};
            trunc_external=wide<0 ? -((-wide)>>>31) : (wide>>>31);
        end
    endfunction
    always @(posedge clk)begin
        if(rst)begin
            busy<=0;age<=0;ll<=0;lr<=0;el<=0;er<=0;gl<=0;ge<=0;tag<=0;
            mul_l<=0;mul_r<=0;local_product_l<=0;local_product_r<=0;
            external_product_l<=0;external_product_r<=0;external_integer_l<=0;external_integer_r<=0;
            sum_l<=0;sum_r<=0;out_l<=0;out_r<=0;out_valid<=0;out_frame<=0;protocol_error<=0;
        end else begin
            out_valid<=0;
            if(in_valid)begin
                if(busy || local_gain>32768 || external_gain>32768)protocol_error<=1;
                else begin
                    busy<=1;age<=0;ll<=local_l;lr<=local_r;el<=external_l;er<=external_r;
                    gl<=local_gain;ge<=external_gain;tag<=in_frame;
                end
            end
            if(busy)begin
                age<=age+1'b1;
                case(age)
                    0:begin mul_l<=ll*$signed({1'b0,gl});mul_r<=lr*$signed({1'b0,gl});end
                    1:begin
                        local_product_l<=mul_l;local_product_r<=mul_r;
                        mul_l<=el*$signed({1'b0,ge});mul_r<=er*$signed({1'b0,ge});
                    end
                    2:begin external_product_l<=mul_l;external_product_r<=mul_r;end
                    3:begin external_integer_l<=trunc_external(external_product_l);external_integer_r<=trunc_external(external_product_r);end
                    4:begin
                        sum_l<=$signed({{15{local_product_l[48]}},local_product_l})+(external_integer_l<<<SCALE);
                        sum_r<=$signed({{15{local_product_r[48]}},local_product_r})+(external_integer_r<<<SCALE);
                    end
                    6:begin out_l<=sum_l;out_r<=sum_r;out_frame<=tag;out_valid<=1;busy<=0;end
                    default:begin end
                endcase
            end
        end
    end
    // synthesis translate_off
    initial if(MIX_SHIFT<0 || MIX_SHIFT>23)$fatal(1,"Master MIX_SHIFT range");
    // synthesis translate_on
endmodule
