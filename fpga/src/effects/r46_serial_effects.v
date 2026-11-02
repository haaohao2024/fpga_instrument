

// Stage5 fixed-latency paired audio processor. The allocator/voices never wait.
// Output wet quantization follows the SAME MIX_SHIFT as the final PCM converter.
// Histories/feedback retain their fixed /8192 scale. Sum weighted returns before
// alignment; preserve full dry precision. Equal aligned wet preserves dry PCM
// differences only without saturation. Reassess if Master Mixer/gain changes.
// 30M/72k experiment: reverb schedule -6 cycles; output at 98 (was 128).
module r46_serial_effects #(parameter integer MIX_SHIFT=5, SCHEDULED_CONTROL=0, SHARED_MAC=0) (
    output wire fx_mac_use,output wire signed[35:0] fx_mac_a,output wire signed[17:0] fx_mac_b,
    input wire signed[53:0] fx_mac_q,
    input wire clk,rst,sample_tick,
    input wire signed [31:0] in_l_q8,in_r_q8,
    input wire in_valid,
    input wire cfg_valid,
    input wire [351:0] cfg_data,
    output reg signed [31:0] out_l_q8,out_r_q8,
    output reg out_valid,
    output reg protocol_error,
    output reg [31:0] frame_count,
    output wire [31:0] cfg_accepted,cfg_rejected,
    output wire effective_bypass,
    output wire [351:0] observe_config,
    output wire [31:0] observe_version
);
    wire [351:0] frame_config;
    wire [2:0] frame_clear,clear_pulse;
    wire [31:0] frame_version;
    assign observe_config=frame_config;
    assign observe_version=frame_version;
    wire [319:0] controls;
    reg busy;
    reg [7:0] cycle;
    reg signed [31:0] dry_l,dry_r;
    reg signed [31:0] result_l,result_r;
    
    wire signed [23:0] ma;reg signed[23:0] ma_left,ma_right;
    assign ma=ma_left-ma_right;

    reg signed [17:0] mb;
    wire signed [47:0] mq;
    reg [13:0] d_old,d_new;
    reg [10:0] d_position;
    reg d_transition;
    
    
    
    reg signed [17:0] d_write[0:1];
    wire signed [17:0] d_read_l,d_read_r;
    wire d_read_valid_l,d_read_valid_r;
    wire d_read_enable=busy && (cycle==5 || cycle==6);
    wire [14:0] d_lag=(cycle==5)?{1'b0,d_old}:{1'b0,d_new};
    wire d_write_enable=busy && cycle==22;
    reg [31:0] c_phase;
    wire [31:0] triangle_phase=c_phase+((cycle==26||cycle==28)?32'h40000000:32'd0);
    reg [10:0] c_base_old,c_base_new;
    reg [8:0] c_depth_old,c_depth_new;
    reg [10:0] c_position;
    reg c_transition;
    reg [31:0] c_delay[0:3];
    
    reg signed [17:0] c_send[0:1];
    
    wire signed [17:0] c_read_l,c_read_r;
    wire c_read_valid_l,c_read_valid_r;
    wire c_read_enable=busy && cycle>=33 && cycle<=36;
    wire [14:0] c_lag_l=(cycle<35 ? c_delay[0][30:16] : c_delay[2][30:16])+((cycle==34 || cycle==36)?15'd1:15'd0);
    wire [14:0] c_lag_r=(cycle<35 ? c_delay[1][30:16] : c_delay[3][30:16])+((cycle==34 || cycle==36)?15'd1:15'd0);
    
    
    reg signed [17:0] r_write[0:3],r_tone[0:1];
    
    
    wire signed [17:0] r_read[0:3];
    wire [3:0] r_read_valid;
    reg [31:0] job_version;
    reg [31:0] input_saturations,history_saturations,output_saturations;
    reg signed [47:0] calc0,calc1;
    integer i;

    // Fixed three-read, one-write operand store. Addresses and forwarding
    // follow a compile-time schedule; no dynamic arbitration or tag lookup.
    reg signed [35:0] operand_memory[0:63] /* synthesis syn_ramstyle="block_ram" */;
    reg [17:0] operand_addresses[0:129] /* synthesis syn_ramstyle="block_ram" */;
    reg [17:0] read_addresses;
    reg signed [18:0] pending0;
    reg signed [18:0] pending1;
    reg signed [17:0] pending2;
    reg signed [17:0] pending3;
    reg signed [35:0] ram_read0,forward_read0,forward_value0;
    reg forward_enable0,forward_held0;
    wire signed [35:0] rf_read0=forward_held0?forward_read0:ram_read0;
    reg signed [35:0] ram_read1,forward_read1,forward_value1;
    reg forward_enable1,forward_held1;
    wire signed [35:0] rf_read1=forward_held1?forward_read1:ram_read1;
    reg signed [35:0] ram_read2,forward_read2,forward_value2;
    reg forward_enable2,forward_held2;
    wire signed [35:0] rf_read2=forward_held2?forward_read2:ram_read2;
    initial begin
     for(integer n=0;n<130;n=n+1)operand_addresses[n]=0;
     operand_addresses[3]=18'h0001c;
     operand_addresses[4]=18'h0001d;
     operand_addresses[9]=18'h00590;
     operand_addresses[10]=18'h005d1;
     operand_addresses[12]=18'h00010;
     operand_addresses[13]=18'h00011;
     operand_addresses[14]=18'h00018;
     operand_addresses[15]=18'h00019;
     operand_addresses[16]=18'h0001a;
     operand_addresses[17]=18'h0001b;
     operand_addresses[18]=18'h0001c;
     operand_addresses[19]=18'h00752;
     operand_addresses[20]=18'h00713;
     operand_addresses[21]=18'h0001d;
     operand_addresses[37]=18'h00100;
     operand_addresses[38]=18'h00141;
     operand_addresses[39]=18'h00182;
     operand_addresses[40]=18'h07103;
     operand_addresses[41]=18'h00005;
     operand_addresses[42]=18'h00006;
     operand_addresses[43]=18'h00007;
     operand_addresses[44]=18'h00288;
     operand_addresses[45]=18'h002c9;
     operand_addresses[47]=18'h00008;
     operand_addresses[48]=18'h00009;
     operand_addresses[53]=18'h00c70;
     operand_addresses[54]=18'h00c70;
     operand_addresses[55]=18'h00cf2;
     operand_addresses[56]=18'h00cf2;
     operand_addresses[57]=18'h00aa8;
     operand_addresses[58]=18'h00ae9;
     operand_addresses[59]=18'h00aa8;
     operand_addresses[60]=18'h00ae9;
     operand_addresses[61]=18'h00cb0;
     operand_addresses[62]=18'h00cf1;
     operand_addresses[63]=18'h0002e;
     operand_addresses[64]=18'h00be0;
     operand_addresses[65]=18'h0002f;
     operand_addresses[66]=18'h00020;
     operand_addresses[67]=18'h00024;
     operand_addresses[68]=18'h00021;
     operand_addresses[69]=18'h00025;
     operand_addresses[70]=18'h00022;
     operand_addresses[71]=18'h00026;
     operand_addresses[72]=18'h00023;
     operand_addresses[73]=18'h00027;
     operand_addresses[79]=18'h00036;
     operand_addresses[80]=18'h00037;
     operand_addresses[83]=18'h0001a;
     operand_addresses[84]=18'h00d1b;
     operand_addresses[85]=18'h00d4e;
     operand_addresses[86]=18'h0000f;
     operand_addresses[92]=18'h0050c;
     operand_addresses[93]=18'h0054d;
     operand_addresses[94]=18'h00b1e;
     operand_addresses[95]=18'h00b5f;
     operand_addresses[96]=18'h0001e;
     operand_addresses[97]=18'h0001f;
    end
    function signed [47:0] trunc0;
        input signed [47:0] x;
        input integer shift;
        begin
          // Toward-zero division by 2^n: arithmetic shift plus one only
          // for a negative value with discarded nonzero bits. No abs/negate
          // chains, and the most-negative signed value remains correct.
          trunc0=(x>>>shift)+((x[47]&&((x&((48'd1<<shift)-1'b1))!=0))?48'sd1:48'sd0);
        end
    endfunction
    function signed [17:0] sat18;
        input signed [47:0] x;
        begin
            if(x>48'sd131071) sat18=18'sh1ffff;
            else if(x < -48'sd131072) sat18=-18'sd131071-18'sd1;
            else sat18=x[17:0];
        end
    endfunction
    function signed [31:0] sat32;
        input signed [47:0] x;
        begin
            if(x>48'sd2147483647) sat32=32'sh7fffffff;
            else if(x < -48'sd2147483648) sat32=32'sh80000000;
            else sat32=x[31:0];
        end
    endfunction
    function signed [23:0] triangle;
        input [31:0] phase;
        reg signed [31:0] t;
        begin
            t={14'd0,phase[31:14]};
            if(t<65536)triangle=t;
            else if(t<196608)triangle=131072-t;
            else triangle=t-262144;
        end
    endfunction
    assign fx_mac_use=busy;
    assign fx_mac_a=ma;assign fx_mac_b=mb;
    generate if(SHARED_MAC)begin: borrowed
      assign mq=fx_mac_q[47:0];
    end else begin: standalone
      reg signed[23:0] a;reg signed[17:0] b;reg signed[47:0] product,q;
      always @(posedge clk)begin
       if(rst)begin a<=0;b<=0;product<=0;q<=0;end
       else begin a<=ma;b<=mb;product<=a*b;q<=product;end
      end
      assign mq=q;
    end endgenerate
    fx_history18 #(.DEPTH(16384),.LENGTH(16384),.AW(14)) delay_l(
        .clk(clk),.rst(rst),.clear(clear_pulse[0]),.read_en(d_read_enable),.read_lag(d_lag),
        .read_data(d_read_l),.read_valid(d_read_valid_l),.write_en(d_write_enable),.write_data(d_write[0]));
    fx_history18 #(.DEPTH(16384),.LENGTH(16384),.AW(14)) delay_r(
        .clk(clk),.rst(rst),.clear(clear_pulse[0]),.read_en(d_read_enable),.read_lag(d_lag),
        .read_data(d_read_r),.read_valid(d_read_valid_r),.write_en(d_write_enable),.write_data(d_write[1]));
    fx_history18 #(.DEPTH(2048),.LENGTH(2048),.AW(11)) chorus_l(
        .clk(clk),.rst(rst),.clear(clear_pulse[1]),.read_en(c_read_enable),.read_lag(c_lag_l),
        .read_data(c_read_l),.read_valid(c_read_valid_l),.write_en(busy && cycle==49),.write_data(c_send[0][17:0]));
    fx_history18 #(.DEPTH(2048),.LENGTH(2048),.AW(11)) chorus_r(
        .clk(clk),.rst(rst),.clear(clear_pulse[1]),.read_en(c_read_enable),.read_lag(c_lag_r),
        .read_data(c_read_r),.read_valid(c_read_valid_r),.write_en(busy && cycle==49),.write_data(c_send[1][17:0]));
    wire [3:0] r_write_enable={ {2{busy && cycle==78}}, {2{busy && cycle==77}} };
    wire [3:0] r_read_enable={ {2{busy && cycle==50}}, {2{busy && cycle==49}} };
    r32_reverb_history history_bank(.clk(clk),.rst(rst),.clear(clear_pulse[2]),
      .read_en(r_read_enable),.write_en(r_write_enable),
      .write_data({r_write[3],r_write[2],r_write[1],r_write[0]}),
      .read_data({r_read[3],r_read[2],r_read[1],r_read[0]}),.read_valid(r_read_valid));

    wire start=in_valid && !busy;
    fx_config_frame config_bank(.clk(clk),.rst(rst),.sample_tick(sample_tick),
        .cfg_valid(cfg_valid),.cfg_data(cfg_data),.frame_config(frame_config),
        .frame_clear(frame_clear),.frame_version(frame_version),
        .accepted_count(cfg_accepted),.rejected_count(cfg_rejected));
    fx_frame_control #(.SCHEDULED_CONTROL(SCHEDULED_CONTROL)) control(.clk(clk),.rst(rst),.start(start),.sample_tick(sample_tick),
        .config_data(frame_config),.clear_request(frame_clear),.values(controls),
        .clear_pulse(clear_pulse),.effective_bypass(effective_bypass));

    
    reg signed[32:0] feedback_first;
    reg signed[35:0] post_a,post_b;reg post_sub;reg[4:0] post_shift;
    wire signed[35:0] post_sum=post_a+(post_b^{36{post_sub}})+post_sub;
    reg signed[35:0] post_scaled;reg discarded;
    always @*begin
     case(post_shift)
      0:begin post_scaled=post_sum;discarded=0;end
      1:begin post_scaled=post_sum>>>1;discarded=post_sum[0];end
      2:begin post_scaled=post_sum>>>2;discarded=|post_sum[1:0];end
      10:begin post_scaled=post_sum>>>10;discarded=|post_sum[9:0];end
      13:begin post_scaled=post_sum>>>13;discarded=|post_sum[12:0];end
      15:begin post_scaled=post_sum>>>15;discarded=|post_sum[14:0];end
      16:begin post_scaled=post_sum>>>16;discarded=|post_sum[15:0];end
      default:begin post_scaled=post_sum>>>(8+MIX_SHIFT);discarded=|post_sum[7+MIX_SHIFT:0];end
     endcase
    end
    wire signed[35:0] post_value=post_scaled+((post_sum[35]&&discarded)?36'sd1:36'sd0);
    // Saturation consumers have fixed shifts and known free destination
    // slots. Split add from round/saturate without moving output cycle98.
    reg signed[35:0] saturation_sum_q;
    wire signed[35:0] history_round=(saturation_sum_q>>>15)+
       ((saturation_sum_q[35]&&(|saturation_sum_q[14:0]))?36'sd1:36'sd0);
    wire signed[17:0] history_sat=sat18(history_round);
    wire signed[31:0] final_sat=sat32(saturation_sum_q);
    always @(posedge clk)begin
     if(rst)saturation_sum_q<=0;
     else if(busy)saturation_sum_q<=post_sum;
    end

    wire signed[17:0] post_sat=sat18(post_value);
    always @*begin
     ma_left=0;ma_right=0;mb=0;
     if(busy)case(cycle)
      3:begin ma_left=$signed(rf_read0);mb=$signed(controls[31:0]);end
      4:begin ma_left=$signed(rf_read0);mb=$signed(controls[31:0]);end
      9:begin ma_left=$signed(rf_read1);ma_right=$signed(rf_read0);mb=d_transition?d_position:18'd1024;end
      10:begin ma_left=$signed(rf_read1);ma_right=$signed(rf_read0);mb=d_transition?d_position:18'd1024;end
      14:begin ma_left=$signed(rf_read0);mb=32768-$signed(controls[223:192]);end
      15:begin ma_left=$signed(rf_read0);mb=32768-$signed(controls[223:192]);end
      16:begin ma_left=$signed(rf_read0);mb=$signed(controls[223:192]);end
      17:begin ma_left=$signed(rf_read0);mb=$signed(controls[223:192]);end
      18:begin ma_left=$signed(rf_read0);mb=$signed(controls[63:32]);end
      19:begin ma_left=$signed(rf_read1);mb=$signed(controls[63:32]);end
      20:begin ma_left=$signed(rf_read1);mb=$signed(controls[95:64]);end
      21:begin ma_left=$signed(rf_read0);mb=$signed(controls[95:64]);end
      25:begin ma_left=triangle(triangle_phase);mb={9'd0,c_depth_old};end
      26:begin ma_left=triangle(triangle_phase);mb={9'd0,c_depth_old};end
      27:begin ma_left=triangle(triangle_phase);mb={9'd0,c_depth_new};end
      28:begin ma_left=triangle(triangle_phase);mb={9'd0,c_depth_new};end
      37:begin ma_left=$signed(rf_read0);ma_right=$signed(rf_read1);mb={2'b0,c_delay[0][15:0]};end
      38:begin ma_left=$signed(rf_read0);ma_right=$signed(rf_read1);mb={2'b0,c_delay[1][15:0]};end
      39:begin ma_left=$signed(rf_read0);ma_right=$signed(rf_read1);mb={2'b0,c_delay[2][15:0]};end
      40:begin ma_left=$signed(rf_read0);ma_right=$signed(rf_read2);mb={2'b0,c_delay[3][15:0]};end
      44:begin ma_left=$signed(rf_read1);ma_right=$signed(rf_read0);mb=c_transition?c_position:18'd1024;end
      45:begin ma_left=$signed(rf_read1);ma_right=$signed(rf_read0);mb=c_transition?c_position:18'd1024;end
      66:begin ma_left=$signed(rf_read0);mb=18'sd32768;end
      67:begin ma_left=$signed(rf_read0);mb=$signed(controls[255:224]);end
      68:begin ma_left=$signed(rf_read0);mb=18'sd32768;end
      69:begin ma_left=$signed(rf_read0);mb=$signed(controls[255:224]);end
      70:begin ma_left=$signed(rf_read0);mb=18'sd32768;end
      71:begin ma_left=$signed(rf_read0);mb=$signed(controls[255:224]);end
      72:begin ma_left=$signed(rf_read0);mb=18'sd32768;end
      73:begin ma_left=$signed(rf_read0);mb=$signed(controls[255:224]);end
      79:begin ma_left=$signed(rf_read0);mb=32768-$signed(controls[287:256]);end
      80:begin ma_left=$signed(rf_read0);mb=32768-$signed(controls[287:256]);end
      81:begin ma_left=r_tone[0];mb=$signed(controls[287:256]);end
      82:begin ma_left=r_tone[1];mb=$signed(controls[287:256]);end
      83:begin ma_left=$signed(rf_read0);mb=$signed(controls[127:96]);end
      84:begin ma_left=$signed(rf_read0);mb=$signed(controls[127:96]);end
      85:begin ma_left=$signed(rf_read0);mb=$signed(controls[159:128]);end
      86:begin ma_left=$signed(rf_read0);mb=$signed(controls[159:128]);end
      87:begin ma_left=r_tone[0];mb=$signed(controls[191:160]);end
      88:begin ma_left=r_tone[1];mb=$signed(controls[191:160]);end
      default:begin end
     endcase
    end
    // Predecoded next micro-operation, registered alongside cycle. The
    // selected operands still come from the original cycle's RAM/DSP results.
    wire [7:0] next_cycle=start?8'd1:busy?cycle+8'd1:cycle;
    reg [3:0] post_a_select,post_b_select;
    reg [13:0] post_instruction;
    always @*begin
     post_instruction=0;
     case(next_cycle)
      1:post_instruction={4'd0,4'd1,5'(13),1'b0};
      2:post_instruction={4'd0,4'd2,5'(13),1'b0};
      6:post_instruction={4'd0,4'd3,5'(15),1'b0};
      7:post_instruction={4'd0,4'd3,5'(15),1'b0};
      12:post_instruction={4'd1,4'd3,5'(10),1'b0};
      13:post_instruction={4'd1,4'd3,5'(10),1'b0};
      19:post_instruction={4'd2,4'd3,5'(15),1'b0};
      20:post_instruction={4'd2,4'd3,5'(15),1'b0};
      21:post_instruction={4'd0,4'd3,5'(15),1'b0};
      22:post_instruction={4'd0,4'd3,5'(15),1'b0};
      23:post_instruction={4'd0,4'd3,5'(15),1'b0};
      24:post_instruction={4'd0,4'd3,5'(15),1'b0};
      28:post_instruction={4'd3,4'd3,5'(0),1'b0};
      29:post_instruction={4'd3,4'd3,5'(0),1'b0};
      30:post_instruction={4'd4,4'd3,5'(0),1'b0};
      31:post_instruction={4'd4,4'd3,5'(0),1'b0};
      40:post_instruction={4'd5,4'd3,5'(16),1'b0};
      41:post_instruction={4'd6,4'd3,5'(16),1'b0};
      42:post_instruction={4'd6,4'd3,5'(16),1'b0};
      43:post_instruction={4'd6,4'd3,5'(16),1'b0};
      47:post_instruction={4'd1,4'd3,5'(10),1'b0};
      48:post_instruction={4'd1,4'd3,5'(10),1'b0};
      50:post_instruction={4'd7,4'd4,5'(0),1'b0};
      53:post_instruction={4'd2,4'd5,5'(0),1'b0};
      54:post_instruction={4'd2,4'd5,5'(0),1'b1};
      55:post_instruction={4'd2,4'd5,5'(0),1'b0};
      56:post_instruction={4'd2,4'd5,5'(0),1'b1};
      57:post_instruction={4'd2,4'd5,5'(1),1'b0};
      58:post_instruction={4'd2,4'd5,5'(1),1'b0};
      59:post_instruction={4'd2,4'd5,5'(1),1'b1};
      60:post_instruction={4'd2,4'd5,5'(1),1'b1};
      61:post_instruction={4'd2,4'd5,5'(1),1'b0};
      62:post_instruction={4'd2,4'd5,5'(1),1'b1};
      63:post_instruction={4'd0,4'd6,5'(1),1'b0};
      64:post_instruction={4'd0,4'd5,5'(1),1'b0};
      65:post_instruction={4'd0,4'd6,5'(1),1'b1};
      70:post_instruction={4'd8,4'd3,5'(15),1'b0};
      72:post_instruction={4'd8,4'd3,5'(15),1'b0};
      74:post_instruction={4'd8,4'd3,5'(15),1'b0};
      76:post_instruction={4'd8,4'd3,5'(15),1'b0};
      84:post_instruction={4'd9,4'd3,5'(15),1'b0};
      85:post_instruction={4'd9,4'd3,5'(15),1'b0};
      86:post_instruction={4'd0,4'd3,5'(2),1'b0};
      87:post_instruction={4'd0,4'd3,5'(2),1'b0};
      88:post_instruction={4'd0,4'd3,5'(2),1'b0};
      89:post_instruction={4'd0,4'd3,5'(2),1'b0};
      90:post_instruction={4'd0,4'd3,5'(2),1'b0};
      91:post_instruction={4'd0,4'd3,5'(2),1'b0};
      92:post_instruction={4'd9,4'd6,5'(0),1'b0};
      93:post_instruction={4'd9,4'd6,5'(0),1'b0};
      94:post_instruction={4'd2,4'd5,5'(8+MIX_SHIFT),1'b0};
      95:post_instruction={4'd2,4'd5,5'(8+MIX_SHIFT),1'b0};
      96:post_instruction={4'd10,4'd6,5'(0),1'b0};
      97:post_instruction={4'd11,4'd6,5'(0),1'b0};
      default:begin end
     endcase
    end
    always @(posedge clk)begin
     if(rst)begin post_a_select<=0;post_b_select<=0;post_shift<=0;post_sub<=0;end
     else {post_a_select,post_b_select,post_shift,post_sub}<=post_instruction;
    end
    always @*begin
     post_a=0;post_b=0;
     case(post_a_select)
      0:post_a=0;
      1:post_a=$signed($signed(rf_read0))*48'sd1024;
      2:post_a=$signed(rf_read0);
      3:post_a=$signed({21'd0,c_base_old})*48'sd65536;
      4:post_a=$signed({21'd0,c_base_new})*48'sd65536;
      5:post_a=$signed($signed(rf_read1))*48'sd65536;
      6:post_a=$signed($signed(rf_read0))*48'sd65536;
      7:post_a=$signed({1'b0,c_phase});
      8:post_a=feedback_first;
      9:post_a=$signed(rf_read1);
      10:post_a=dry_l;
      11:post_a=dry_r;
     endcase
     case(post_b_select)
      0:post_b=0;
      1:post_b=dry_l;
      2:post_b=dry_r;
      3:post_b=mq;
      4:post_b=$signed({1'b0,controls[319:288]});
      5:post_b=$signed(rf_read1);
      6:post_b=$signed(rf_read0);
     endcase
    end

    always @(posedge clk)begin
     read_addresses<=operand_addresses[start?8'd2:busy&&cycle<128?cycle+8'd2:8'd0];
     ram_read0<=operand_memory[read_addresses[0+:6]];
     forward_held0<=!rst&&busy&&forward_enable0;
     forward_read0<=forward_value0;
     ram_read1<=operand_memory[read_addresses[6+:6]];
     forward_held1<=!rst&&busy&&forward_enable1;
     forward_read1<=forward_value1;
     ram_read2<=operand_memory[read_addresses[12+:6]];
     forward_held2<=!rst&&busy&&forward_enable2;
     forward_read2<=forward_value2;
    end
    always @*begin
     forward_enable0=0;forward_value0=0;
     case(cycle)
      9:begin forward_enable0=1;forward_value0=$signed(18'(pending0));end
      36:begin forward_enable0=1;forward_value0=$signed(18'(c_read_l));end
      37:begin forward_enable0=1;forward_value0=$signed(18'(pending1));end
      38:begin forward_enable0=1;forward_value0=$signed(18'(c_read_l));end
      39:begin forward_enable0=1;forward_value0=$signed(18'(pending3));end
      43:begin forward_enable0=1;forward_value0=$signed(18'(pending0));end
      44:begin forward_enable0=1;forward_value0=$signed(18'(pending1));end
      57:begin forward_enable0=1;forward_value0=$signed(19'(pending1));end
      63:begin forward_enable0=1;forward_value0=$signed(18'(post_value));end
      default:begin end
     endcase
    end
    always @*begin
     forward_enable1=0;forward_value1=0;
     case(cycle)
      8:begin forward_enable1=1;forward_value1=$signed(18'(d_read_l));end
      9:begin forward_enable1=1;forward_value1=$signed(18'(pending2));end
      37:begin forward_enable1=1;forward_value1=$signed(18'(pending0));end
      38:begin forward_enable1=1;forward_value1=$signed(18'(pending0));end
      43:begin forward_enable1=1;forward_value1=$signed(18'(pending2));end
      44:begin forward_enable1=1;forward_value1=$signed(18'(pending0));end
      52:begin forward_enable1=1;forward_value1=$signed(18'(pending0));end
      54:begin forward_enable1=1;forward_value1=$signed(18'(pending1));end
      56:begin forward_enable1=1;forward_value1=$signed(19'(pending0));end
      57:begin forward_enable1=1;forward_value1=$signed(19'(pending0));end
      default:begin end
     endcase
    end
    always @*begin
     forward_enable2=0;forward_value2=0;
     case(cycle)
      39:begin forward_enable2=1;forward_value2=$signed(18'(pending2));end
      default:begin end
     endcase
    end
    always @(posedge clk)if(!rst&&busy)begin
     case(cycle)
      7:begin
       pending0<=$signed(18'(d_read_r));
       pending1<=$signed(18'(post_value));
      end
      8:begin
       pending2<=$signed(18'(d_read_r));
      end
      35:begin
       pending0<=$signed(18'(c_read_r));
      end
      36:begin
       pending1<=$signed(18'(c_read_r));
      end
      37:begin
       pending0<=$signed(18'(c_read_l));
       pending2<=$signed(18'(c_read_r));
      end
      38:begin
       pending1<=$signed(18'(c_read_l));
       pending3<=$signed(18'(c_read_r));
      end
      40:begin
       pending0<=$signed(18'(post_value));
      end
      41:begin
       pending1<=$signed(18'(post_value));
      end
      42:begin
       pending2<=$signed(18'(post_value));
      end
      43:begin
       pending0<=$signed(18'(post_value));
      end
      51:begin
       pending0<=$signed(18'(r_read[1]));
      end
      52:begin
       pending0<=$signed(18'(r_read[2]));
       pending1<=$signed(18'(r_read[3]));
      end
      53:begin
       pending0<=$signed(19'(post_value));
      end
      54:begin
       pending1<=$signed(19'(post_value));
      end
      55:begin
       pending0<=$signed(19'(post_value));
      end
      56:begin
       pending0<=$signed(19'(post_value));
      end
      57:begin
       pending1<=$signed(19'(post_value));
      end
      58:begin
       pending0<=$signed(19'(post_value));
      end
      59:begin
       pending1<=$signed(19'(post_value));
      end
      60:begin
       pending0<=$signed(19'(post_value));
      end
      61:begin
       pending1<=$signed(18'(post_value));
      end
      62:begin
       pending0<=$signed(18'(post_value));
      end
      64:begin
       pending2<=$signed(18'($signed(rf_read0)));
      end
      65:begin
       pending2<=$signed(18'(post_value));
      end
      default:begin end
     endcase
    end
    reg [5:0] operand_write_address;reg signed[35:0] operand_write_data;reg operand_write_enable;
    reg [4:0] write_format;
    // Format1 is issued only for dry input conversion, cycles1/2.
    // Keep that conversion off the unrelated operand-RAM arithmetic path.
    wire signed [31:0] input_scale_raw=post_b_select==2?dry_r:dry_l;
    wire signed [18:0] input_scale=$signed(input_scale_raw[31:13])+
       ((input_scale_raw[31]&&(|input_scale_raw[12:0]))?19'sd1:19'sd0);
    wire [17:0] input_scale_sat=input_scale[18]==input_scale[17]?input_scale[17:0]:
       (input_scale[18]?18'h20000:18'h1ffff);
    // synthesis translate_off
    always @(posedge clk)if(!rst&&busy&&operand_write_enable&&write_format==1)begin
      if((cycle!=1&&cycle!=2)||input_scale_sat!==post_sat)$fatal(1,"FX_INPUT_SCALE_EQ");
    end
    // synthesis translate_on

    reg [11:0] next_write_control;
    always @*begin
     next_write_control=0;
     case(next_cycle)
      1:next_write_control={1'b1,6'd28,5'd1};
      2:next_write_control={1'b1,6'd29,5'd1};
      6:next_write_control={1'b1,6'd24,5'd2};
      7:next_write_control={1'b1,6'd16,5'd3};
      8:next_write_control={1'b1,6'd22,5'd3};
      9:next_write_control={1'b1,6'd17,5'd4};
      10:next_write_control={1'b1,6'd23,5'd5};
      11:next_write_control={1'b1,6'd25,5'd6};
      12:next_write_control={1'b1,6'd26,5'd2};
      13:next_write_control={1'b1,6'd27,5'd2};
      17:next_write_control={1'b1,6'd18,5'd7};
      18:next_write_control={1'b1,6'd19,5'd7};
      23:next_write_control={1'b1,6'd46,5'd2};
      24:next_write_control={1'b1,6'd47,5'd2};
      35:next_write_control={1'b1,6'd4,5'd8};
      36:next_write_control={1'b1,6'd0,5'd8};
      37:next_write_control={1'b1,6'd5,5'd4};
      38:next_write_control={1'b1,6'd1,5'd6};
      39:next_write_control={1'b1,6'd6,5'd4};
      40:next_write_control={1'b1,6'd2,5'd6};
      41:next_write_control={1'b1,6'd7,5'd5};
      42:next_write_control={1'b1,6'd3,5'd9};
      43:next_write_control={1'b1,6'd8,5'd4};
      44:next_write_control={1'b1,6'd10,5'd5};
      45:next_write_control={1'b1,6'd9,5'd6};
      46:next_write_control={1'b1,6'd11,5'd4};
      47:next_write_control={1'b1,6'd14,5'd2};
      48:next_write_control={1'b1,6'd15,5'd2};
      51:next_write_control={1'b1,6'd48,5'd10};
      52:next_write_control={1'b1,6'd49,5'd4};
      53:next_write_control={1'b1,6'd50,5'd4};
      54:next_write_control={1'b1,6'd51,5'd6};
      55:next_write_control={1'b1,6'd40,5'd11};
      56:next_write_control={1'b1,6'd42,5'd11};
      57:next_write_control={1'b1,6'd41,5'd12};
      58:next_write_control={1'b1,6'd43,5'd11};
      59:next_write_control={1'b1,6'd36,5'd12};
      60:next_write_control={1'b1,6'd37,5'd11};
      61:next_write_control={1'b1,6'd38,5'd12};
      62:next_write_control={1'b1,6'd39,5'd11};
      63:next_write_control={1'b1,6'd32,5'd2};
      64:next_write_control={1'b1,6'd33,5'd2};
      65:next_write_control={1'b1,6'd34,5'd5};
      66:next_write_control={1'b1,6'd35,5'd5};
      67:next_write_control={1'b1,6'd54,5'd6};
      68:next_write_control={1'b1,6'd55,5'd4};
      82:next_write_control={1'b1,6'd52,5'd7};
      83:next_write_control={1'b1,6'd53,5'd7};
      86:next_write_control={1'b1,6'd20,5'd13};
      87:next_write_control={1'b1,6'd21,5'd13};
      88:next_write_control={1'b1,6'd12,5'd13};
      89:next_write_control={1'b1,6'd13,5'd13};
      90:next_write_control={1'b1,6'd44,5'd13};
      91:next_write_control={1'b1,6'd45,5'd13};
      92:next_write_control={1'b1,6'd30,5'd14};
      93:next_write_control={1'b1,6'd31,5'd14};
      94:next_write_control={1'b1,6'd30,5'd15};
      95:next_write_control={1'b1,6'd31,5'd15};
      default:begin end
     endcase
    end
    always @(posedge clk)begin
     if(rst){operand_write_enable,operand_write_address,write_format}<=0;
     else {operand_write_enable,operand_write_address,write_format}<=next_write_control;
    end
    always @*begin
     operand_write_data=0;
     case(write_format)
      0:operand_write_data=0;
      1:operand_write_data=$signed(input_scale_sat);
      2:operand_write_data=$signed(18'(post_value));
      3:operand_write_data=$signed(18'(d_read_l));
      4:operand_write_data=$signed(18'(pending0));
      5:operand_write_data=$signed(18'(pending2));
      6:operand_write_data=$signed(18'(pending1));
      7:operand_write_data=$signed(33'(mq));
      8:operand_write_data=$signed(18'(c_read_l));
      9:operand_write_data=$signed(18'(pending3));
      10:operand_write_data=$signed(18'(r_read[0]));
      11:operand_write_data=$signed(19'(pending0));
      12:operand_write_data=$signed(19'(pending1));
      13:operand_write_data=$signed(33'(post_value));
      14:operand_write_data=$signed(36'(post_sum));
      15:operand_write_data=$signed(36'((post_value << (8+MIX_SHIFT))));
     endcase
    end
    always @(posedge clk)if(!rst&&busy&&operand_write_enable)operand_memory[operand_write_address]<=operand_write_data;
    // synthesis translate_off
    always @(posedge clk)if(!rst&&busy)begin
     if(cycle==19||cycle==20||cycle==70||cycle==72||cycle==74||cycle==76||cycle==84||cycle==85)
      if(post_shift!=15||post_sub)$fatal(1,"FX_FIXED_HISTORY_SHIFT");
     if(cycle==96||cycle==97||write_format==14)
      if(post_shift!=0||post_sub||post_value!==post_sum)$fatal(1,"FX_FIXED_FINAL_SHIFT");
    end
    // synthesis translate_on
    // synthesis translate_off
    wire signed [17:0] input_l;
    assign input_l=operand_memory[28][17:0];
    wire signed [17:0] input_r;
    assign input_r=operand_memory[29][17:0];
    wire signed [17:0] d_send[0:1];
    assign d_send[0]=operand_memory[24][17:0];
    assign d_send[1]=operand_memory[25][17:0];
    wire signed [17:0] d_first[0:1];
    assign d_first[0]=operand_memory[16][17:0];
    assign d_first[1]=operand_memory[17][17:0];
    wire signed [17:0] d_second[0:1];
    assign d_second[0]=operand_memory[22][17:0];
    assign d_second[1]=operand_memory[23][17:0];
    wire signed [17:0] d_wet[0:1];
    assign d_wet[0]=operand_memory[26][17:0];
    assign d_wet[1]=operand_memory[27][17:0];
    wire signed [32:0] d_input_product[0:1];
    assign d_input_product[0]=operand_memory[18][32:0];
    assign d_input_product[1]=operand_memory[19][32:0];
    wire signed [17:0] r_send[0:1];
    assign r_send[0]=operand_memory[46][17:0];
    assign r_send[1]=operand_memory[47][17:0];
    wire signed [17:0] c_floor[0:3];
    assign c_floor[0]=operand_memory[4][17:0];
    assign c_floor[1]=operand_memory[5][17:0];
    assign c_floor[2]=operand_memory[6][17:0];
    assign c_floor[3]=operand_memory[7][17:0];
    wire signed [17:0] c_ceil[0:3];
    assign c_ceil[0]=operand_memory[0][17:0];
    assign c_ceil[1]=operand_memory[1][17:0];
    assign c_ceil[2]=operand_memory[2][17:0];
    assign c_ceil[3]=operand_memory[3][17:0];
    wire signed [17:0] c_interp[0:3];
    assign c_interp[0]=operand_memory[8][17:0];
    assign c_interp[1]=operand_memory[9][17:0];
    assign c_interp[2]=operand_memory[10][17:0];
    assign c_interp[3]=operand_memory[11][17:0];
    wire signed [17:0] c_wet[0:1];
    assign c_wet[0]=operand_memory[14][17:0];
    assign c_wet[1]=operand_memory[15][17:0];
    wire signed [17:0] r_tap[0:3];
    assign r_tap[0]=operand_memory[48][17:0];
    assign r_tap[1]=operand_memory[49][17:0];
    assign r_tap[2]=operand_memory[50][17:0];
    assign r_tap[3]=operand_memory[51][17:0];
    wire signed [18:0] r_pair[0:3];
    assign r_pair[0]=operand_memory[40][18:0];
    assign r_pair[1]=operand_memory[41][18:0];
    assign r_pair[2]=operand_memory[42][18:0];
    assign r_pair[3]=operand_memory[43][18:0];
    wire signed [18:0] r_h[0:3];
    assign r_h[0]=operand_memory[36][18:0];
    assign r_h[1]=operand_memory[37][18:0];
    assign r_h[2]=operand_memory[38][18:0];
    assign r_h[3]=operand_memory[39][18:0];
    wire signed [17:0] r_wet[0:1];
    assign r_wet[0]=operand_memory[54][17:0];
    assign r_wet[1]=operand_memory[55][17:0];
    wire signed [17:0] r_b[0:3];
    assign r_b[0]=operand_memory[32][17:0];
    assign r_b[1]=operand_memory[33][17:0];
    assign r_b[2]=operand_memory[34][17:0];
    assign r_b[3]=operand_memory[35][17:0];
    wire signed [32:0] r_tone_input[0:1];
    assign r_tone_input[0]=operand_memory[52][32:0];
    assign r_tone_input[1]=operand_memory[53][32:0];
    wire signed [28:0] d_return[0:1];
    assign d_return[0]=operand_memory[20][28:0];
    assign d_return[1]=operand_memory[21][28:0];
    wire signed [28:0] c_return[0:1];
    assign c_return[0]=operand_memory[12][28:0];
    assign c_return[1]=operand_memory[13][28:0];
    wire signed [28:0] r_return[0:1];
    assign r_return[0]=operand_memory[44][28:0];
    assign r_return[1]=operand_memory[45][28:0];
    wire signed [35:0] mix_partial[0:1];
    assign mix_partial[0]=operand_memory[30][35:0];
    assign mix_partial[1]=operand_memory[31][35:0];
    // synthesis translate_on
    always @(posedge clk)begin
        if(rst)begin
            busy<=0;cycle<=0;dry_l<=0;dry_r<=0;out_l_q8<=0;out_r_q8<=0;
            out_valid<=0;protocol_error<=0;frame_count<=0;
            result_l<=0;result_r<=0;;;
            d_old<=11520;d_new<=11520;d_position<=0;d_transition<=0;
            c_phase<=0;c_base_old<=576;c_base_new<=576;c_depth_old<=192;c_depth_new<=192;c_position<=0;c_transition<=0;
            job_version<=0;
            for(i=0;i<4;i=i+1)begin
                c_delay[i]<=0;;;;
                ;;;r_write[i]<=0;
            end
            input_saturations<=0;history_saturations<=0;output_saturations<=0;
            for(i=0;i<2;i=i+1)begin
                ;;;;
                ;;d_write[i]<=0;
                c_send[i]<=0;;;
                ;;r_tone[i]<=0;;;
            end

            feedback_first<=0;
            for(integer j=0;j<4;j++);
            ;;
        end else begin
            out_valid<=0;
            if(in_valid&&busy)protocol_error<=1;
            if(sample_tick&&busy)protocol_error<=1;
            if(start)begin busy<=1;cycle<=1;dry_l<=in_l_q8;dry_r<=in_r_q8;job_version<=frame_version;end
            else if(busy)begin
             cycle<=cycle+1'b1;
             case(cycle)
              20:d_write[0]<=history_sat;
              21:d_write[1]<=history_sat;
              71:r_write[0]<=history_sat;
              73:r_write[1]<=history_sat;
              75:r_write[2]<=history_sat;
              77:r_write[3]<=history_sat;
              85:r_tone[0]<=history_sat;
              86:r_tone[1]<=history_sat;
              97:result_l<=final_sat;
              98:result_r<=final_sat;
              default:begin end
             endcase
             case(cycle)
              1:begin ; input_saturations<=input_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              2:begin ; input_saturations<=input_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              6:begin ; end
              7:begin ; end
              12:begin ; end
              13:begin ; end
              19:begin history_saturations<=history_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              20:begin history_saturations<=history_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              21:begin c_send[0]<=post_value; end
              22:begin c_send[1]<=post_value; end
              23:begin ; end
              24:begin ; end
              28:begin c_delay[0]<=post_value; end
              29:begin c_delay[1]<=post_value; end
              30:begin c_delay[2]<=post_value; end
              31:begin c_delay[3]<=post_value; end
              40:begin ; end
              41:begin ; end
              42:begin ; end
              43:begin ; end
              47:begin ; end
              48:begin ; end
              50:begin c_phase<=post_value; end
              53:begin ; end
              54:begin ; end
              55:begin ; end
              56:begin ; end
              57:begin ; end
              58:begin ; end
              59:begin ; end
              60:begin ; end
              61:begin ; end
              62:begin ; end
              63:begin ; end
              64:begin ; end
              65:begin ; end
              70:begin history_saturations<=history_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              72:begin history_saturations<=history_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              74:begin history_saturations<=history_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              76:begin history_saturations<=history_saturations+(post_value>48'sd131071||post_value< -48'sd131072); end
              84:begin end
              85:begin end
              86:begin ; end
              87:begin ; end
              88:begin ; end
              89:begin ; end
              90:begin ; end
              91:begin ; end
              92:begin ; end
              93:begin ; end
              94:begin ; end
              95:begin ; end
              96:begin output_saturations<=output_saturations+(post_value>48'sd2147483647||post_value< -48'sd2147483648); end
              97:begin output_saturations<=output_saturations+(post_value>48'sd2147483647||post_value< -48'sd2147483648); end
              default:begin end
             endcase
             case(cycle)
              20:d_write[0]<=history_sat;
              21:d_write[1]<=history_sat;
              71:r_write[0]<=history_sat;
              73:r_write[1]<=history_sat;
              75:r_write[2]<=history_sat;
              77:r_write[3]<=history_sat;
              85:r_tone[0]<=history_sat;
              86:r_tone[1]<=history_sat;
              97:result_l<=final_sat;
              98:result_r<=final_sat;
              default:begin end
             endcase
             case(cycle)
              1:begin
                if(clear_pulse[2])begin r_tone[0]<=0;r_tone[1]<=0;end
                        if(clear_pulse[0])begin
                            d_old<=frame_config[45:32];d_new<=frame_config[45:32];d_position<=0;d_transition<=0;
                        end else if(d_transition && d_position<1024)d_position<=d_position+1'b1;
                        else if(d_new!=frame_config[45:32])begin
                            d_old<=d_new;d_new<=frame_config[45:32];d_position<=1;d_transition<=1;
                        end else begin d_old<=d_new;d_position<=0;d_transition<=0;end
                        if(clear_pulse[1])begin
                            c_base_old<=frame_config[106:96];c_base_new<=frame_config[106:96];
                            c_depth_old<=frame_config[136:128];c_depth_new<=frame_config[136:128];c_position<=0;c_transition<=0;
                        end else if(c_transition && c_position<1024)c_position<=c_position+1'b1;
                        else if(c_base_new!=frame_config[106:96] || c_depth_new!=frame_config[136:128])begin
                            c_base_old<=c_base_new;c_depth_old<=c_depth_new;
                            c_base_new<=frame_config[106:96];c_depth_new<=frame_config[136:128];c_position<=1;c_transition<=1;
                        end else begin c_base_old<=c_base_new;c_depth_old<=c_depth_new;c_position<=0;c_transition<=0;end

              end
              7:begin ;;if(!d_read_valid_l||!d_read_valid_r)protocol_error<=1;end
              8:begin ;;end
              17:;
              18:;
              35:begin ;;if(!c_read_valid_l||!c_read_valid_r)protocol_error<=1;end
              36:begin ;;end
              37:begin ;;end
              38:begin ;;end
              51:begin ;;if(r_read_valid[1:0]!=2'b11)protocol_error<=1;end
              52:begin ;;if(r_read_valid[3:2]!=2'b11)protocol_error<=1;end
              64:;
              69,71,73,75:feedback_first<=mq;
              82:;
              83:;
              default:begin end
             endcase
             if(cycle==98)begin
              if(job_version!=frame_version)protocol_error<=1;
              out_l_q8<=result_l;out_r_q8<=final_sat;out_valid<=1;
              frame_count<=frame_count+1'b1;busy<=0;
             end
            end
        end
    end

 // synthesis translate_off
 reg signed[47:0] wide_check_a,wide_check_b;reg wide_check_sub;reg[4:0] wide_check_shift;
    always @*begin
     wide_check_a=0;wide_check_b=0;wide_check_sub=0;wide_check_shift=0;
     case(cycle)
      1:begin wide_check_a=0;wide_check_b=dry_l;wide_check_shift=13;wide_check_sub=0;end
      2:begin wide_check_a=0;wide_check_b=dry_r;wide_check_shift=13;wide_check_sub=0;end
      6:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      7:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      12:begin wide_check_a=$signed($signed(rf_read0))*48'sd1024;wide_check_b=mq;wide_check_shift=10;wide_check_sub=0;end
      13:begin wide_check_a=$signed($signed(rf_read0))*48'sd1024;wide_check_b=mq;wide_check_shift=10;wide_check_sub=0;end
      19:begin wide_check_a=$signed(rf_read0);wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      20:begin wide_check_a=$signed(rf_read0);wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      21:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      22:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      23:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      24:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      28:begin wide_check_a=$signed({21'd0,c_base_old})*48'sd65536;wide_check_b=mq;wide_check_shift=0;wide_check_sub=0;end
      29:begin wide_check_a=$signed({21'd0,c_base_old})*48'sd65536;wide_check_b=mq;wide_check_shift=0;wide_check_sub=0;end
      30:begin wide_check_a=$signed({21'd0,c_base_new})*48'sd65536;wide_check_b=mq;wide_check_shift=0;wide_check_sub=0;end
      31:begin wide_check_a=$signed({21'd0,c_base_new})*48'sd65536;wide_check_b=mq;wide_check_shift=0;wide_check_sub=0;end
      40:begin wide_check_a=$signed($signed(rf_read1))*48'sd65536;wide_check_b=mq;wide_check_shift=16;wide_check_sub=0;end
      41:begin wide_check_a=$signed($signed(rf_read0))*48'sd65536;wide_check_b=mq;wide_check_shift=16;wide_check_sub=0;end
      42:begin wide_check_a=$signed($signed(rf_read0))*48'sd65536;wide_check_b=mq;wide_check_shift=16;wide_check_sub=0;end
      43:begin wide_check_a=$signed($signed(rf_read0))*48'sd65536;wide_check_b=mq;wide_check_shift=16;wide_check_sub=0;end
      47:begin wide_check_a=$signed($signed(rf_read0))*48'sd1024;wide_check_b=mq;wide_check_shift=10;wide_check_sub=0;end
      48:begin wide_check_a=$signed($signed(rf_read0))*48'sd1024;wide_check_b=mq;wide_check_shift=10;wide_check_sub=0;end
      50:begin wide_check_a=$signed({1'b0,c_phase});wide_check_b=$signed({1'b0,controls[319:288]});wide_check_shift=0;wide_check_sub=0;end
      53:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=0;wide_check_sub=0;end
      54:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=0;wide_check_sub=1;end
      55:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=0;wide_check_sub=0;end
      56:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=0;wide_check_sub=1;end
      57:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=0;end
      58:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=0;end
      59:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=1;end
      60:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=1;end
      61:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=0;end
      62:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=1;end
      63:begin wide_check_a=0;wide_check_b=$signed(rf_read0);wide_check_shift=1;wide_check_sub=0;end
      64:begin wide_check_a=0;wide_check_b=$signed(rf_read1);wide_check_shift=1;wide_check_sub=0;end
      65:begin wide_check_a=0;wide_check_b=$signed(rf_read0);wide_check_shift=1;wide_check_sub=1;end
      70:begin wide_check_a=feedback_first;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      72:begin wide_check_a=feedback_first;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      74:begin wide_check_a=feedback_first;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      76:begin wide_check_a=feedback_first;wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      84:begin wide_check_a=$signed(rf_read1);wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      85:begin wide_check_a=$signed(rf_read1);wide_check_b=mq;wide_check_shift=15;wide_check_sub=0;end
      86:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=2;wide_check_sub=0;end
      87:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=2;wide_check_sub=0;end
      88:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=2;wide_check_sub=0;end
      89:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=2;wide_check_sub=0;end
      90:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=2;wide_check_sub=0;end
      91:begin wide_check_a=0;wide_check_b=mq;wide_check_shift=2;wide_check_sub=0;end
      92:begin wide_check_a=$signed(rf_read1);wide_check_b=$signed(rf_read0);wide_check_shift=0;wide_check_sub=0;end
      93:begin wide_check_a=$signed(rf_read1);wide_check_b=$signed(rf_read0);wide_check_shift=0;wide_check_sub=0;end
      94:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=8+MIX_SHIFT;wide_check_sub=0;end
      95:begin wide_check_a=$signed(rf_read0);wide_check_b=$signed(rf_read1);wide_check_shift=8+MIX_SHIFT;wide_check_sub=0;end
      96:begin wide_check_a=dry_l;wide_check_b=$signed(rf_read0);wide_check_shift=0;wide_check_sub=0;end
      97:begin wide_check_a=dry_r;wide_check_b=$signed(rf_read0);wide_check_shift=0;wide_check_sub=0;end
      default:begin end
     endcase
    end

 wire signed[47:0] wide_check_sum=wide_check_sub?wide_check_a-wide_check_b:wide_check_a+wide_check_b;
 always @(posedge clk)if(!rst&&busy)begin
  if(wide_check_a!==$signed(post_a)||wide_check_b!==$signed(post_b)||wide_check_sum!==$signed(post_sum))
   $fatal(1,"R46_FX_POST_WIDTH cycle=%0d a=%h b=%h sum=%h",cycle,wide_check_a,wide_check_b,wide_check_sum);
 end
 // synthesis translate_on
endmodule
