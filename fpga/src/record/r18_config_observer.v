// Passive configuration journal. Initial values are cloned on START; later
// records describe real parameter state changes and actual engine edges.
// Fourteen cells include the immutable in-flight prefix: appending does not
// change a transaction already reserved by the EVR RAM writer.
module r18_config_observer #(parameter integer SYNC_READ=1)(
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
 input wire pan_valid,input wire[4:0] pan_slot,
 input wire[314:0] pan_before,pan_after,
 input wire [2:0] stream_state,input wire [31:0] stream_generation,
 input wire [63:0] media_epoch,
 output wire tx_valid,output reg [5:0] tx_count,input wire [5:0] tx_index,output wire [255:0] tx_cell,
 input wire tx_read_valid,input wire [15:0] tx_read_epoch,
 output reg tx_response_valid,output reg [5:0] tx_response_index,output reg [15:0] tx_response_epoch,
 input wire tx_ready,tx_done,
 output reg fault_valid,output reg [63:0] first_missing_frame,
 output wire [7:0] fault_code,output wire idle,output wire capture_quiet
);
 wire r54_equal_0;
 wire r54_equal_1;
 wire r54_equal_2;
 wire r54_equal_3;
 wire r54_equal_4;

 localparam TIMBRE=14,GLIDE=15,PAN=16,EFFECTS=17,GAIN=18,KEYMAP=19,MEDIA=20,EXT=21;
 function [255:0] make_cell;
  input [7:0] typ,flags;input [63:0] frame,note,payload;
  begin make_cell={payload,note,frame,32'd0,8'hff,8'hff,flags,typ};end
 endfunction
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
 // Musical configuration journal: one immutable pending change per producer.
 // A seven-bit mask FIFO preserves capture order; payloads are never replaced.

 reg [811:0] initial_state;reg [63:0] initial_frame;reg [15:0] initial_subcycle;
 reg initial_pending,inflight;reg [3:0] selected;
 reg [6:0] occupied,masks[0:7];reg [2:0] head,tail;reg [3:0] groups_used;
 reg [383:0] values[0:6];reg [63:0] times[0:6];reg [15:0] offsets[0:6];
 reg [63:0] pan_tag;reg [2:0] previous_timbre;reg [3:0] previous_glide;
 reg [31:0] previous_key,previous_fx,previous_gain,previous_stream;
 reg [63:0] previous_epoch,previous_frame;reg [15:0] previous_subcycle;
 reg [2:0] previous_state;reg [15:0] user_l,user_e;reg [1:0] user_mute;
 wire [811:0] live_state={media_epoch,stream_generation,stream_state,gain_frame,gain_accepted,
  gain_state,gain_current_e,gain_current_l,user_mute,user_e,user_l,
  fx_version,fx_config,keymap_version,keymap,glide_code,timbre_id};
 wire collect=recording&&!fault_valid&&!capture_fault&&!start;
 wire [6:0] changes={((recording||start)&&!stop&&pan_valid&&(!fault_valid||start)&&(!capture_fault||start)),
  collect&&(stream_state!=previous_state||!r54_equal_0||!r54_equal_1),
  collect&&(!r54_equal_2),collect&&(!r54_equal_3),
  collect&&(!r54_equal_4),collect&&(glide_code!=previous_glide),collect&&(timbre_id!=previous_timbre)};
 wire [6:0] front=masks[head];reg [2:0] first;
 always @*begin first=0;for(integer i=6;i>=0;i--)if(front[i])first=i;end
 wire [3:0] current=inflight?selected:initial_pending?4'd7:{1'b0,first};
 wire [6:0] removed=tx_done&&inflight&&selected<7?(7'd1<<selected):7'd0;
 wire pop=(|removed)&&((front&~removed)==0);
 wire collision=|(changes&(occupied&~removed));
 wire push=(|changes)&&(!collision||start)&&!rst;
 assign tx_valid=!fault_valid&&!capture_fault&&!inflight&&(initial_pending||groups_used!=0);
 assign idle=!inflight&&!initial_pending&&groups_used==0;
 assign capture_quiet=idle&&!(|changes);
 assign fault_code=8'd2;
 reg [255:0] response_cell,encoded;reg [63:0] part;reg [7:0] typ;
 always @*begin
  case(current) 7:tx_count=16;2:tx_count=2;3:tx_count=6;5:tx_count=2;default:tx_count=1;endcase
  part=0;typ=EXT;encoded=0;
  if(current==7)encoded=snapshot_cell(tx_index,initial_state,initial_frame,initial_subcycle);
  else begin
   case(current)
    0:begin typ=TIMBRE;part={45'd0,values[0][2:0],offsets[0]};end
    1:begin typ=GLIDE;part={44'd0,values[1][3:0],offsets[1]};end
    2:begin typ=tx_index==0?KEYMAP:EXT;part=tx_index==0?{8'd0,values[2][87:32]}:{16'd0,values[2][31:0],offsets[2]};end
    3:begin typ=tx_index==0?EFFECTS:EXT;part=values[3][tx_index*64+:64];end
    4:begin typ=GAIN;part={16'd0,values[4][31:0],offsets[4]};end
    5:begin typ=tx_index==0?MEDIA:EXT;part=tx_index==0?{13'd0,values[5][34:0],offsets[5]}:values[5][98:35];end
    6:begin typ=PAN;part={values[6][29:0],18'd0,offsets[6]};end
   endcase
   encoded=make_cell(typ,0,times[current],current==6?pan_tag:64'd0,part);
  end
  encoded[8]=(tx_index==tx_count-1'b1);
 end
 assign tx_cell=response_cell;
 always @(posedge clk)begin
  if(rst)begin tx_response_valid<=0;tx_response_index<=0;tx_response_epoch<=0;end
  else begin tx_response_valid<=tx_read_valid;
   if(tx_read_valid)begin response_cell<=encoded;tx_response_index<=tx_index;tx_response_epoch<=tx_read_epoch;end
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   initial_pending<=0;inflight<=0;selected<=0;occupied<=0;head<=0;tail<=0;groups_used<=0;
   fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;
   previous_timbre<=0;previous_glide<=0;previous_key<=0;previous_fx<=0;previous_gain<=0;
   previous_state<=0;previous_stream<=0;previous_epoch<=0;previous_frame<=0;previous_subcycle<=0;
   user_l<=32768;user_e<=32768;user_mute<=0;
  end else begin
   previous_timbre<=timbre_id;previous_glide<=glide_code;previous_key<=keymap_version;previous_fx<=fx_version;
   previous_gain<=gain_version;previous_state<=stream_state;previous_stream<=stream_generation;previous_epoch<=media_epoch;
   previous_frame<=frame_id;previous_subcycle<=subcycle;
   if(gain_cfg_valid&&gain_local<=32768&&gain_external<=32768)begin user_l<=gain_local;user_e<=gain_external;user_mute<={gain_external_mute,gain_local_mute};end
   if(tx_valid&&tx_ready)begin inflight<=1;selected<=current;end
   if(tx_done&&inflight)begin
    inflight<=0;if(selected==7)initial_pending<=0;
    else begin masks[head]<=front&~removed;if(pop)head<=head+1'b1;end
   end
   occupied<=(occupied&~removed)|(push?changes:7'd0);
   groups_used<=groups_used+(push?4'd1:4'd0)-(pop?4'd1:4'd0);
   if(push)begin masks[tail]<=changes;tail<=tail+1'b1;end
   if(collision&&!start)fault_valid<=1;
   if(capture_fault)fault_valid<=1;
   if(start)begin
    initial_state<=live_state;initial_frame<=frame_id;initial_subcycle<=subcycle;initial_pending<=1;inflight<=0;
    fault_valid<=0;first_missing_frame<=64'hffffffffffffffff;occupied<=changes;head<=0;tail<=push?1:0;groups_used<=push?1:0;
    if(push)masks[0]<=changes;
   end
   if(fault_valid&&!inflight&&!start)begin initial_pending<=0;groups_used<=0;occupied<=0;head<=0;tail<=0;end
  end
 end
 generate for(genvar g=0;g<7;g++)begin: capture_fields
  always @(posedge clk)if(push&&changes[g])begin
   times[g]<=g==6?frame_id:previous_frame;offsets[g]<=g==6?subcycle:previous_subcycle;
   case(g)
    0:values[g]<={381'd0,timbre_id};
    1:values[g]<={380'd0,glide_code};
    2:values[g]<={296'd0,keymap,keymap_version};
    3:values[g]<={fx_version,fx_config};
    4:values[g]<={352'd0,gain_state[31:0]};
    5:values[g]<={285'd0,media_epoch,stream_generation,stream_state};
    6:values[g]<={354'd0,pan_slot,pan_after[58:43],pan_after[12:4]};
   endcase
  end
 end endgenerate
 always @(posedge clk)if(push&&changes[6])pan_tag<={42'd0,1'b1,pan_after[58:43],pan_slot};
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(tx_read_valid&&tx_index>=tx_count)$fatal(1,"R25_CFG_INDEX");
  if(groups_used>7)$fatal(1,"R25_CFG_MASK_QUEUE");
 end
 // synthesis translate_on

 r54_full_equal #(.WIDTH(32)) r54_equal_0_tree(.a(stream_generation),.b(previous_stream),.equal(r54_equal_0));
 r54_full_equal #(.WIDTH(64)) r54_equal_1_tree(.a(media_epoch),.b(previous_epoch),.equal(r54_equal_1));
 r54_full_equal #(.WIDTH(32)) r54_equal_2_tree(.a(gain_version),.b(previous_gain),.equal(r54_equal_2));
 r54_full_equal #(.WIDTH(32)) r54_equal_3_tree(.a(fx_version),.b(previous_fx),.equal(r54_equal_3));
 r54_full_equal #(.WIDTH(32)) r54_equal_4_tree(.a(keymap_version),.b(previous_key),.equal(r54_equal_4));
endmodule
