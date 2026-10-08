// Per-instance pan configuration, independent of the performance event path.
module voice_pan_config #(
    // Formal Allocator guarantees identity changes are preceded by cancel on
    // the same publication edge. Generic users retain full-tag validation.
    parameter integer ALLOCATOR_OWNERSHIP=0
) (
    input wire clk,rst,sample_tick,
    input wire [31:0] slot_valid,slot_cancel,
    input wire [2047:0] slot_ids,
    input wire [511:0] slot_generations,
    input wire pan_valid,
    input wire [4:0] pan_slot,
    input wire [63:0] pan_id,
    input wire [15:0] pan_generation,
    input wire [8:0] pan_value,
    output reg [287:0] snapshot_pan,
    output reg [2047:0] snapshot_ids,
    output reg [511:0] snapshot_generations,
    output reg [31:0] accepted_count,stale_count,invalid_count,
    output wire [287:0] observe_current_pan
);
 function equal64(input [63:0] a,b);
  reg [31:0] matched /* synthesis syn_keep=1 */;integer k;
  begin
   for(k=0;k<32;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);
   equal64=&matched;
  end
 endfunction
 function equal16(input [15:0] a,b);
  reg [7:0] matched /* synthesis syn_keep=1 */;integer k;
  begin
   for(k=0;k<8;k=k+1)matched[k]=(a[k*2+:2]==b[k*2+:2]);
   equal16=&matched;
  end
 endfunction
    reg [31:0] owned;
    reg [8:0] value[0:31];

    wire [31:0] current;
    wire pan_accept=pan_valid && pan_value<=256 && slot_valid[pan_slot] && !slot_cancel[pan_slot] &&
        equal64(slot_ids[pan_slot*64+:64],pan_id) && equal16(slot_generations[pan_slot*16+:16],pan_generation);
    genvar g;
    generate for(g=0;g<32;g=g+1) begin: tags
        assign observe_current_pan[g*9+:9]=current[g]?value[g]:9'd128;
        if(ALLOCATOR_OWNERSHIP)begin: allocator_lifetime
            assign current[g]=owned[g] && slot_valid[g];
        end else begin: generic_identity
            reg [63:0] owner;
            reg [15:0] generation;
            assign current[g]=owned[g] && slot_valid[g] &&
                equal64(owner,slot_ids[g*64+:64]) && equal16(generation,slot_generations[g*16+:16]);
            always @(posedge clk)begin
                if(rst)begin owner<=0;generation<=0;end
                else if(pan_accept && pan_slot==g)begin owner<=pan_id;generation<=pan_generation;end
            end
        end
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            owned<=0;snapshot_pan<={32{9'd128}};snapshot_ids<=0;snapshot_generations<=0;
            accepted_count<=0;stale_count<=0;invalid_count<=0;
            for(i=0;i<32;i=i+1)begin value[i]<=128;end
        end else begin
            for(i=0;i<32;i=i+1)if(!current[i] || slot_cancel[i])owned[i]<=0;
            if(sample_tick) begin
                snapshot_ids<=slot_ids;snapshot_generations<=slot_generations;
                // Like Voice snapshot: pre-edge state, even on a publication edge.
                // Cancellation belongs to the frozen issue/writeback authority.
                for(i=0;i<32;i=i+1)snapshot_pan[i*9 +:9]<=current[i]?value[i]:9'd128;
            end
            if(pan_valid)begin
                if(pan_value>256)invalid_count<=invalid_count+1'b1;
                else if(!slot_valid[pan_slot] || slot_cancel[pan_slot] ||
                        !equal64(slot_ids[pan_slot*64 +:64],pan_id) ||
                        !equal16(slot_generations[pan_slot*16 +:16],pan_generation))
                    stale_count<=stale_count+1'b1;
                else begin
                    owned[pan_slot]<=1;value[pan_slot]<=pan_value;
                    accepted_count<=accepted_count+1'b1;
                end
            end
        end
    end
    // synthesis translate_off
    generate if(ALLOCATOR_OWNERSHIP)begin: producer_contract
        reg prior_reset=1;
        reg [2047:0] prior_ids;
        reg [511:0] prior_generations;
        reg [31:0] prior_cancel;
        always @(posedge clk)begin
            if(!rst && !prior_reset)begin
                for(integer c=0;c<32;c=c+1)
                    if({slot_ids[c*64+:64],slot_generations[c*16+:16]} !==
                       {prior_ids[c*64+:64],prior_generations[c*16+:16]} && !prior_cancel[c])
                        $fatal(1,"PAN_ALLOCATOR_IDENTITY_WITHOUT_CANCEL slot=%0d",c);
            end
            prior_reset<=rst;prior_ids<=slot_ids;
            prior_generations<=slot_generations;prior_cancel<=slot_cancel;
        end
    end endgenerate
    // synthesis translate_on
endmodule
