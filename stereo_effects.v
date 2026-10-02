// Stage5 fixed-latency paired audio processor. The allocator/voices never wait.
// Output wet quantization follows the SAME MIX_SHIFT as the final PCM converter.
// Histories/feedback retain their fixed /8192 scale. Sum weighted returns before
// alignment; preserve full dry precision. Equal aligned wet preserves dry PCM
// differences only without saturation. Reassess if Master Mixer/gain changes.
module stereo_effects #(parameter integer MIX_SHIFT=5) (
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
    reg signed [17:0] input_l,input_r;
    reg signed [23:0] ma0,ma1;
    reg signed [17:0] mb0,mb1;
    wire signed [47:0] mq0,mq1;
    reg [13:0] d_old,d_new;
    reg [10:0] d_position;
    reg d_transition;
    reg signed [31:0] d_first[0:1],d_second[0:1],d_send[0:1],d_wet[0:1];
    reg signed [47:0] d_input_product[0:1],d_return[0:1];
    reg signed [17:0] d_write[0:1];
    wire signed [17:0] d_read_l,d_read_r;
    wire d_read_valid_l,d_read_valid_r;
    wire d_read_enable=busy && (cycle==5 || cycle==6);
    wire [14:0] d_lag=(cycle==5)?{1'b0,d_old}:{1'b0,d_new};
    wire d_write_enable=busy && cycle==16;
    reg [31:0] c_phase;
    reg [10:0] c_base_old,c_base_new;
    reg [8:0] c_depth_old,c_depth_new;
    reg [10:0] c_position;
    reg c_transition;
    reg [31:0] c_delay[0:3];
    reg signed [31:0] c_floor[0:3],c_ceil[0:3],c_interp[0:3];
    reg signed [31:0] c_send[0:1],c_wet[0:1];
    reg signed [47:0] c_return[0:1];
    wire signed [17:0] c_read_l,c_read_r;
    wire c_read_valid_l,c_read_valid_r;
    wire c_read_enable=busy && cycle>=33 && cycle<=36;
    wire [14:0] c_lag_l=(cycle<35 ? c_delay[0][30:16] : c_delay[2][30:16])+((cycle==34 || cycle==36)?15'd1:15'd0);
    wire [14:0] c_lag_r=(cycle<35 ? c_delay[1][30:16] : c_delay[3][30:16])+((cycle==34 || cycle==36)?15'd1:15'd0);
    reg signed [31:0] r_send[0:1],r_tap[0:3],r_h[0:3],r_b[0:3],r_wet[0:1];
    reg signed [17:0] r_write[0:3],r_tone[0:1];
    reg signed [47:0] r_tone_input[0:1],r_return[0:1];
    wire signed [17:0] r_read[0:3];
    wire [3:0] r_read_valid;
    reg [31:0] job_version;
    reg [31:0] input_saturations,history_saturations,output_saturations;
    reg signed [47:0] calc0,calc1;
    integer i;
    function signed [47:0] trunc0;
        input signed [47:0] x;
        input integer shift;
        begin trunc0=(x<0)?-((-x)>>>shift):(x>>>shift);end
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
    fx_mac_pair mac(.clk(clk),.rst(rst),.a0(ma0),.a1(ma1),.b0(mb0),.b1(mb1),.q0(mq0),.q1(mq1));
    fx_history18 #(.DEPTH(16384),.LENGTH(16384),.AW(14)) delay_l(
        .clk(clk),.rst(rst),.clear(clear_pulse[0]),.read_en(d_read_enable),.read_lag(d_lag),
        .read_data(d_read_l),.read_valid(d_read_valid_l),.write_en(d_write_enable),.write_data(d_write[0]));
    fx_history18 #(.DEPTH(16384),.LENGTH(16384),.AW(14)) delay_r(
        .clk(clk),.rst(rst),.clear(clear_pulse[0]),.read_en(d_read_enable),.read_lag(d_lag),
        .read_data(d_read_r),.read_valid(d_read_valid_r),.write_en(d_write_enable),.write_data(d_write[1]));
    fx_history18 #(.DEPTH(2048),.LENGTH(2048),.AW(11)) chorus_l(
        .clk(clk),.rst(rst),.clear(clear_pulse[1]),.read_en(c_read_enable),.read_lag(c_lag_l),
        .read_data(c_read_l),.read_valid(c_read_valid_l),.write_en(busy && cycle==45),.write_data(c_send[0][17:0]));
    fx_history18 #(.DEPTH(2048),.LENGTH(2048),.AW(11)) chorus_r(
        .clk(clk),.rst(rst),.clear(clear_pulse[1]),.read_en(c_read_enable),.read_lag(c_lag_r),
        .read_data(c_read_r),.read_valid(c_read_valid_r),.write_en(busy && cycle==45),.write_data(c_send[1][17:0]));
    genvar line;
    generate for(line=0;line<4;line=line+1)begin: reverb
        localparam integer N=(line==0)?1567:(line==1)?1789:(line==2)?1999:2137;
        localparam [14:0] LAG=N;
        fx_history18 #(.DEPTH(line==3?4096:2048),.LENGTH(N),.AW(line==3?12:11)) history(
            .clk(clk),.rst(rst),.clear(clear_pulse[2]),
            .read_en(busy && cycle==(line<2?55:56)),.read_lag(LAG),
            .read_data(r_read[line]),.read_valid(r_read_valid[line]),
            .write_en(busy && cycle==(line<2?68:69)),.write_data(r_write[line]));
    end endgenerate
    always @* begin
        ma0=0;ma1=0;mb0=0;mb1=0;
        if(busy)case(cycle)
            5:begin ma0=input_l;ma1=input_r;mb0=$signed(controls[31:0]);mb1=mb0;end
            9:begin ma0=d_second[0]-d_first[0];ma1=d_second[1]-d_first[1];
                mb0=d_transition?d_position:18'd1024;mb1=mb0;end
            12:begin ma0=d_send[0];ma1=d_send[1];mb0=32768-$signed(controls[223:192]);mb1=mb0;end
            13:begin ma0=d_wet[0];ma1=d_wet[1];mb0=$signed(controls[223:192]);mb1=mb0;end
            17:begin ma0=input_l;ma1=input_r;mb0=$signed(controls[63:32]);mb1=mb0;end
            18:begin ma0=input_l;ma1=input_r;mb0=$signed(controls[95:64]);mb1=mb0;end
            29,30:begin
                ma0=triangle(c_phase);ma1=triangle(c_phase+32'h40000000);
                mb0=(cycle==29)?{9'd0,c_depth_old}:{9'd0,c_depth_new};mb1=mb0;
            end
            37:begin
                ma0=c_ceil[0]-c_floor[0];ma1=c_ceil[1]-c_floor[1];
                mb0={2'b0,c_delay[0][15:0]};mb1={2'b0,c_delay[1][15:0]};
            end
            39:begin
                ma0=c_ceil[2]-c_floor[2];ma1=c_ceil[3]-c_floor[3];
                mb0={2'b0,c_delay[2][15:0]};mb1={2'b0,c_delay[3][15:0]};
            end
            42:begin
                ma0=c_interp[2]-c_interp[0];ma1=c_interp[3]-c_interp[1];
                mb0=c_transition?c_position:18'd1024;mb1=mb0;
            end
            62,63,64,65:begin
                ma0=r_b[cycle-62];ma1=r_h[cycle-62];
                mb0=32768-$signed(controls[255:224]);mb1=$signed(controls[255:224]);
            end
            86:begin ma0=r_wet[0];ma1=r_wet[1];mb0=32768-$signed(controls[287:256]);mb1=mb0;end
            87:begin ma0=r_tone[0];ma1=r_tone[1];mb0=$signed(controls[287:256]);mb1=mb0;end
            90:begin ma0=d_wet[0];ma1=d_wet[1];mb0=$signed(controls[127:96]);mb1=mb0;end
            91:begin ma0=c_wet[0];ma1=c_wet[1];mb0=$signed(controls[159:128]);mb1=mb0;end
            92:begin ma0=r_tone[0];ma1=r_tone[1];mb0=$signed(controls[191:160]);mb1=mb0;end
            default:begin end
        endcase
    end
    wire start=in_valid && !busy;
    fx_config_frame config_bank(.clk(clk),.rst(rst),.sample_tick(sample_tick),
        .cfg_valid(cfg_valid),.cfg_data(cfg_data),.frame_config(frame_config),
        .frame_clear(frame_clear),.frame_version(frame_version),
        .accepted_count(cfg_accepted),.rejected_count(cfg_rejected));
    fx_frame_control control(.clk(clk),.rst(rst),.start(start),
        .config_data(frame_config),.clear_request(frame_clear),.values(controls),
        .clear_pulse(clear_pulse),.effective_bypass(effective_bypass));
    always @(posedge clk)begin
        if(rst)begin
            busy<=0;cycle<=0;dry_l<=0;dry_r<=0;out_l_q8<=0;out_r_q8<=0;
            out_valid<=0;protocol_error<=0;frame_count<=0;
            result_l<=0;result_r<=0;input_l<=0;input_r<=0;
            d_old<=11520;d_new<=11520;d_position<=0;d_transition<=0;
            c_phase<=0;c_base_old<=576;c_base_new<=576;c_depth_old<=192;c_depth_new<=192;c_position<=0;c_transition<=0;
            job_version<=0;
            for(i=0;i<4;i=i+1)begin
                c_delay[i]<=0;c_floor[i]<=0;c_ceil[i]<=0;c_interp[i]<=0;
                r_tap[i]<=0;r_h[i]<=0;r_b[i]<=0;r_write[i]<=0;
            end
            input_saturations<=0;history_saturations<=0;output_saturations<=0;
            for(i=0;i<2;i=i+1)begin
                d_first[i]<=0;d_second[i]<=0;d_send[i]<=0;d_wet[i]<=0;
                d_input_product[i]<=0;d_return[i]<=0;d_write[i]<=0;
                c_send[i]<=0;c_wet[i]<=0;c_return[i]<=0;
                r_send[i]<=0;r_wet[i]<=0;r_tone[i]<=0;r_tone_input[i]<=0;r_return[i]<=0;
            end
        end else begin
            out_valid<=0;
            if(in_valid && busy)protocol_error<=1;
            if(sample_tick && busy)protocol_error<=1;
            if(start)begin busy<=1;cycle<=1;dry_l<=in_l_q8;dry_r<=in_r_q8;job_version<=frame_version;end
            else if(busy)begin
                cycle<=cycle+1'b1;
                case(cycle)
                    1:begin
                        if(clear_pulse[2])begin r_tone[0]<=0;r_tone[1]<=0;end
                        calc0=trunc0(dry_l,13);calc1=trunc0(dry_r,13);
                        input_l<=sat18(calc0);input_r<=sat18(calc1);
                        input_saturations<=input_saturations+(calc0>131071 || calc0< -131072)+(calc1>131071 || calc1< -131072);
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
                    7:begin
                        d_send[0]<=trunc0(mq0,15);d_send[1]<=trunc0(mq1,15);
                        d_first[0]<=d_read_l;d_first[1]<=d_read_r;
                        if(!d_read_valid_l || !d_read_valid_r)protocol_error<=1;
                    end
                    8:begin d_second[0]<=d_read_l;d_second[1]<=d_read_r;end
                    11:begin
                        d_wet[0]<=trunc0(($signed(d_first[0])*48'sd1024)+mq0,10);
                        d_wet[1]<=trunc0(($signed(d_first[1])*48'sd1024)+mq1,10);
                    end
                    14:begin d_input_product[0]<=mq0;d_input_product[1]<=mq1;end
                    15:begin
                        calc0=trunc0(d_input_product[0]+mq0,15);calc1=trunc0(d_input_product[1]+mq1,15);
                        d_write[0]<=sat18(calc0);d_write[1]<=sat18(calc1);
                        history_saturations<=history_saturations+(calc0>131071 || calc0< -131072)+(calc1>131071 || calc1< -131072);
                    end
                    19:begin c_send[0]<=trunc0(mq0,15);c_send[1]<=trunc0(mq1,15);end
                    20:begin r_send[0]<=trunc0(mq0,15);r_send[1]<=trunc0(mq1,15);end
                    31:begin c_delay[0]<=({21'd0,c_base_old}<<16)+mq0;c_delay[1]<=({21'd0,c_base_old}<<16)+mq1;end
                    32:begin c_delay[2]<=({21'd0,c_base_new}<<16)+mq0;c_delay[3]<=({21'd0,c_base_new}<<16)+mq1;end
                    35:begin
                        c_floor[0]<=c_read_l;c_floor[1]<=c_read_r;
                        if(!c_read_valid_l || !c_read_valid_r)protocol_error<=1;
                    end
                    36:begin c_ceil[0]<=c_read_l;c_ceil[1]<=c_read_r;end
                    37:begin c_floor[2]<=c_read_l;c_floor[3]<=c_read_r;end
                    38:begin c_ceil[2]<=c_read_l;c_ceil[3]<=c_read_r;end
                    39:begin
                        c_interp[0]<=trunc0($signed(c_floor[0])*48'sd65536+mq0,16);
                        c_interp[1]<=trunc0($signed(c_floor[1])*48'sd65536+mq1,16);
                    end
                    41:begin
                        c_interp[2]<=trunc0($signed(c_floor[2])*48'sd65536+mq0,16);
                        c_interp[3]<=trunc0($signed(c_floor[3])*48'sd65536+mq1,16);
                    end
                    44:begin
                        c_wet[0]<=trunc0($signed(c_interp[0])*48'sd1024+mq0,10);
                        c_wet[1]<=trunc0($signed(c_interp[1])*48'sd1024+mq1,10);
                    end
                    46:c_phase<=c_phase+controls[319:288];
                    57:begin r_tap[0]<=r_read[0];r_tap[1]<=r_read[1];if(r_read_valid[1:0]!=2'b11)protocol_error<=1;end
                    58:begin r_tap[2]<=r_read[2];r_tap[3]<=r_read[3];if(r_read_valid[3:2]!=2'b11)protocol_error<=1;end
                    60:begin
                        r_h[0]<=trunc0($signed(r_tap[0])+$signed(r_tap[1])+$signed(r_tap[2])+$signed(r_tap[3]),1);
                        r_h[1]<=trunc0($signed(r_tap[0])-$signed(r_tap[1])+$signed(r_tap[2])-$signed(r_tap[3]),1);
                        r_h[2]<=trunc0($signed(r_tap[0])+$signed(r_tap[1])-$signed(r_tap[2])-$signed(r_tap[3]),1);
                        r_h[3]<=trunc0($signed(r_tap[0])-$signed(r_tap[1])-$signed(r_tap[2])+$signed(r_tap[3]),1);
                        r_b[0]<=trunc0(r_send[0],1);r_b[1]<=trunc0(r_send[1],1);
                        r_b[2]<=trunc0(r_send[0],1);r_b[3]<=trunc0(-$signed(r_send[1]),1);
                        r_wet[0]<=trunc0($signed(r_tap[0])+$signed(r_tap[2]),1);
                        r_wet[1]<=trunc0($signed(r_tap[1])-$signed(r_tap[3]),1);
                    end
                    64,65,66,67:begin
                        calc0=trunc0(mq0+mq1,15);r_write[cycle-64]<=sat18(calc0);
                        history_saturations<=history_saturations+(calc0>131071 || calc0< -131072);
                    end
                    88:begin r_tone_input[0]<=mq0;r_tone_input[1]<=mq1;end
                    89:begin r_tone[0]<=sat18(trunc0(r_tone_input[0]+mq0,15));r_tone[1]<=sat18(trunc0(r_tone_input[1]+mq1,15));end
                    92:begin d_return[0]<=trunc0(mq0,2);d_return[1]<=trunc0(mq1,2);end
                    93:begin c_return[0]<=trunc0(mq0,2);c_return[1]<=trunc0(mq1,2);end
                    94:begin r_return[0]<=trunc0(mq0,2);r_return[1]<=trunc0(mq1,2);end
                    96:begin
                        // Keep the full signed48 sum; never quantize each effect separately.
                        calc0=d_return[0]+c_return[0]+r_return[0];calc1=d_return[1]+c_return[1]+r_return[1];
                        calc0=trunc0(calc0,8+MIX_SHIFT) <<< (8+MIX_SHIFT);
                        calc1=trunc0(calc1,8+MIX_SHIFT) <<< (8+MIX_SHIFT);
                        calc0=$signed(dry_l)+calc0;calc1=$signed(dry_r)+calc1;
                        result_l<=sat32(calc0);result_r<=sat32(calc1);
                        output_saturations<=output_saturations+(calc0>48'sd2147483647 || calc0< -48'sd2147483648)+(calc1>48'sd2147483647 || calc1< -48'sd2147483648);
                    end
                    default:begin end
                endcase
                if(cycle==128)begin
                    if(job_version!=frame_version)protocol_error<=1;
                    out_l_q8<=result_l;out_r_q8<=result_r;out_valid<=1;
                    frame_count<=frame_count+1'b1;busy<=0;
                end
            end
        end
    end
    // synthesis translate_off
    initial if(MIX_SHIFT<0 || MIX_SHIFT>23)$fatal(1,"Effects MIX_SHIFT must be 0..23");
    // synthesis translate_on
endmodule
