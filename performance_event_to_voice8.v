// Stage-1 fixed mapping: local source/key -> the same physical voice index.
// Pitch is mutable data, never the identity used to release a voice.
// Commit the entire batch on clk, independently of audio sample_tick.
// Parameter/configuration writes are NOT performance events in this protocol.
module performance_event_to_voice8 (
    input wire clk, rst, panic,
    input wire event_valid,
    input wire [328:0] event_packet,
    output wire event_ready,
    output reg [7:0] note_gate, note_trigger, vibrato_depth,
    output reg [63:0] pressure_value,
    output reg [55:0] note_code,
    output reg protocol_error
);
    localparam [55:0] BASE = {7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    integer i,j;
    reg bad;
    reg [8:0] seen;
    reg [31:0] item;
    assign event_ready = !rst;
    always @* begin
        bad = !(|event_packet[296:288]); seen=0; item=0;
        for (i=0; i<9; i=i+1) if (event_packet[288+i]) begin
            item=event_packet[i*32 +: 32];
            if (item[31:28]!=0 || item[0]) bad=1;
            if (item[27:24]>=1 && item[27:24]<=3 && item[23:16]<8) begin
                if (seen[item[23:16]]) bad=1;
                seen[item[23:16]]=1;
            end else if (item[27:24]==4 && item[23:16]==255 && item[15:9]==0) begin
                if (seen[8]) bad=1;
                seen[8]=1;
            end else bad=1;
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            note_gate<=0; note_trigger<=0; pressure_value<=0;
            note_code<=BASE; vibrato_depth<=0; protocol_error<=0;
        end else begin
            note_trigger<=0;
            if (panic || protocol_error || (event_valid && bad)) begin
                note_gate<=0;
                if (event_valid && bad) protocol_error<=1;
            end else if (event_valid) begin
                for (j=0; j<9; j=j+1) if (event_packet[288+j]) begin
                    if (event_packet[j*32+24 +: 4]==4)
                        vibrato_depth<=event_packet[j*32+1 +: 8];
                    else begin
                        note_code[event_packet[j*32+16 +: 8]*7 +: 7]<=event_packet[j*32+9 +: 7];
                        pressure_value[event_packet[j*32+16 +: 8]*8 +: 8]<=event_packet[j*32+1 +: 8];
                        case (event_packet[j*32+24 +: 4])
                            1: begin note_gate[event_packet[j*32+16 +: 8]]<=1; note_trigger[event_packet[j*32+16 +: 8]]<=1; end
                            2: note_gate[event_packet[j*32+16 +: 8]]<=0;
                            default: begin end
                        endcase
                    end
                end
            end
        end
    end
endmodule
