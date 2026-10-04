// Passive configuration journal. Initial values are cloned on START; later
// records describe real parameter state changes and actual engine edges.
// Fourteen cells include the immutable in-flight prefix: appending does not
// change a transaction already reserved by the EVR RAM writer.
module s11_config_observer(
 input wire clk,rst,start,stop,recording,capture_fault,
 input wire [63:0] frame_id,input wire [15:0] subcycle,
 input wire [2:0] timbre_id,input wire [3:0] glide_code,
 input wire [55:0] keymap,input wire [31:0] keymap_version,
 input wire [351:0] fx_config,input wire [31:0] fx_version,
 input wire gain_cfg_valid,input wire [15:0] gain_local,gain_external,
 input wire gain_local_mute,gain_external_mute,
 input wire [31:0] gain_accepted,gain_frame,gain_version,
 input wire gain_sample,input wire [15:0] gain_current_l,gain_current_e,
 input wire [6:0] gain_remaining,input wire [103:0] gain_state,
 input wire pan_valid,input wire [4:0] pan_slot,input wire [63:0] pan_id,
 input wire [15:0] pan_generation,input wire [8:0] pan_value,
 input wire [31:0] slot_valid,slot_cancel,
 input wire [2047:0] slot_ids,mapped_runtime_ids,mapped_persistent_ids,
 input wire [511:0] slot_generations,mapped_generations,
 input wire [2:0] stream_state,input wire [31:0] stream_generation,
 input wire [63:0] media_epoch,
 output wire tx_valid,output reg [5:0] tx_count,output reg [10239:0] tx_cells,
 input wire tx_ready,tx_done,
 output reg fault_valid,output reg [63:0] first_missing_frame,
 output wire [7:0] fault_code,output wire idle
);
 localparam TIMBRE=14,GLIDE=15,PAN=16,EFFECTS=17,GAIN=18,KEYMAP=19,MEDIA=20,EXT=21;
 reg [255:0] cells[0:13];reg [3:0] head,tail;
 reg [4:0] used,locked_count;reg inflight;reg [1:0] selected;
 reg [1:0] initial_phase;
 reg [811:0] initial_state;reg [63:0] initial_frame;reg [15:0] initial_subcycle;
 reg [2:0] previous_timbre;reg [3:0] previous_glide;
 reg [31:0] previous_keymap_version,previous_fx_version,previous_gain_accepted,previous_gain_version;
 reg [6:0] previous_remaining;reg [2:0] previous_stream_state;
 reg [31:0] previous_stream_generation;reg [63:0] previous_media_epoch;
 reg [63:0] previous_frame;reg [15:0] previous_subcycle;
 reg [15:0] user_l,user_e;reg [1:0] user_mute;
 wire [811:0] live_state={media_epoch,stream_generation,stream_state,gain_frame,gain_accepted,
  gain_state,gain_current_e,gain_current_l,user_mute,user_e,user_l,
  fx_version,fx_config,keymap_version,keymap,glide_code,timbre_id};
 assign idle=!inflight&&initial_phase==0&&used==0;
 assign fault_code=8'd2;
 assign tx_valid=!fault_valid&&!capture_fault&&!inflight&&(initial_phase!=0||used!=0);
 function [255:0] make_cell;
  input [7:0] typ,flags;input [63:0] frame,note,payload;
  begin make_cell={payload,note,frame,32'd0,8'hff,8'hff,flags,typ};end
 endfunction
 function [3:0] addptr;
  input [3:0] p;input integer n;integer v;
  begin v=p+n;if(v>=14)v=v-14;addptr=v;end
 endfunction
 // Identify only data that the fault will actually retire.  The immutable
 // in-flight prefix still commits; a current-edge handshake is protected too.
 function [63:0] first_unaccepted_frame;
  input [63:0] fallback;integer protected_cells;
  begin
   if(initial_phase==1 || (initial_phase==2 && !(inflight&&selected==2) &&
       !(tx_valid&&tx_ready)))first_unaccepted_frame=initial_frame;
   else begin
    protected_cells=(inflight&&selected==3)?locked_count:
      (tx_valid&&tx_ready&&initial_phase==0)?used:0;
    if(used>protected_cells)
     first_unaccepted_frame=cells[addptr(head,protected_cells)][127:64];
    else first_unaccepted_frame=fallback;
   end
  end
 endfunction
 // Snapshot layout, low to high: timbre3,glide4,keymap56,keyversion32,
 // FX352,FXversion32,usergain34,currentgain32,gainstate104,accepted32,
 // gainframe32,streamstate3,streamgeneration32,mediaepoch64.
 function [255:0] snapshot_cell;
  input integer which;input [811:0] s;input [63:0] fr;input [15:0] sc;
  reg [63:0] p;reg [7:0] typ;reg [3:0] phase;
  begin
   p=0;typ=EXT;phase=4;
   case(which)
    0:begin typ=TIMBRE;p={45'd0,s[2:0],sc};end
    1:begin typ=GLIDE;p={44'd0,s[6:3],sc};end
    2:begin typ=KEYMAP;p={8'd0,s[62:7]};end
    3:p={16'd0,s[94:63],sc};
    4:begin typ=GAIN;p={2'd0,phase,s[648],s[647:641],s[512:511],s[510:495],s[494:479],sc};end
    5:p={s[576:561],s[560:545],s[544:529],s[528:513]};
    6:p={s[680:649],s[640:609]};
    7:p={s[712:681],32'd0};
    8:begin typ=EFFECTS;p=s[158:95];end
    9:p=s[222:159];
    10:p=s[286:223];
    11:p=s[350:287];
    12:p=s[414:351];
    13:p={s[478:447],s[446:415]};
    14:begin typ=MEDIA;p={13'd0,s[747:716],s[715:713],sc};end
    15:p=s[811:748];
   endcase
   snapshot_cell=make_cell(typ,8'd2,fr,0,p);
  end
 endfunction
 integer k,index,count;reg [3583:0] additions;
 reg [255:0] c;reg [63:0] pan_pid;
 reg [3:0] gain_phase;
 always @(*)begin
  tx_cells=0;tx_count=0;
  if((inflight&&selected==1)||(!inflight&&initial_phase==1))begin
   tx_count=14;
   for(integer q=0;q<14;q=q+1)tx_cells[q*256+:256]=snapshot_cell(q,initial_state,initial_frame,initial_subcycle);
   tx_cells[13*256+8+:8]=8'd3;
  end else if((inflight&&selected==2)||(!inflight&&initial_phase==2))begin
   tx_count=2;tx_cells[255:0]=snapshot_cell(14,initial_state,initial_frame,initial_subcycle);
   tx_cells[511:256]=snapshot_cell(15,initial_state,initial_frame,initial_subcycle);tx_cells[264+:8]=8'd3;
  end else begin
   tx_count=inflight?locked_count:used;
   for(integer q=0;q<14;q=q+1)begin
    index=head+q;if(index>=14)index=index-14;
    tx_cells[q*256+:256]=cells[index];
   end
  end
 end
 task append;
  input [255:0] x;
  begin if(count<14)additions[count*256+:256]=x;count=count+1;end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   head<=0;tail<=0;used<=0;locked_count<=0;inflight<=0;selected<=0;initial_phase<=0;
   initial_state<=0;initial_frame<=0;initial_subcycle<=0;fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;
   previous_timbre<=0;previous_glide<=0;previous_keymap_version<=0;previous_fx_version<=0;
   previous_gain_accepted<=0;previous_gain_version<=0;previous_remaining<=0;
   previous_stream_state<=0;previous_stream_generation<=0;previous_media_epoch<=0;
   previous_frame<=0;previous_subcycle<=0;user_l<=32768;user_e<=32768;user_mute<=0;
   for(k=0;k<14;k=k+1)cells[k]<=0;
  end else begin
   previous_timbre<=timbre_id;previous_glide<=glide_code;
   previous_keymap_version<=keymap_version;previous_fx_version<=fx_version;
   previous_gain_accepted<=gain_accepted;previous_gain_version<=gain_version;previous_remaining<=gain_remaining;
   previous_stream_state<=stream_state;previous_stream_generation<=stream_generation;previous_media_epoch<=media_epoch;
   previous_frame<=frame_id;previous_subcycle<=subcycle;
   if(gain_cfg_valid&&gain_local<=32768&&gain_external<=32768)begin
    user_l<=gain_local;user_e<=gain_external;user_mute<={gain_external_mute,gain_local_mute};
   end
   if(tx_valid&&tx_ready)begin
    inflight<=1;selected<=initial_phase==1?1:initial_phase==2?2:3;
    locked_count<=initial_phase==0?used:0;
   end
   if(tx_done&&inflight)begin
    inflight<=0;
    if(selected==1)initial_phase<=2;
    else if(selected==2)initial_phase<=0;
    else begin head<=addptr(head,locked_count);used<=used-locked_count;end
   end
   additions=0;count=0;
   // These differences became visible after the PREVIOUS edge's real commit.
   // A STOP now excludes new same-edge operations, not that already executed
   // prefix.  At the next edge recording is false, so STOP-edge changes are
   // still outside the record.  Direct Pan below retains its same-edge rule.
   if(recording&&!fault_valid&&!capture_fault&&!start)begin
    if(timbre_id!=previous_timbre)append(make_cell(TIMBRE,0,previous_frame,0,{45'd0,timbre_id,previous_subcycle}));
    if(glide_code!=previous_glide)append(make_cell(GLIDE,0,previous_frame,0,{44'd0,glide_code,previous_subcycle}));
    if(keymap_version!=previous_keymap_version)begin
     append(make_cell(KEYMAP,0,previous_frame,0,{8'd0,keymap}));
     append(make_cell(EXT,0,previous_frame,0,{16'd0,keymap_version,previous_subcycle}));
    end
    if(fx_version!=previous_fx_version)begin
     append(make_cell(EFFECTS,0,previous_frame,0,fx_config[63:0]));
     for(k=1;k<5;k=k+1)append(make_cell(EXT,0,previous_frame,0,fx_config[k*64+:64]));
     append(make_cell(EXT,0,previous_frame,0,{fx_version,fx_config[351:320]}));
    end
    gain_phase=gain_accepted!=previous_gain_accepted?1:gain_version!=previous_gain_version?2:3;
    if(gain_accepted!=previous_gain_accepted||gain_version!=previous_gain_version||
       (previous_remaining!=0&&gain_remaining==0))begin
     append(make_cell(GAIN,0,previous_frame,0,{2'd0,gain_phase,gain_state[103],gain_remaining,user_mute,user_e,user_l,previous_subcycle}));
     append(make_cell(EXT,0,previous_frame,0,{gain_state[31:0],gain_current_e,gain_current_l}));
     append(make_cell(EXT,0,previous_frame,0,{gain_accepted,gain_version}));
     append(make_cell(EXT,0,previous_frame,0,{gain_frame,32'd0}));
    end
    if(stream_state!=previous_stream_state||stream_generation!=previous_stream_generation||media_epoch!=previous_media_epoch)begin
     append(make_cell(MEDIA,0,previous_frame,0,{13'd0,stream_generation,stream_state,previous_subcycle}));
     append(make_cell(EXT,0,previous_frame,0,media_epoch));
    end
   end
   // This condition is the exact unchanged voice_pan_config accept rule.
   // Same-edge START changes follow the cloned initial state.
   if((recording||start)&&!stop&&(!fault_valid||start)&&(!capture_fault||start)&&pan_valid&&pan_value<=256&&slot_valid[pan_slot]&&
      !slot_cancel[pan_slot]&&slot_ids[pan_slot*64+:64]==pan_id&&slot_generations[pan_slot*16+:16]==pan_generation)begin
    // START creates a new file identity map from the continuation snapshot.
    // A matching runtime ID in the retired file is not its new persistent ID.
    pan_pid=start?pan_slot+64'd1:
     (mapped_runtime_ids[pan_slot*64+:64]==pan_id&&mapped_generations[pan_slot*16+:16]==pan_generation)?mapped_persistent_ids[pan_slot*64+:64]:64'd0;
    append(make_cell(PAN,0,frame_id,pan_pid,{pan_slot,pan_generation,pan_value,18'd0,subcycle}));
    append(make_cell(EXT,0,frame_id,pan_pid,pan_id));
   end
   if(count!=0)begin
    if(count>14||used-((tx_done&&inflight&&selected==3)?locked_count:0)+count>14)begin
     fault_valid<=1;
     if(!fault_valid)first_missing_frame<=first_unaccepted_frame(additions[127:64]);
    end
    else begin
     for(k=0;k<14;k=k+1)if(k<count)begin c=additions[k*256+:256];
      if(k==count-1)c[15:8]=c[15:8]|1;cells[addptr(tail,k)]<=c;end
     tail<=addptr(tail,count);used<=used-((tx_done&&inflight&&selected==3)?locked_count:0)+count;
    end
   end
   // An upstream EVR failure retires only the unaccepted CFG suffix.  It
   // does not replace that failure reason with this producer's overflow code.
   if(capture_fault&&!start&&first_missing_frame==64'hffffffffffffffff)
    first_missing_frame<=first_unaccepted_frame(64'hffffffffffffffff);
   if(start)begin initial_state<=live_state;initial_frame<=frame_id;initial_subcycle<=subcycle;
    initial_phase<=1;fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;head<=0;tail<=count;used<=count;inflight<=0;
    for(k=0;k<14;k=k+1)if(k<count)begin c=additions[k*256+:256];if(k==count-1)c[15:8]=c[15:8]|1;cells[k]<=c;end
   end
   if((fault_valid||capture_fault)&&!inflight&&!start)begin initial_phase<=0;used<=0;head<=0;tail<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if($isunknown({start,stop,recording,capture_fault,gain_cfg_valid,gain_sample,pan_valid,tx_ready,tx_done}))$fatal(1,"S11_CFG_CONTROL_XZ");
  if(used>14)$fatal(1,"S11_CFG_QUEUE_COUNT");
  if(inflight&&selected==3&&locked_count>used)$fatal(1,"S11_CFG_PREFIX_COUNT");
 end
 // synthesis translate_on
endmodule
