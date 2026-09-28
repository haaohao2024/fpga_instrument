// Configuration decoder for a second EC11's debounced step pulses.
module glide_parameter_control (
    input wire clk,rst,step_pulse,step_dir,
    output reg [3:0] glide_code
);
    always @(posedge clk) begin
        if (rst) glide_code<=0;
        else if (step_pulse) begin
            if (step_dir && glide_code<4'd11) glide_code<=glide_code+1'b1;
            else if (!step_dir && glide_code!=0) glide_code<=glide_code-1'b1;
        end
    end
endmodule
