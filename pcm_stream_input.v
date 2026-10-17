// Stage6 synchronous PCM stream. All clocks/controls are in the 50MHz domain.
// cmd: 0 START, 1 STOP, 2 transport loss. START is a connection barrier.
// sample_tick alone advances playback. FIFO RAM transfers are not consumption.
module pcm_stream_input (
    input wire clk,rst,sample_tick,
    input wire ctrl_valid,
    output wire ctrl_ready,
    input wire [1:0] ctrl_cmd,
    input wire [63:0] ctrl_epoch,
    input wire [31:0] ctrl_rate,
    input wire ctrl_track,
    input wire pcm_valid,
    output wire pcm_ready,
    input wire signed [15:0] pcm_l,pcm_r,
    input wire [63:0] pcm_epoch,
    output reg signed [31:0] sample_l_q16,sample_r_q16,
    output reg [15:0] stream_gain,
    output reg sample_valid,
    output reg [31:0] sample_frame,
    output reg [63:0] sample_epoch,
    output reg [31:0] sample_generation,
    output reg [2:0] state,
    output wire [11:0] buffered,
    output wire [31:0] observe_generation,
    output reg [32:0] rate_q32,
    output reg [31:0] phase_q32,
    output reg [31:0] accepted_count,consumed_count,discard_count,
    output reg [31:0] stale_count,underflow_count,conceal_count,
    output reg [31:0] backpressure_count,rejected_control_count,
    output reg protocol_error
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;

    localparam STOPPED=0,PREFILL=1,PLAY=2,FADE=3,DRAIN=4;
    reg [63:0] epoch;
    reg epoch_used,track_mode,recover;
    reg [31:0] generation,frame_number;
    reg [31:0] look [0:3];
    reg [2:0] look_count;
    reg read_pending;
    wire [11:0] fifo_count;
    wire fifo_ready,read_ready,read_valid;
    wire [31:0] read_data;
    reg [15:0] fade_gain;
    reg [6:0] fade_remaining;
    // A 64-sample fade subtracts q+1 for the first r samples, then q,
    // where the starting gain is 64*q+r. This is exactly the original
    // repeated ceil(gain/remaining), including restarts of an active fade.
    reg [9:0] fade_decrement;
    reg [5:0] fade_extra;
    wire [15:0] fade_successor=fade_gain-{6'd0,fade_decrement}-(fade_extra!=0);
    wire [15:0] restarted_fade_gain=(sample_tick && state==FADE && fade_remaining!=0)?fade_successor:fade_gain;
    reg signed [31:0] last_l,last_r;
    reg [31:0] held_data;
    reg [63:0] held_epoch;
    reg stalled;
    reg [1:0] render_pipe;
    reg [11:0] window_count;
    reg [23:0] window_sum;
    wire command=ctrl_valid && ctrl_ready;
    wire start_ok=command && ctrl_cmd==0 && ctrl_rate==48000 && (!epoch_used || !r54_equal_0);
    wire stop_cmd=command && ctrl_cmd==1;
    wire loss_cmd=command && ctrl_cmd==2 && (state==PLAY || state==PREFILL);
    wire [33:0] phase_sum={2'b0,phase_q32}+{1'b0,rate_q32};
    wire [1:0] advance=track_mode ? phase_sum[33:32]:2'd1;
    wire missing=sample_tick && state==PLAY && look_count<(track_mode ? 2:1);
    wire flush=start_ok || stop_cmd || loss_cmd || missing;
    assign ctrl_ready=!rst && (ctrl_cmd!=0 || state==STOPPED);
    assign observe_generation=generation;
    assign buffered=fifo_count+look_count+read_pending;
    assign pcm_ready=!rst && !command && !missing && (state==PREFILL || state==PLAY)
                     && (!r54_equal_1 || fifo_ready);
    wire accepted=pcm_valid && pcm_ready && r54_equal_1;
    wire take_read=!rst && !flush && !sample_tick && !read_pending && look_count<4
                   && (state==PREFILL || state==PLAY) && read_ready;
    pcm_pair_fifo u_fifo(.clk(clk),.rst(rst),.clear(flush),
        .in_valid(accepted),.in_data({pcm_l,pcm_r}),.in_ready(fifo_ready),
        .pop(take_read),.pop_ready(read_ready),.out_valid(read_valid),
        .out_data(read_data),.occupancy(fifo_count));
    // synthesis translate_off
    always @(posedge clk)if(!rst && state==PLAY && fade_remaining!=0)
        if(fade_gain !== (64-fade_remaining)*512)$fatal(1,"PCM_PLAY_FADE_INVARIANT");
    // synthesis translate_on
    wire rate_request=sample_tick && state==PLAY && !missing &&
                      !stop_cmd && !loss_cmd && track_mode && window_count==4095;
    wire rate_result_valid;
    wire [32:0] rate_result;
    wire rate_busy;
    pcm_rate_window_pipeline rate_update(
        .clk(clk),.rst(rst),.cancel(flush || state!=PLAY),
        .request(rate_request),.window_sum(window_sum),.buffered(buffered),
        .current_rate(rate_q32),.busy(rate_busy),
        .result_valid(rate_result_valid),.result(rate_result));
    // The actual producer has >=1041 cycles between sample ticks. This
    // consumer requires nine: eight calculation edges, then the next tick.
    // Cancellation clears all in-flight ownership before a new stream.
    // synthesis translate_off
    always @(posedge clk)if(!rst && !flush && sample_tick && rate_busy)
        $fatal(1,"PCM_RATE_SAMPLE_DEADLINE");
    // synthesis translate_on
    integer j,nlook;
    reg [15:0] next_fade;

    reg signed [31:0] interpolated_l,interpolated_r;
    function signed [31:0] interpolate;
        input signed [15:0] a,b;
        input [15:0] fraction;
        reg signed [16:0] delta;
        reg signed [33:0] product;
        reg signed [34:0] sum;
        begin
            delta=$signed({b[15],b})-$signed({a[15],a});
            product=delta*$signed({1'b0,fraction});
            sum=$signed({{3{a[15]}},a,16'd0})+$signed({product[33],product});
            interpolate=sum[31:0];
        end
    endfunction
    always @(posedge clk)begin
        if(rst)begin
            state<=STOPPED;epoch<=0;epoch_used<=0;track_mode<=1;recover<=0;
            generation<=0;frame_number<=0;look_count<=0;read_pending<=0;
            fade_gain<=0;fade_remaining<=0;fade_decrement<=0;fade_extra<=0;last_l<=0;last_r<=0;
            sample_l_q16<=0;sample_r_q16<=0;stream_gain<=0;sample_valid<=0;
            sample_frame<=0;sample_epoch<=0;sample_generation<=0;render_pipe<=0;
            rate_q32<=33'h100000000;phase_q32<=0;window_count<=0;window_sum<=0;
            accepted_count<=0;consumed_count<=0;discard_count<=0;stale_count<=0;
            underflow_count<=0;conceal_count<=0;backpressure_count<=0;
            rejected_control_count<=0;protocol_error<=0;stalled<=0;held_data<=0;held_epoch<=0;
            for(j=0;j<4;j=j+1)look[j]<=0;

            interpolated_l<=0;interpolated_r<=0;
        end else begin
            if(rate_result_valid)rate_q32<=rate_result;
            render_pipe<={render_pipe[0],sample_tick};sample_valid<=render_pipe[1];
            if(stalled && !command && (!pcm_valid || {pcm_l,pcm_r}!=held_data || !r54_equal_2))protocol_error<=1;
            stalled<=pcm_valid && !pcm_ready && !command;
            held_data<={pcm_l,pcm_r};held_epoch<=pcm_epoch;
            if(pcm_valid && !pcm_ready)backpressure_count<=backpressure_count+1;
            if(pcm_valid && pcm_ready)begin
                if(!r54_equal_1)stale_count<=stale_count+1;
                else accepted_count<=accepted_count+1;
            end
            nlook=look_count;
            if(sample_tick)begin
                frame_number<=frame_number+1;sample_frame<=frame_number;
                sample_epoch<=epoch;sample_generation<=generation;
                sample_l_q16<=0;sample_r_q16<=0;stream_gain<=0;
                if(state==PREFILL && buffered>=512 && look_count>=2 && !command)begin
                    state<=PLAY;fade_gain<=0;fade_remaining<=64;
                    phase_q32<=0;rate_q32<=33'h100000000;window_sum<=0;window_count<=0;
                end
                if(state==PLAY && !missing && !stop_cmd && !loss_cmd)begin
                    interpolated_l=track_mode ? interpolate(look[0][31:16],look[1][31:16],phase_q32[31:16]):$signed({look[0][31:16],16'd0});
                    interpolated_r=track_mode ? interpolate(look[0][15:0],look[1][15:0],phase_q32[31:16]):$signed({look[0][15:0],16'd0});
                    sample_l_q16<=interpolated_l;sample_r_q16<=interpolated_r;
                    last_l<=interpolated_l;last_r<=interpolated_r;
                    next_fade=fade_gain;
                    if(fade_remaining!=0)begin
                        // PLAY starts at gain=0, remaining=64 and never
                        // restarts in PLAY: each exact original step is 512.
                        next_fade=fade_gain+16'd512;
                        fade_remaining<=fade_remaining-1'b1;
                    end
                    fade_gain<=next_fade;stream_gain<=next_fade;
                    consumed_count<=consumed_count+advance;nlook=look_count-advance;
                    for(j=0;j<4;j=j+1)if(j+advance<4)look[j]<=look[j+advance];
                    if(track_mode)begin
                        phase_q32<=phase_sum[31:0];
                        window_sum<=window_sum+buffered;window_count<=window_count+1'b1;
                        if(window_count==4095)begin
                            // Capture/compute below; deliver before the next PCM tick.
                            window_sum<=0;window_count<=0;
                        end
                    end
                end
                if(state==FADE)begin
                    next_fade=fade_gain;
                    if(fade_remaining!=0)begin
                        // Subtract ceiling so that the final endpoint is exact.
                        next_fade=fade_successor;
                        if(fade_extra!=0)fade_extra<=fade_extra-1'b1;
                        fade_remaining<=fade_remaining-1'b1;
                    end
                    fade_gain<=next_fade;stream_gain<=next_fade;
                    sample_l_q16<=last_l;sample_r_q16<=last_r;
                    conceal_count<=conceal_count+1;
                    if(fade_remaining==1)state<=DRAIN;
                end
                // One additional frame barrier lets the final zero reach DAC.
                if(state==DRAIN)begin state<=recover ? PREFILL:STOPPED;last_l<=0;last_r<=0;end
            end
            if(take_read)read_pending<=1;
            if(read_valid)begin
                if(!read_pending || nlook>=4)protocol_error<=1;
                else begin look[nlook]<=read_data;nlook=nlook+1;end
                read_pending<=0;
            end
            look_count<=nlook;
            if(command && ctrl_cmd==0 && !start_ok)rejected_control_count<=rejected_control_count+1;
            if(command && ctrl_cmd==3)rejected_control_count<=rejected_control_count+1;
            if(flush)begin
                discard_count<=discard_count+buffered;look_count<=0;read_pending<=0;
                generation<=generation+1;phase_q32<=0;rate_q32<=33'h100000000;
                window_count<=0;window_sum<=0;
                if(start_ok)begin
                    epoch<=ctrl_epoch;epoch_used<=1;track_mode<=ctrl_track;state<=PREFILL;
                    fade_gain<=0;fade_remaining<=0;fade_decrement<=0;fade_extra<=0;last_l<=0;last_r<=0;recover<=0;
                end else begin
                    state<=FADE;fade_remaining<=64;recover<=!stop_cmd;
                    // A same-edge FADE tick still updates fade_gain before
                    // restarting remaining, exactly as the original NBAs.
                    fade_decrement<=restarted_fade_gain[15:6];
                    fade_extra<=restarted_fade_gain[5:0];
                    if(loss_cmd || missing)underflow_count<=underflow_count+1;
                    // If flush meets a tick, this very frame holds the last
                    // sample at current gain. The following 64 frames fade.
                    if(sample_tick)begin sample_l_q16<=last_l;sample_r_q16<=last_r;stream_gain<=fade_gain;end
                end
            end
        end
    end
 r54_full_equal #(.WIDTH(64)) r54_equal_0_tree(.a(ctrl_epoch),.b(epoch),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(64)) r54_equal_1_tree(.a(pcm_epoch),.b(epoch),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(64)) r54_equal_2_tree(.a(pcm_epoch),.b(held_epoch),.equal(r54_equal_2));
endmodule

// One outstanding window, bounded eight-cycle computation. Independent
// oscillator state and the audio sample schedule are not modified.
module pcm_rate_window_pipeline(
    input wire clk,rst,cancel,request,
    input wire [23:0] window_sum,
    input wire [11:0] buffered,
    input wire [32:0] current_rate,
    output wire busy,result_valid,
    output reg [32:0] result
);
    reg [3:0] phase;
    reg [24:0] total;
    reg signed [25:0] error_value;
    reg [17:0] magnitude;
    reg negative,clamped;
    reg [44:0] product_low,product_high;
    reg [53:0] product;
    reg signed [23:0] correction;
    reg signed [33:0] target;
    reg [32:0] lower_rate,upper_rate,captured_rate;
    assign busy=phase!=0;
    assign result_valid=phase==8 && !rst && !cancel;
    always @(posedge clk)begin
        if(rst || cancel)begin
            phase<=0;total<=0;error_value<=0;magnitude<=0;
            negative<=0;clamped<=0;product_low<=0;product_high<=0;
            product<=0;correction<=0;target<=0;result<=0;
            lower_rate<=0;upper_rate<=0;captured_rate<=0;
        end else begin
            if(request)begin
                total<={1'b0,window_sum}+{13'd0,buffered};
                captured_rate<=current_rate;phase<=1;
            end else if(phase!=0)begin
                phase<=phase==8 ? 0:phase+1'b1;
                case(phase)
                    1:begin
                        error_value<=$signed({1'b0,total})-26'sd2097152;
                        lower_rate<=captured_rate-33'd274877;
                        upper_rate<=captured_rate+33'd274877;
                    end
                    2:begin
                        negative<=error_value<0;
                        clamped<=error_value>26'sd256000 || error_value< -26'sd256000;
                        magnitude<=error_value<0 ? -error_value:error_value;
                    end
                    3:begin
                        product_low<=magnitude[8:0]*36'd36028797019;
                        product_high<=magnitude[17:9]*36'd36028797019;
                    end
                    4:product<={9'd0,product_low}+{product_high,9'd0};
                    5:begin
                        if(clamped)correction<=negative ? -24'sd4294967:24'sd4294967;
                        else correction<=negative ? -$signed({1'b0,product[53:31]}):$signed({1'b0,product[53:31]});
                    end
                    6:target<=34'sd4294967296+{{10{correction[23]}},correction};
                    7:begin
                        if(target>$signed({1'b0,upper_rate}))result<=upper_rate;
                        else if(target<$signed({1'b0,lower_rate}))result<=lower_rate;
                        else result<=target[32:0];
                    end
                endcase
            end
        end
    end
    // Reference uses the original full-width division, not the reciprocal
    // or any DUT intermediate. Never synthesized into the formal datapath.
    // synthesis translate_off
    reg expected_valid;
    reg signed [63:0] ref_error,ref_correction,ref_target,ref_rate;
    reg [32:0] expected_result;
    always @(posedge clk)begin
        if(rst || cancel)begin expected_valid<=0;expected_result<=0;end
        else begin
            if(request)begin
                if(busy)$fatal(1,"PCM_RATE_OVERLAPPING_WINDOW");
                if(current_rate<33'd4290672329 || current_rate>33'd4299262263)
                    $fatal(1,"PCM_RATE_INPUT_RANGE");
                ref_error=$signed({1'b0,window_sum})+$signed({1'b0,buffered})-64'sd2097152;
                ref_correction=(ref_error*64'sd68719476736)/64'sd4096000000;
                if(ref_correction>4294967)ref_correction=4294967;
                if(ref_correction< -4294967)ref_correction=-4294967;
                ref_target=64'sd4294967296+ref_correction;
                ref_rate=$signed({1'b0,current_rate});
                if(ref_target>ref_rate+274877)ref_target=ref_rate+274877;
                if(ref_target<ref_rate-274877)ref_target=ref_rate-274877;
                expected_result<=ref_target[32:0];expected_valid<=1;
            end
            if(result_valid)begin
                if(!expected_valid || result!==expected_result)$fatal(1,"PCM_RATE_RESULT_IDENTITY");
                expected_valid<=0;
            end
        end
    end
    // synthesis translate_on
endmodule
