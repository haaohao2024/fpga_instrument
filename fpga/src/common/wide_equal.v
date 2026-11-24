// Full-width combinational equality. Each LUT4 compares exactly two bits;
// all bits participate. Equality and inequality consumers share one tree.
module wide_equal #(parameter integer WIDTH=32)(
 input wire [WIDTH-1:0] a,b,output wire equal);
 localparam integer PAIRS=(WIDTH+1)/2;
 wire [2*PAIRS-1:0] pa={{(2*PAIRS-WIDTH){1'b0}},a};
 wire [2*PAIRS-1:0] pb={{(2*PAIRS-WIDTH){1'b0}},b};
 wire [PAIRS-1:0] pairs;
 for(genvar g=0;g<PAIRS;g=g+1)begin: compare_pairs
  LUT4 #(.INIT(16'h9009)) eq_pair(.I0(pa[2*g]),.I1(pb[2*g]),.I2(pa[2*g+1]),.I3(pb[2*g+1]),.F(pairs[g]));
 end
 assign equal=&pairs;
endmodule
