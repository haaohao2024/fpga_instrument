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

// Local release knob: 0=immediate, 1..7=1024..7168 samples at 48 kHz.
// The existing config/record transport retains its legacy glide_code name.
module release_parameter_control (
 input wire clk,rst,step_pulse,step_dir,
 output reg [3:0] glide_code
);
 always @(posedge clk)begin
  if(rst)glide_code<=4'd4;
  else if(step_pulse)begin
   if(step_dir&&glide_code<7)glide_code<=glide_code+1'b1;
   else if(!step_dir&&glide_code!=0)glide_code<=glide_code-1'b1;
  end
 end
endmodule
