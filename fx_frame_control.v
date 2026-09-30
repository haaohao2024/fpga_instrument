// Per-sample exact linear ramps: 64 samples (rate:1024), no divider/MAC.
module fx_frame_control(
    input wire clk,rst,start,
    input wire [351:0] config_data,
    input wire [2:0] clear_request,
    output wire [319:0] values,
    output reg [2:0] clear_pulse,
    output wire effective_bypass
);
    // values: send D/C/R, wet D/C/R, feedbackD, feedbackR, lowpass, rate.
    reg signed [31:0] current[0:9],target[0:9],increment[0:9];
    reg [10:0] residue[0:9],error_acc[0:9],remaining[0:9];
    reg sign_down[0:9];
    reg [2:0] clearing;
    integer i,n,shift;
    reg signed [31:0] desired,delta,step_v,next_v;
    reg [31:0] magnitude;
    reg [11:0] err_v;
    reg down_v;
    genvar k;
    generate for(k=0;k<10;k=k+1)begin: outs
        assign values[k*32 +:32]=current[k];
    end endgenerate
    assign effective_bypass=(current[3]==0 && current[4]==0 && current[5]==0);
    always @(posedge clk) begin
        clear_pulse<=0;
        if(rst)begin
            clearing<=0;
            for(i=0;i<10;i=i+1)begin
                current[i]<=0;target[i]<=0;increment[i]<=0;residue[i]<=0;
                error_acc[i]<=0;remaining[i]<=0;sign_down[i]<=0;
            end
            current[6]<=12288;target[6]<=12288;
            current[7]<=24576;target[7]<=24576;
            current[8]<=16384;target[8]<=16384;
            current[9]<=71583;target[9]<=71583;
        end else if(start)begin
            for(i=0;i<3;i=i+1)begin
                if(clear_request[i])clearing[i]<=1;
                else if(clearing[i] && current[i]==0 && current[i+3]==0)begin
                    clear_pulse[i]<=1;clearing[i]<=0;
                end
            end
            for(i=0;i<10;i=i+1)begin
                n=(i==9)?1024:64;shift=(i==9)?10:6;
                if(i<3) desired=(!config_data[3] && config_data[i] && !clearing[i] && !clear_request[i])?32768:0;
                else if(i<6) desired=(!config_data[3] && !clearing[i-3] && !clear_request[i-3])?
                    config_data[(i+5)*32 +:32]:0;
                else case(i)
                    6:desired=config_data[95:64];
                    7:desired=config_data[223:192];
                    8:desired=config_data[255:224];
                    default:desired=config_data[191:160];
                endcase
                if(desired!=target[i])begin
                    delta=desired-current[i];down_v=(delta<0);
                    magnitude=down_v ? -delta : delta;
                    step_v=down_v ? -$signed(magnitude>>shift) : $signed(magnitude>>shift);
                    current[i]<=current[i]+step_v;
                    target[i]<=desired;increment[i]<=step_v;sign_down[i]<=down_v;
                    residue[i]<=magnitude&(n-1);error_acc[i]<=magnitude&(n-1);
                    remaining[i]<=n-1;
                end else if(remaining[i]!=0)begin
                    err_v=error_acc[i]+residue[i];
                    next_v=current[i]+increment[i];
                    if(err_v>=n)begin next_v=next_v+(sign_down[i]?-1:1);err_v=err_v-n;end
                    current[i]<=(remaining[i]==1)?target[i]:next_v;
                    remaining[i]<=remaining[i]-1'b1;error_acc[i]<=err_v;
                end
            end
        end
    end
endmodule
