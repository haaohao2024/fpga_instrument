// Passive configuration journal. Initial values are cloned on START; later
// records describe real parameter state changes and actual engine edges.
// Fourteen cells include the immutable in-flight prefix: appending does not
// change a transaction already reserved by the EVR RAM writer.
module s11_config_observer #(parameter integer SYNC_READ=1)(
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
 input wire [2047:0] slot_ids,
 input wire [511:0] slot_generations,
 input wire [63:0] map_query_runtime,map_query_persistent,
 input wire [15:0] map_query_generation,
 input wire [2:0] stream_state,input wire [31:0] stream_generation,
 input wire [63:0] media_epoch,
 output wire tx_valid,output reg [5:0] tx_count,input wire [5:0] tx_index,output wire [255:0] tx_cell,
 input wire tx_read_valid,input wire [15:0] tx_read_epoch,
 output reg tx_response_valid,output reg [5:0] tx_response_index,output reg [15:0] tx_response_epoch,
 input wire tx_ready,tx_done,
 output reg fault_valid,output reg [63:0] first_missing_frame,
 output wire [7:0] fault_code,output wire idle
);
 localparam TIMBRE=14,GLIDE=15,PAN=16,EFFECTS=17,GAIN=18,KEYMAP=19,MEDIA=20,EXT=21;
 reg [14:0] descriptors[0:13];reg [3:0] head,tail;
 // One immutable timestamp pair per capture clock, shared by all groups.
 // At most 14 capture clocks can remain owned by the 14-cell queue.
 reg [159:0] timestamp_pool[0:13];reg [3:0] timestamp_tail;
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
 // All calls use5-bit positions/counts or protected_cells from those
 // counts. The count-1 expression must retain signed-1 when count is zero.
 // Six signed input bits and seven signed sum bits preserve every call,
 // including the inactive count-zero last-marker expression.
 function [3:0] addptr;
  input [3:0] p;input signed [5:0] n;reg signed [6:0] v;
  begin
   v=$signed({3'b000,p})+$signed({n[5],n});
   if(v>=7'sd14)v=v-7'sd14;addptr=v[3:0];
  end
 endfunction
 function [63:0] descriptor_frame;
  input [3:0] address;
  reg [14:0] descriptor;reg [159:0] stamp;
  begin
   descriptor=descriptors[address];stamp=timestamp_pool[descriptor[4:1]];
   descriptor_frame=descriptor[14:12]==6?stamp[159:96]:stamp[79:16];
  end
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
     first_unaccepted_frame=descriptor_frame(addptr(head,protected_cells));
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
 // Fixed candidates and destination decodes replace variable packed-vector
 // insertion and multi-address writes. All decisions use pre-edge state.
 wire collect_changes=recording&&!fault_valid&&!capture_fault&&!start;
 wire add_timbre=collect_changes&&(timbre_id!=previous_timbre);
 wire add_glide=collect_changes&&(glide_code!=previous_glide);
 wire add_key=collect_changes&&(keymap_version!=previous_keymap_version);
 wire add_fx=collect_changes&&(fx_version!=previous_fx_version);
 wire add_gain=collect_changes&&(gain_accepted!=previous_gain_accepted||gain_version!=previous_gain_version||(previous_remaining!=0&&gain_remaining==0));
 wire add_media=collect_changes&&(stream_state!=previous_stream_state||stream_generation!=previous_stream_generation||media_epoch!=previous_media_epoch);
 // Fixed word slices give the Pan query a bounded 32-word mux.
 wire [63:0] slot_id_words[0:31];
 wire [15:0] slot_generation_words[0:31];
 generate for(genvar p=0;p<32;p=p+1)begin: fixed_pan_words
  assign slot_id_words[p]=slot_ids[p*64+:64];
  assign slot_generation_words[p]=slot_generations[p*16+:16];
 end endgenerate
 wire add_pan=(recording||start)&&!stop&&(!fault_valid||start)&&(!capture_fault||start)&&pan_valid&&pan_value<=256&&slot_valid[pan_slot]&&
  !slot_cancel[pan_slot]&&slot_id_words[pan_slot]==pan_id&&slot_generation_words[pan_slot]==pan_generation;
 wire [63:0] pan_pid=start?pan_slot+64'd1:
  (map_query_runtime==pan_id&&map_query_generation==pan_generation)?map_query_persistent:64'd0;
 wire [3:0] gain_phase=gain_accepted!=previous_gain_accepted?4'd1:gain_version!=previous_gain_version?4'd2:4'd3;
 wire [4:0] pos_timbre=0;
 wire [4:0] pos_glide=pos_timbre+(add_timbre?5'd1:5'd0);
 wire [4:0] pos_key=pos_glide+(add_glide?5'd1:5'd0);
 wire [4:0] pos_fx=pos_key+(add_key?5'd2:5'd0);
 wire [4:0] pos_gain=pos_fx+(add_fx?5'd6:5'd0);
 wire [4:0] pos_media=pos_gain+(add_gain?5'd4:5'd0);
 wire [4:0] pos_pan=pos_media+(add_media?5'd2:5'd0);
 wire [4:0] count=pos_pan+(add_pan?5'd2:5'd0);
 wire [4:0] released=(tx_done&&inflight&&selected==3)?locked_count:5'd0;
 wire [5:0] next_used={1'b0,used}-{1'b0,released}+{1'b0,count};
 wire queue_write=count!=0&&(start||(count<=14&&next_used<=14));
 wire [3:0] write_base=tail;
 wire [63:0] additions_first_frame=pos_pan!=0?previous_frame:frame_id;
 wire [63:0] candidate_payload[0:17];
 wire [4:0] candidate_type[0:17],candidate_position[0:17];
 wire [3:0] candidate_address[0:17];
 wire [17:0] candidate_valid;
 assign candidate_payload[0]={45'd0,timbre_id,previous_subcycle};
 assign candidate_type[0]=TIMBRE;
 assign candidate_position[0]=pos_timbre+5'd0;
 assign candidate_address[0]=addptr(write_base,candidate_position[0]);
 assign candidate_valid[0]=add_timbre;
 assign candidate_payload[1]={44'd0,glide_code,previous_subcycle};
 assign candidate_type[1]=GLIDE;
 assign candidate_position[1]=pos_glide+5'd0;
 assign candidate_address[1]=addptr(write_base,candidate_position[1]);
 assign candidate_valid[1]=add_glide;
 assign candidate_payload[2]={8'd0,keymap};
 assign candidate_type[2]=KEYMAP;
 assign candidate_position[2]=pos_key+5'd0;
 assign candidate_address[2]=addptr(write_base,candidate_position[2]);
 assign candidate_valid[2]=add_key;
 assign candidate_payload[3]={16'd0,keymap_version,previous_subcycle};
 assign candidate_type[3]=EXT;
 assign candidate_position[3]=pos_key+5'd1;
 assign candidate_address[3]=addptr(write_base,candidate_position[3]);
 assign candidate_valid[3]=add_key;
 assign candidate_payload[4]=fx_config[63:0];
 assign candidate_type[4]=EFFECTS;
 assign candidate_position[4]=pos_fx+5'd0;
 assign candidate_address[4]=addptr(write_base,candidate_position[4]);
 assign candidate_valid[4]=add_fx;
 assign candidate_payload[5]=fx_config[64+:64];
 assign candidate_type[5]=EXT;
 assign candidate_position[5]=pos_fx+5'd1;
 assign candidate_address[5]=addptr(write_base,candidate_position[5]);
 assign candidate_valid[5]=add_fx;
 assign candidate_payload[6]=fx_config[128+:64];
 assign candidate_type[6]=EXT;
 assign candidate_position[6]=pos_fx+5'd2;
 assign candidate_address[6]=addptr(write_base,candidate_position[6]);
 assign candidate_valid[6]=add_fx;
 assign candidate_payload[7]=fx_config[192+:64];
 assign candidate_type[7]=EXT;
 assign candidate_position[7]=pos_fx+5'd3;
 assign candidate_address[7]=addptr(write_base,candidate_position[7]);
 assign candidate_valid[7]=add_fx;
 assign candidate_payload[8]=fx_config[256+:64];
 assign candidate_type[8]=EXT;
 assign candidate_position[8]=pos_fx+5'd4;
 assign candidate_address[8]=addptr(write_base,candidate_position[8]);
 assign candidate_valid[8]=add_fx;
 assign candidate_payload[9]={fx_version,fx_config[351:320]};
 assign candidate_type[9]=EXT;
 assign candidate_position[9]=pos_fx+5'd5;
 assign candidate_address[9]=addptr(write_base,candidate_position[9]);
 assign candidate_valid[9]=add_fx;
 assign candidate_payload[10]={2'd0,gain_phase,gain_state[103],gain_remaining,user_mute,user_e,user_l,previous_subcycle};
 assign candidate_type[10]=GAIN;
 assign candidate_position[10]=pos_gain+5'd0;
 assign candidate_address[10]=addptr(write_base,candidate_position[10]);
 assign candidate_valid[10]=add_gain;
 assign candidate_payload[11]={gain_state[31:0],gain_current_e,gain_current_l};
 assign candidate_type[11]=EXT;
 assign candidate_position[11]=pos_gain+5'd1;
 assign candidate_address[11]=addptr(write_base,candidate_position[11]);
 assign candidate_valid[11]=add_gain;
 assign candidate_payload[12]={gain_accepted,gain_version};
 assign candidate_type[12]=EXT;
 assign candidate_position[12]=pos_gain+5'd2;
 assign candidate_address[12]=addptr(write_base,candidate_position[12]);
 assign candidate_valid[12]=add_gain;
 assign candidate_payload[13]={gain_frame,32'd0};
 assign candidate_type[13]=EXT;
 assign candidate_position[13]=pos_gain+5'd3;
 assign candidate_address[13]=addptr(write_base,candidate_position[13]);
 assign candidate_valid[13]=add_gain;
 assign candidate_payload[14]={13'd0,stream_generation,stream_state,previous_subcycle};
 assign candidate_type[14]=MEDIA;
 assign candidate_position[14]=pos_media+5'd0;
 assign candidate_address[14]=addptr(write_base,candidate_position[14]);
 assign candidate_valid[14]=add_media;
 assign candidate_payload[15]=media_epoch;
 assign candidate_type[15]=EXT;
 assign candidate_position[15]=pos_media+5'd1;
 assign candidate_address[15]=addptr(write_base,candidate_position[15]);
 assign candidate_valid[15]=add_media;
 assign candidate_payload[16]={pan_slot,pan_generation,pan_value,18'd0,subcycle};
 assign candidate_type[16]=PAN;
 assign candidate_position[16]=pos_pan+5'd0;
 assign candidate_address[16]=addptr(write_base,candidate_position[16]);
 assign candidate_valid[16]=add_pan;
 assign candidate_payload[17]=pan_id;
 assign candidate_type[17]=EXT;
 assign candidate_position[17]=pos_pan+5'd1;
 assign candidate_address[17]=addptr(write_base,candidate_position[17]);
 assign candidate_valid[17]=add_pan;
 wire [3:0] timestamp_write_index=start?4'd0:timestamp_tail;
 always @(posedge clk)begin
  if(rst || start)timestamp_tail<=start&&queue_write?4'd1:4'd0;
  else if(queue_write)timestamp_tail<=timestamp_tail==13?4'd0:timestamp_tail+1'b1;
  if(!rst && queue_write)
   timestamp_pool[timestamp_write_index]<={frame_id,subcycle,previous_frame,previous_subcycle};
 end
 // Each field group can change once per clock. Capture it in its own
 // bounded pool; the 14-cell ring stores only immutable descriptors and
 // frame IDs. Capacity is floor(14 / cells_per_group), including the locked
 // prefix. A whole transaction retires before its pool entries can be reused.
 reg [2:0] timbre_pool[0:13];reg [3:0] timbre_tail;
 wire [3:0] timbre_write_index=start?4'd0:timbre_tail;
 wire capture_timbre=queue_write&&add_timbre;
 always @(posedge clk)begin
  if(rst || start)timbre_tail<=start&&capture_timbre?4'd1:4'd0;
  else if(capture_timbre)timbre_tail<=timbre_tail==13?4'd0:timbre_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_timbre)timbre_pool[timbre_write_index]<=timbre_id;
 reg [3:0] glide_pool[0:13];reg [3:0] glide_tail;
 wire [3:0] glide_write_index=start?4'd0:glide_tail;
 wire capture_glide=queue_write&&add_glide;
 always @(posedge clk)begin
  if(rst || start)glide_tail<=start&&capture_glide?4'd1:4'd0;
  else if(capture_glide)glide_tail<=glide_tail==13?4'd0:glide_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_glide)glide_pool[glide_write_index]<=glide_code;
 reg [87:0] key_pool[0:6];reg [3:0] key_tail;
 wire [3:0] key_write_index=start?4'd0:key_tail;
 wire capture_key=queue_write&&add_key;
 always @(posedge clk)begin
  if(rst || start)key_tail<=start&&capture_key?4'd1:4'd0;
  else if(capture_key)key_tail<=key_tail==6?4'd0:key_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_key)key_pool[key_write_index]<={keymap,keymap_version};
 reg [383:0] fx_pool[0:1];reg [3:0] fx_tail;
 wire [3:0] fx_write_index=start?4'd0:fx_tail;
 wire capture_fx=queue_write&&add_fx;
 always @(posedge clk)begin
  if(rst || start)fx_tail<=start&&capture_fx?4'd1:4'd0;
  else if(capture_fx)fx_tail<=fx_tail==1?4'd0:fx_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_fx)fx_pool[fx_write_index]<={fx_version,fx_config};
 reg [205:0] gain_pool[0:2];reg [3:0] gain_tail;
 wire [3:0] gain_write_index=start?4'd0:gain_tail;
 wire capture_gain=queue_write&&add_gain;
 always @(posedge clk)begin
  if(rst || start)gain_tail<=start&&capture_gain?4'd1:4'd0;
  else if(capture_gain)gain_tail<=gain_tail==2?4'd0:gain_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_gain)gain_pool[gain_write_index]<={candidate_payload[13][63:32],candidate_payload[12],candidate_payload[11],candidate_payload[10][61:16]};
 reg [98:0] media_pool[0:6];reg [3:0] media_tail;
 wire [3:0] media_write_index=start?4'd0:media_tail;
 wire capture_media=queue_write&&add_media;
 always @(posedge clk)begin
  if(rst || start)media_tail<=start&&capture_media?4'd1:4'd0;
  else if(capture_media)media_tail<=media_tail==6?4'd0:media_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_media)media_pool[media_write_index]<={media_epoch,stream_generation,stream_state};
 reg [157:0] pan_pool[0:6];reg [3:0] pan_tail;
 wire [3:0] pan_write_index=start?4'd0:pan_tail;
 wire capture_pan=queue_write&&add_pan;
 always @(posedge clk)begin
  if(rst || start)pan_tail<=start&&capture_pan?4'd1:4'd0;
  else if(capture_pan)pan_tail<=pan_tail==6?4'd0:pan_tail+1'b1;
 end
 // Pool contents are valid only through committed descriptors. Reset
 // clears their ownership, not the data RAM; every owned entry is captured
 // before any read. Exactly one address per field group is written per clock.
 always @(posedge clk)
  if(!rst && capture_pan)pan_pool[pan_write_index]<={pan_id,pan_pid,pan_slot,pan_generation,pan_value};
 wire [9:0] candidate_descriptor[0:17];
 assign candidate_descriptor[0]={3'd0,3'd0,timbre_write_index};
 assign candidate_descriptor[1]={3'd1,3'd0,glide_write_index};
 assign candidate_descriptor[2]={3'd2,3'd0,key_write_index};
 assign candidate_descriptor[3]={3'd2,3'd1,key_write_index};
 assign candidate_descriptor[4]={3'd3,3'd0,fx_write_index};
 assign candidate_descriptor[5]={3'd3,3'd1,fx_write_index};
 assign candidate_descriptor[6]={3'd3,3'd2,fx_write_index};
 assign candidate_descriptor[7]={3'd3,3'd3,fx_write_index};
 assign candidate_descriptor[8]={3'd3,3'd4,fx_write_index};
 assign candidate_descriptor[9]={3'd3,3'd5,fx_write_index};
 assign candidate_descriptor[10]={3'd4,3'd0,gain_write_index};
 assign candidate_descriptor[11]={3'd4,3'd1,gain_write_index};
 assign candidate_descriptor[12]={3'd4,3'd2,gain_write_index};
 assign candidate_descriptor[13]={3'd4,3'd3,gain_write_index};
 assign candidate_descriptor[14]={3'd5,3'd0,media_write_index};
 assign candidate_descriptor[15]={3'd5,3'd1,media_write_index};
 assign candidate_descriptor[16]={3'd6,3'd0,pan_write_index};
 assign candidate_descriptor[17]={3'd6,3'd1,pan_write_index};
 generate for(genvar cell_index=0;cell_index<14;cell_index=cell_index+1)begin: fixed_descriptor_write
  wire [17:0] hit;wire [9:0] descriptor_term[0:17];
  for(genvar candidate_index=0;candidate_index<18;candidate_index=candidate_index+1)begin: decode
   assign hit[candidate_index]=candidate_valid[candidate_index]&&
    ((start&&cell_index<count)?candidate_position[candidate_index]==cell_index:
     (count<=14&&next_used<=14&&candidate_address[candidate_index]==cell_index));
   assign descriptor_term[candidate_index]=candidate_descriptor[candidate_index]&{10{hit[candidate_index]}};
  end
  wire [9:0] write_descriptor=descriptor_term[0]|descriptor_term[1]|descriptor_term[2]|descriptor_term[3]|descriptor_term[4]|descriptor_term[5]|descriptor_term[6]|descriptor_term[7]|descriptor_term[8]|descriptor_term[9]|descriptor_term[10]|descriptor_term[11]|descriptor_term[12]|descriptor_term[13]|descriptor_term[14]|descriptor_term[15]|descriptor_term[16]|descriptor_term[17];
  wire is_pan=hit[16]||hit[17];
  wire last=(start&&cell_index<count)?cell_index==count-1'b1:cell_index==addptr(write_base,count-1'b1);
  always @(posedge clk)begin
   if(rst)descriptors[cell_index]<=0;
   else if(queue_write&&(|hit))begin
    descriptors[cell_index]<={write_descriptor,timestamp_write_index,last};
   end
  end
 end endgenerate
 wire [4:0] read_sum={1'b0,head}+{1'b0,tx_index[3:0]};
 wire [3:0] read_address=read_sum>=14 ? read_sum-5'd14 : read_sum;
 // Serialize the requested descriptor into one cell. Pool reads are
 // shared by all ring entries; no wide candidate mux is replicated 14 times.
 wire [14:0] read_descriptor=descriptors[read_address];
 wire [2:0] read_group=read_descriptor[14:12],read_part=read_descriptor[11:9];
 wire [3:0] read_pool_index=read_descriptor[8:5];
 wire [159:0] read_timestamp=timestamp_pool[read_descriptor[4:1]];
 wire [63:0] read_frame=read_group==6?read_timestamp[159:96]:read_timestamp[79:16];
 wire [15:0] read_subcycle=read_group==6?read_timestamp[95:80]:read_timestamp[15:0];
 reg [63:0] read_payload,read_pid;reg [7:0] read_type;
 always @*begin
  read_payload=0;read_pid=0;read_type=EXT;
  case(read_group)
   0:begin read_type=TIMBRE;read_payload={45'd0,timbre_pool[read_pool_index],read_subcycle};end
   1:begin read_type=GLIDE;read_payload={44'd0,glide_pool[read_pool_index],read_subcycle};end
   2:begin if(read_part==0)begin read_type=KEYMAP;read_payload={8'd0,key_pool[read_pool_index][87:32]};end
    else read_payload={16'd0,key_pool[read_pool_index][31:0],read_subcycle};end
   3:begin if(read_part==0)read_type=EFFECTS;
    if(read_part<5)read_payload=fx_pool[read_pool_index][read_part*64+:64];
    else read_payload={fx_pool[read_pool_index][383:352],fx_pool[read_pool_index][351:320]};end
   4:case(read_part)
    0:begin read_type=GAIN;read_payload={2'd0,gain_pool[read_pool_index][45:0],read_subcycle};end
    1:read_payload=gain_pool[read_pool_index][109:46];
    2:read_payload=gain_pool[read_pool_index][173:110];
    3:read_payload={gain_pool[read_pool_index][205:174],32'd0};
   endcase
   5:if(read_part==0)begin read_type=MEDIA;read_payload={13'd0,media_pool[read_pool_index][34:0],read_subcycle};end
    else read_payload=media_pool[read_pool_index][98:35];
   6:begin read_pid=pan_pool[read_pool_index][93:30];
    if(read_part==0)begin read_type=PAN;read_payload={pan_pool[read_pool_index][29:0],18'd0,read_subcycle};end
    else read_payload=pan_pool[read_pool_index][157:94];end
  endcase
 end
 reg [255:0] capture_tx_cell,response_cell;
 // Indexed combinational read: the consumer requests one immutable cell.
 // No new storage or cycle is inserted; the eight-word writer advances the
 // index only after its last word. Out-of-range indices return zero.
 always @(*)begin
  capture_tx_cell=0;tx_count=0;
  if((inflight&&selected==1)||(!inflight&&initial_phase==1))begin
   tx_count=14;
   if(tx_index<14)begin
    capture_tx_cell=snapshot_cell(tx_index,initial_state,initial_frame,initial_subcycle);
    if(tx_index==13)capture_tx_cell[15:8]=8'd3;
   end
  end else if((inflight&&selected==2)||(!inflight&&initial_phase==2))begin
   tx_count=2;
   if(tx_index<2)begin
    capture_tx_cell=snapshot_cell(14+tx_index,initial_state,initial_frame,initial_subcycle);
    if(tx_index==1)capture_tx_cell[15:8]=8'd3;
   end
  end else begin
   tx_count=inflight?locked_count:used;
   if(tx_index<tx_count && tx_index<14)
    capture_tx_cell=make_cell(read_type,{7'd0,read_descriptor[0]},read_frame,read_pid,read_payload);
  end
 end
 assign tx_cell=SYNC_READ?response_cell:capture_tx_cell;
 always @(posedge clk)begin
  if(rst)begin tx_response_valid<=0;tx_response_index<=0;tx_response_epoch<=0;end
  else begin tx_response_valid<=SYNC_READ&&tx_read_valid;
   if(SYNC_READ&&tx_read_valid)begin response_cell<=capture_tx_cell;tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(SYNC_READ&&!rst)begin
  if($isunknown(tx_read_valid))$fatal(1,"CFG_READ_CONTROL_XZ");
  if(tx_read_valid&&($isunknown({tx_index,tx_read_epoch})||tx_index>=tx_count))$fatal(1,"CFG_READ_REQUEST_RANGE");
 end
 // synthesis translate_on
 always @(posedge clk)begin
  if(rst)begin
   head<=0;tail<=0;used<=0;locked_count<=0;inflight<=0;selected<=0;initial_phase<=0;
   initial_state<=0;initial_frame<=0;initial_subcycle<=0;fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;
   previous_timbre<=0;previous_glide<=0;previous_keymap_version<=0;previous_fx_version<=0;
   previous_gain_accepted<=0;previous_gain_version<=0;previous_remaining<=0;
   previous_stream_state<=0;previous_stream_generation<=0;previous_media_epoch<=0;
   previous_frame<=0;previous_subcycle<=0;user_l<=32768;user_e<=32768;user_mute<=0;
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
   if(count!=0)begin
    if(count>14||next_used>14)begin
     fault_valid<=1;
     if(!fault_valid)first_missing_frame<=first_unaccepted_frame(additions_first_frame);
    end
    else begin
     tail<=addptr(tail,count);used<=used-((tx_done&&inflight&&selected==3)?locked_count:0)+count;
    end
   end
   // An upstream EVR failure retires only the unaccepted CFG suffix.  It
   // does not replace that failure reason with this producer's overflow code.
   if(capture_fault&&!start&&first_missing_frame==64'hffffffffffffffff)
    first_missing_frame<=first_unaccepted_frame(64'hffffffffffffffff);
   if(start)begin initial_state<=live_state;initial_frame<=frame_id;initial_subcycle<=subcycle;
    initial_phase<=1;fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;head<=0;tail<=count;used<=count;inflight<=0;
   end
   if((fault_valid||capture_fault)&&!inflight&&!start)begin initial_phase<=0;used<=0;head<=0;tail<=0;end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if($isunknown({start,stop,recording,capture_fault,gain_cfg_valid,gain_sample,pan_valid,tx_ready,tx_done}))$fatal(1,"S11_CFG_CONTROL_XZ");
  if((tx_valid||inflight)&&$isunknown(tx_index))$fatal(1,"S11_CFG_INDEX_XZ");
  if(used>14)$fatal(1,"S11_CFG_QUEUE_COUNT");
  if(inflight&&selected==3&&locked_count>used)$fatal(1,"S11_CFG_PREFIX_COUNT");
 end
 // synthesis translate_on
endmodule
