// Local FSR/EC11 controls to atomic performance-event batches.
// Packet: timestamp[904:873], mask[872:864], nine 96-bit records.
// Record: press_token[95:32], stage-1 payload[31:0]. Token zero is invalid.
// Tokens belong to press gestures, not pitches or audio frames.
module local_performance_event_adapter (
    input wire clk, rst,
    input wire [31:0] sample_time,
    input wire [7:0] note_gate, note_trigger, vibrato_depth,
    input wire [63:0] pressure_value,
    input wire [55:0] note_code,
    output wire event_valid,
    input wire event_ready,
    output reg [904:0] event_packet,
    output reg overflow
);
    localparam [55:0] BASE = {7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    reg [7:0] previous_gate, previous_vibrato;
    reg [63:0] previous_pressure;
    reg [55:0] previous_notes;
    reg [63:0] token_counter;
    reg [63:0] key_token [0:7];
    reg [3:0] kind;
    reg [63:0] next_token;
    integer i;
    assign event_valid = (|event_packet[872:864]) && !overflow && !rst;
    always @* begin
        event_packet=0;
        event_packet[904:873]=sample_time;
        next_token=token_counter;
        kind=0;
        for (i=0;i<8;i=i+1) begin
            kind=0;
            if (note_trigger[i] || (note_gate[i] && !previous_gate[i])) kind=1;
            else if (!note_gate[i] && previous_gate[i]) kind=2;
            else if (note_gate[i] &&
                     (pressure_value[i*8 +: 8]!=previous_pressure[i*8 +: 8] ||
                      note_code[i*7 +: 7]!=previous_notes[i*7 +: 7])) kind=3;
            if (kind==1) begin
                next_token=next_token+1'b1;
                if (next_token==0) next_token=1;
            end
            event_packet[864+i]=(kind!=0);
            event_packet[i*96 +: 96]={((kind==1)?next_token:key_token[i]),
                4'd0,kind,i[7:0],note_code[i*7 +: 7],pressure_value[i*8 +: 8],1'b0};
        end
        event_packet[872]=(vibrato_depth!=previous_vibrato);
        event_packet[8*96 +: 96]={64'd0,4'd0,4'd4,8'hff,7'd0,vibrato_depth,1'b0};
    end
    always @(posedge clk) begin
        if (rst) begin
            previous_gate<=0;previous_vibrato<=0;previous_pressure<=0;
            previous_notes<=BASE;token_counter<=0;overflow<=0;
            for (i=0;i<8;i=i+1) key_token[i]<=0;
        end else begin
            previous_gate<=note_gate;previous_vibrato<=vibrato_depth;
            previous_pressure<=pressure_value;previous_notes<=note_code;
            if (event_valid && event_ready) begin
                token_counter<=next_token;
                for (i=0;i<8;i=i+1)
                    if (event_packet[864+i] && event_packet[i*96+24 +: 4]==1)
                        key_token[i]<=event_packet[i*96+32 +: 64];
            end
            if (event_valid && !event_ready) overflow<=1;
        end
    end
endmodule
