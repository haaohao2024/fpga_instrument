// Two ready/valid packet sources, round-robin at accepted packet boundaries.
// Pure combinational forwarding: no clock or sample-frame wait when idle.
// A selected stalled source must hold valid/data until accepted (or reset).
// Stage 1 connects only source 0; source 1 remains disabled.
module performance_event_arbiter #(parameter integer WIDTH=329) (
    input wire clk, rst,
    input wire s0_valid, s1_valid,
    input wire [WIDTH-1:0] s0_data, s1_data,
    output wire s0_ready, s1_ready,
    output wire m_valid,
    output wire [WIDTH-1:0] m_data,
    input wire m_ready
);
    reg prefer_one, locked, locked_one;
    wire choose_one = locked ? locked_one : (s1_valid && (!s0_valid || prefer_one));
    assign m_valid = !rst && (choose_one ? s1_valid : s0_valid);
    assign m_data = choose_one ? s1_data : s0_data;
    assign s0_ready = !rst && !choose_one && m_ready;
    assign s1_ready = !rst && choose_one && m_ready;
    always @(posedge clk) begin
        if (rst) begin prefer_one<=0; locked<=0; locked_one<=0; end
        else if (m_valid && m_ready) begin prefer_one<=!choose_one; locked<=0; end
        else if (m_valid && !m_ready) begin locked<=1; locked_one<=choose_one; end
    end
endmodule
