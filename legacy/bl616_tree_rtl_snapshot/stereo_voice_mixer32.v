// Four passive completion streams -> paired signed Q8 stereo mix.
// Only the original completion-edge accept is authoritative. Never recheck
// live Voice ownership after capturing this transaction.
module stereo_voice_mixer32 #(parameter integer COMPLETION_LIMIT=25) (
    input wire clk,rst,sample_tick,
    input wire [3:0] completion_valid,completion_accept,
    input wire [11:0] completion_slot,
    input wire [71:0] completion_sample,
    input wire [255:0] completion_id,
    input wire [63:0] completion_generation,
    input wire [287:0] snapshot_pan,
    input wire [2047:0] snapshot_ids,
    input wire [511:0] snapshot_generations,
    output reg signed [31:0] mix_l_q8,mix_r_q8,
    output reg mix_valid,
    output reg protocol_error,deadline_error,
    output reg [5:0] last_complete_cycle
);
    reg [3:0] v0,v1,v2,last0,last1,last2;
    reg signed [17:0] x0[0:3],x1[0:3];
    reg [8:0] pan0[0:3],coefficient[0:3];
    reg [3:0] right_unity;
    reg signed [27:0] product_l[0:3],product_r[0:3];
    reg signed [31:0] sum_l[0:3],sum_r[0:3];
    reg [3:0] sums_valid;
    reg signed [31:0] pair_l0,pair_l1,pair_r0,pair_r1;
    reg pair_valid,busy;
    reg [5:0] age;
    reg [7:0] seen[0:3];
    integer k;
    wire signed [27:0] variable_product[0:3],unity_product[0:3];
    genvar g;
    generate for(g=0;g<4;g=g+1)begin: multiply
        assign variable_product[g]=$signed(x1[g])*$signed({1'b0,coefficient[g]});
        assign unity_product[g]=$signed({{10{x1[g][17]}},x1[g]})<<<8;
    end endgenerate
    wire [63:0] selected_id[0:3];wire [15:0] selected_generation[0:3];
    wire [8:0] selected_pan[0:3];
    generate for(genvar l=0;l<4;l=l+1)begin: snapshot_lane
        wire [63:0] ids[0:7];wire [15:0] generations[0:7];wire [8:0] pans[0:7];
        for(genvar s=0;s<8;s=s+1)begin: snapshot_word
            assign ids[s]=snapshot_ids[(l*8+s)*64+:64];
            assign generations[s]=snapshot_generations[(l*8+s)*16+:16];
            assign pans[s]=snapshot_pan[(l*8+s)*9+:9];
        end
        wire [2:0] slot=completion_slot[l*3+:3];
        assign selected_id[l]=ids[slot];assign selected_generation[l]=generations[slot];
        assign selected_pan[l]=pans[slot];
    end endgenerate
    always @(posedge clk)begin
        if(rst)begin
            v0<=0;v1<=0;v2<=0;last0<=0;last1<=0;last2<=0;right_unity<=0;
            sums_valid<=0;pair_valid<=0;mix_valid<=0;mix_l_q8<=0;mix_r_q8<=0;
            protocol_error<=0;deadline_error<=0;last_complete_cycle<=0;age<=0;busy<=0;
            pair_l0<=0;pair_l1<=0;pair_r0<=0;pair_r1<=0;
            for(k=0;k<4;k=k+1)begin
                x0[k]<=0;x1[k]<=0;pan0[k]<=128;coefficient[k]<=256;
                product_l[k]<=0;product_r[k]<=0;sum_l[k]<=0;sum_r[k]<=0;seen[k]<=0;
            end
        end else begin
            v0<=completion_valid;v1<=v0;v2<=v1;last1<=last0;last2<=last1;
            sums_valid<=v2 & last2;pair_valid<=&sums_valid;mix_valid<=pair_valid;
            if(busy)begin age<=age+1'b1;if(age>=39)deadline_error<=1;end
            if(sample_tick)begin
                if(busy || |v0 || |v1 || |v2 || |completion_valid)deadline_error<=1;
                busy<=1;age<=0;
                for(k=0;k<4;k=k+1)begin sum_l[k]<=0;sum_r[k]<=0;seen[k]<=0;end
            end
            if(completion_valid!=0 && completion_valid!=4'b1111)protocol_error<=1;
            if(sums_valid!=0 && sums_valid!=4'b1111)protocol_error<=1;
            for(k=0;k<4;k=k+1)begin
                if(completion_valid[k])begin
                    if(!busy || seen[k][completion_slot[k*3 +:3]])protocol_error<=1;
                    seen[k][completion_slot[k*3 +:3]]<=1;
                    if(completion_slot[k*3 +:3]==7 && seen[k]!=8'h7f)protocol_error<=1;
                    if(completion_id[k*64 +:64]!=selected_id[k] ||
                       completion_generation[k*16 +:16]!=selected_generation[k] ||
                       selected_pan[k]>256)protocol_error<=1;
                    x0[k]<=completion_accept[k]?$signed(completion_sample[k*18 +:18]):18'sd0;
                    pan0[k]<=selected_pan[k];
                    last0[k]<=completion_slot[k*3 +:3]==7;
                end
                if(v0[k])begin
                    x1[k]<=x0[k];right_unity[k]<=pan0[k]>128;
                    coefficient[k]<=pan0[k]>128?((9'd256-pan0[k])<<1):(pan0[k]<<1);
                end
                if(v1[k])begin
                    product_l[k]<=right_unity[k]?variable_product[k]:unity_product[k];
                    product_r[k]<=right_unity[k]?unity_product[k]:variable_product[k];
                end
                if(v2[k])begin
                    sum_l[k]<=sum_l[k]+{{4{product_l[k][27]}},product_l[k]};
                    sum_r[k]<=sum_r[k]+{{4{product_r[k][27]}},product_r[k]};
                end
            end
            if(&sums_valid)begin
                pair_l0<=sum_l[0]+sum_l[1];pair_l1<=sum_l[2]+sum_l[3];
                pair_r0<=sum_r[0]+sum_r[1];pair_r1<=sum_r[2]+sum_r[3];
            end
            if(pair_valid)begin
                mix_l_q8<=pair_l0+pair_l1;mix_r_q8<=pair_r0+pair_r1;
                busy<=0;last_complete_cycle<=age+1'b1;
                if(!busy || age>=COMPLETION_LIMIT)deadline_error<=1;
            end
        end
    end
endmodule
