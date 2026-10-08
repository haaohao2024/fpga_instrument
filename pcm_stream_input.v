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
    function signed [63:0] rate_correction(input signed [63:0] e);
        reg [17:0] magnitude;
        reg [53:0] product;
        reg [22:0] quotient;
        begin
            // The original input is a 24-bit sum plus a 12-bit count minus
            // 2097152, so its multiplication by 2^36 never overflows int64.
            // Outside this interval the ORIGINAL result is already clamped.
            if(e>64'sd256000)rate_correction=64'sd4294967;
            else if(e< -64'sd256000)rate_correction=-64'sd4294967;
            else begin
                magnitude=e<0?-e:e;
                // Exhaustively exact for every magnitude 0..256000:
                // floor(m*2^18/15625)=floor(m*36028797019/2^31).
                product=magnitude*36'd36028797019;
                quotient=product[53:31];
                rate_correction=e<0?-$signed({41'd0,quotient}):$signed({41'd0,quotient});
            end
        end
    endfunction
    reg signed [31:0] last_l,last_r;
    reg [31:0] held_data;
    reg [63:0] held_epoch;
    reg stalled;
    reg [1:0] render_pipe;
    reg [11:0] window_count;
    reg [23:0] window_sum;
    wire command=ctrl_valid && ctrl_ready;
    wire start_ok=command && ctrl_cmd==0 && ctrl_rate==48000 && (!epoch_used || ctrl_epoch!=epoch);
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
                     && (pcm_epoch!=epoch || fifo_ready);
    wire accepted=pcm_valid && pcm_ready && pcm_epoch==epoch;
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
    integer j,nlook;
    reg [15:0] next_fade;
    reg signed [63:0] water_error,correction,target_rate,current_rate;
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
            water_error<=0;correction<=0;target_rate<=0;current_rate<=0;
            interpolated_l<=0;interpolated_r<=0;
        end else begin
            render_pipe<={render_pipe[0],sample_tick};sample_valid<=render_pipe[1];
            if(stalled && !command && (!pcm_valid || {pcm_l,pcm_r}!=held_data || pcm_epoch!=held_epoch))protocol_error<=1;
            stalled<=pcm_valid && !pcm_ready && !command;
            held_data<={pcm_l,pcm_r};held_epoch<=pcm_epoch;
            if(pcm_valid && !pcm_ready)backpressure_count<=backpressure_count+1;
            if(pcm_valid && pcm_ready)begin
                if(pcm_epoch!=epoch)stale_count<=stale_count+1;
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
                            // Q12 mean error -> Q32 rate correction; all
                            // arithmetic widened before products or shifts.
                            water_error=$signed({1'b0,window_sum})+$signed({1'b0,buffered})-64'sd2097152;
                            correction=rate_correction(water_error);
                            if(correction>4294967)correction=4294967;
                            if(correction< -4294967)correction=-4294967;
                            target_rate=64'sd4294967296+correction;
                            current_rate=$signed({1'b0,rate_q32});
                            if(target_rate>current_rate+274877)target_rate=current_rate+274877;
                            if(target_rate<current_rate-274877)target_rate=current_rate-274877;
                            rate_q32<=target_rate[32:0];window_sum<=0;window_count<=0;
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
endmodule
