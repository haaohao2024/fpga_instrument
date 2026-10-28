// Q0.16 gain slews on every audio sample and reaches its target exactly.
// A new instance starts at its measured pressure; Release holds the last gain.
module pressure_gain_step (
    input wire new_owner,
    input wire release_hold,
    input wire [7:0] pressure,
    input wire [16:0] current_gain,
    output reg [16:0] gain_next
);
    wire [16:0] target_gain=(pressure==8'd255)?17'd65536:{1'b0,pressure,pressure};
    reg [16:0] difference,step;
    always @* begin
        difference=0;step=0;gain_next=current_gain;
        if (new_owner) gain_next=target_gain;
        else if (!release_hold && current_gain!=target_gain) begin
            difference=(target_gain>current_gain)?
                (target_gain-current_gain):(current_gain-target_gain);
            step=(difference+17'd3)>>2;
            if (step==0) step=1;
            if (target_gain>current_gain)
                gain_next=(step>=difference)?target_gain:current_gain+step;
            else
                gain_next=(step>=difference)?target_gain:current_gain-step;
        end
    end
endmodule
