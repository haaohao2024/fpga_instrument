// PT8211 V1.7 Japanese/LSBJ, exactly 16 bits/channel, right then left.
// WS=0: right; WS=1: left. Data changes on BCK falling edges.
// All state uses sys_clk; dac_bck is an output, never an internal clock.
module pt8211_serializer #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_000
) (
    input wire sys_clk,
    input wire rst_n, // synchronous, low-active
    input wire signed [15:0] frame_l,
    input wire signed [15:0] frame_r,
    output wire frame_load, // current clock will latch BOTH frame inputs
    output reg dac_bck,
    output reg dac_ws,
    output reg dac_din
);
    // 2 edges/bit * 16 bits/channel * 2 channels/frame.
    localparam [63:0] EDGE_RATE_HZ = 64'd64 * SAMPLE_RATE_HZ;
    function automatic [63:0] constant_gcd(input [63:0] a,b);
        reg [63:0] t;
        begin while(b!=0)begin t=a%b;a=b;b=t;end constant_gcd=a;end
    endfunction
    localparam [63:0] PHASE_UNIT=constant_gcd(CLK_FREQ_HZ,EDGE_RATE_HZ);
    localparam [63:0] PHASE_MOD=CLK_FREQ_HZ/PHASE_UNIT;
    localparam [63:0] PHASE_STEP=EDGE_RATE_HZ/PHASE_UNIT;
    localparam integer PHASE_WIDTH = (PHASE_MOD < 2) ? 1 : $clog2(PHASE_MOD);
    localparam [63:0] SAFE_EDGE_RATE = (EDGE_RATE_HZ < 1) ? 1 : EDGE_RATE_HZ;
    localparam [63:0] MIN_HALF_CYCLES = CLK_FREQ_HZ / SAFE_EDGE_RATE;
    localparam [63:0] SAFE_SAMPLE_RATE = (SAMPLE_RATE_HZ < 1) ? 1 : SAMPLE_RATE_HZ;
    localparam [63:0] MIN_FRAME_CYCLES = CLK_FREQ_HZ / SAFE_SAMPLE_RATE;

    reg [PHASE_WIDTH-1:0] phase;
    reg started;
    reg [3:0] bit_index;
    reg [15:0] shift_reg;
    reg [15:0] left_hold;
    reg edge_enable,frame_load_q;
    wire [PHASE_WIDTH-1:0] phase_next=edge_enable?phase+PHASE_STEP-PHASE_MOD:phase+PHASE_STEP;
    wire edge_next=(phase_next>=PHASE_MOD-PHASE_STEP);
    wire bck_next=edge_enable?~dac_bck:dac_bck;
    wire ws_next=edge_enable&&dac_bck&&bit_index==0?~dac_ws:dac_ws;
    wire [3:0] bit_next=edge_enable&&dac_bck?bit_index-1'b1:bit_index;
    // Startup loads while BCK is low. Thereafter load at the falling edge
    // following the left LSB, simultaneously starting the next right word.
    // Decode the NEXT state locally; this registered pulse describes the
    // same physical latch edge as before, not a delayed frame indication.
    assign frame_load = rst_n && frame_load_q;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            phase <= 0;
            edge_enable <= 0;
            frame_load_q <= 1;
            started <= 0;
            bit_index <= 15;
            shift_reg <= 0;
            left_hold <= 0;
            dac_bck <= 0;
            dac_ws <= 0;
            dac_din <= 0;
        end else if (!started) begin
            phase <= 0;
            edge_enable <= (0 >= PHASE_MOD-PHASE_STEP);
            frame_load_q <= 0;
            started <= 1;
            left_hold <= frame_l;
            shift_reg <= frame_r;
            bit_index <= 15;
            dac_ws <= 0;
            dac_din <= frame_r[15];
        end else begin
            // Constant arithmetic: no PLL, run-time division or generated
            // clock domain. Phase is retained across channel/frame boundaries.
            phase <= phase_next;
            edge_enable <= edge_next;
            frame_load_q <= edge_next && bck_next && ws_next && bit_next==0;

            if (edge_enable) begin
                dac_bck <= ~dac_bck;
                if (dac_bck) begin // falling edge, previous value was high
                    if (bit_index != 0) begin
                        bit_index <= bit_index - 1'b1;
                        shift_reg <= {shift_reg[14:0], 1'b0};
                        dac_din <= shift_reg[14];
                    end else begin
                        bit_index <= 15;
                        if (!dac_ws) begin
                            dac_ws <= 1;
                            shift_reg <= left_hold;
                            dac_din <= left_hold[15];
                        end else begin
                            dac_ws <= 0;
                            left_hold <= frame_l;
                            shift_reg <= frame_r;
                            dac_din <= frame_r[15];
                        end
                    end
                end
            end
        end
    end

    // Only checks configuration in simulation; no timing delays in RTL.
    // Use the timing table's 18.4 MHz limit, not the text's looser 20 MHz.
    // Check shortest quantized periods as well as requested average rates.
    // synthesis translate_off
    initial begin
        if (CLK_FREQ_HZ <= 0 || SAMPLE_RATE_HZ <= 0 || SAMPLE_RATE_HZ > 384000 ||
            EDGE_RATE_HZ > CLK_FREQ_HZ)
            $fatal(1, "Invalid PT8211 clock/sample-rate configuration");
        if (MIN_HALF_CYCLES * 64'd1000000000 < 64'd25 * CLK_FREQ_HZ)
            $fatal(1, "Shortest BCK high phase is less than PT8211 tH=25 ns");
        if (64'd36800000 * MIN_HALF_CYCLES < CLK_FREQ_HZ)
            $fatal(1, "Shortest BCK period exceeds PT8211 18.4 MHz limit");
        if (64'd384000 * MIN_FRAME_CYCLES < CLK_FREQ_HZ)
            $fatal(1, "Shortest WS period exceeds PT8211 384 kHz limit");
    end
    // synthesis translate_on
endmodule
