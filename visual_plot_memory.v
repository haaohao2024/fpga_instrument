// No reset of RAM contents. Ownership/validity hides old banks. Two-cycle pixel
// reads; write-side read is only used for XY RMW on the exclusively owned back.
module visual_plot_memory #(parameter integer ADDRESS_BITS=11)(
 input wire process_clk,write_enable,input wire [ADDRESS_BITS-1:0] write_address,
 input wire [15:0] write_data,
 input wire [ADDRESS_BITS-1:0] process_read_address,output reg [15:0] process_read_data,
 input wire pixel_clk,read_enable,input wire [ADDRESS_BITS-1:0] read_address,
 output reg [15:0] read_data
);
 reg [15:0] memory[0:(1<<ADDRESS_BITS)-1];
 reg [15:0] read_stage;
 always @(posedge process_clk)begin
  if(write_enable)memory[write_address]<=write_data;
  process_read_data<=memory[process_read_address];
 end
 always @(posedge pixel_clk)begin
  if(read_enable)read_stage<=memory[read_address];
  read_data<=read_stage;
 end
endmodule
