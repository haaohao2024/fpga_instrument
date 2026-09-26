// Fall-through synchronous packet FIFO. Empty + ready transfers immediately.
// Captures only when needed, supports simultaneous full pop/push, no sample_tick.
module performance_event_queue #(
    parameter integer WIDTH=329, DEPTH=4,
    parameter integer PTR_W=(DEPTH<=2)?1:$clog2(DEPTH),
    parameter integer COUNT_W=$clog2(DEPTH+1)
) (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire [WIDTH-1:0] s_data,
    output wire m_valid,
    input wire m_ready,
    output wire [WIDTH-1:0] m_data,
    output reg [COUNT_W-1:0] occupancy
);
    reg [WIDTH-1:0] memory [0:DEPTH-1];
    reg [PTR_W-1:0] rd_ptr, wr_ptr;
    wire empty = occupancy==0;
    wire pop_stored = !empty && m_ready && !rst;
    wire push_stored = s_valid && s_ready && (!empty || !m_ready);
    assign s_ready = !rst && ((occupancy<DEPTH) || m_ready);
    assign m_valid = !rst && (!empty || s_valid);
    assign m_data = empty ? s_data : memory[rd_ptr];
    always @(posedge clk) begin
        if (rst) begin occupancy<=0; rd_ptr<=0; wr_ptr<=0; end
        else begin
            if (push_stored) begin
                memory[wr_ptr]<=s_data;
                wr_ptr <= (wr_ptr==DEPTH-1) ? 0 : wr_ptr+1'b1;
            end
            if (pop_stored) rd_ptr <= (rd_ptr==DEPTH-1) ? 0 : rd_ptr+1'b1;
            case ({push_stored,pop_stored})
                2'b10: occupancy<=occupancy+1'b1;
                2'b01: occupancy<=occupancy-1'b1;
                default: occupancy<=occupancy;
            endcase
        end
    end
    // synthesis translate_off
    initial if (DEPTH<2) $fatal(1,"Event FIFO DEPTH must be >=2");
    // synthesis translate_on
endmodule
