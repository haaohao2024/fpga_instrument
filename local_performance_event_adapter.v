// Encode changes in the verified local controls. One atomic batch per clk:
// [328:297] sample timestamp, [296:288] lane mask, [287:0] nine 32-bit events.
// Event: source[31:28], kind[27:24], key[23:16], note[15:9], value[8:1], reserved[0].
// Kinds: 1 NOTE_ON, 2 NOTE_OFF, 3 KEY_EXPRESSION (pitch+pressure), 4 VIBRATO.
// Local source=0; key=pad 0..7, NOT pitch; global vibrato key=255.
// Physical inputs cannot stall. A rejected batch latches a fail-stop fault;
// the receiver then releases every gate until reset. Never silently lose OFF.
module local_performance_event_adapter (
    input wire clk, rst,
    input wire [31:0] sample_time,
    input wire [7:0] note_gate, note_trigger, vibrato_depth,
    input wire [63:0] pressure_value,
    input wire [55:0] note_code,
    output wire event_valid,
    input wire event_ready,
    output reg [328:0] event_packet,
    output reg overflow
);
    localparam [55:0] BASE = {7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    reg [7:0] previous_gate, previous_vibrato;
    reg [63:0] previous_pressure;
    reg [55:0] previous_notes;
    reg [3:0] kind;
    integer i;
    assign event_valid = (|event_packet[296:288]) && !overflow && !rst;
    always @* begin
        event_packet = 0;
        event_packet[328:297] = sample_time;
        kind = 0;
        for (i=0; i<8; i=i+1) begin
            kind = 0;
            if (note_trigger[i] || (note_gate[i] && !previous_gate[i])) kind=1;
            else if (!note_gate[i] && previous_gate[i]) kind=2;
            else if (pressure_value[i*8 +: 8] != previous_pressure[i*8 +: 8] ||
                     note_code[i*7 +: 7] != previous_notes[i*7 +: 7]) kind=3;
            event_packet[288+i] = (kind != 0);
            event_packet[i*32 +: 32] = {4'd0,kind,i[7:0],note_code[i*7 +: 7],pressure_value[i*8 +: 8],1'b0};
        end
        event_packet[296] = (vibrato_depth != previous_vibrato);
        event_packet[256 +: 32] = {4'd0,4'd4,8'hff,7'd0,vibrato_depth,1'b0};
    end
    always @(posedge clk) begin
        if (rst) begin
            previous_gate<=0; previous_vibrato<=0; previous_pressure<=0;
            previous_notes<=BASE; overflow<=0;
        end else begin
            previous_gate<=note_gate; previous_vibrato<=vibrato_depth;
            previous_pressure<=pressure_value; previous_notes<=note_code;
            if (event_valid && !event_ready) overflow<=1;
        end
    end
endmodule
