// Pure mapping. Multiple logical score keys at one pitch remain OR-combined.
module score_guide(
 input wire clk,rst,cfg_valid,cfg_prefix,input wire [23:0] cfg_order,input wire [13:0] cfg_lead,
 input wire [55:0] local_notes,input wire [31:0] held,input wire [223:0] notes,
 input wire preview_valid,input wire [63:0] preview_time,music_time,input wire [127:0] preview_notes,
 input wire [7:0] player_state,error_code,
 output reg prefix,output reg [215:0] colors,output reg [5:0] unmapped_count,
 output reg [31:0] invalid_config_count
);
 reg [23:0] order;reg [13:0] lead;
 reg [7:0] current,upcoming;reg [7:0] used;reg permutation_ok;
 reg found;integer i,j,n,offset;
 always @(*)begin
  used=0;permutation_ok=cfg_lead<=9600;
  for(i=0;i<8;i=i+1)begin if(used[cfg_order[i*3+:3]])permutation_ok=0;used[cfg_order[i*3+:3]]=1;end
  current=0;upcoming=0;unmapped_count=0;
  for(i=0;i<32;i=i+1)if(held[i])begin
   found=0;for(j=0;j<8;j=j+1)if(notes[i*7+:7]==local_notes[j*7+:7])begin current[j]=1;found=1;end
   if(!found)unmapped_count=unmapped_count+1;
  end
  if(preview_valid&&preview_time>=music_time&&preview_time-music_time<=lead)
   for(j=0;j<8;j=j+1)upcoming[j]=preview_notes[local_notes[j*7+:7]];
  colors=0;offset=prefix?1:0;
  if(prefix)begin
   if(error_code!=0)colors[23:0]=24'h001800;
   else if(player_state==3||unmapped_count!=0)colors[23:0]=24'h101000;
   else if(player_state==2)colors[23:0]=24'h080000;
  end
  for(j=0;j<8;j=j+1)begin
   n=offset+order[j*3+:3];
   if(player_state==3)colors[n*24+:24]=24'h080800;
   else if(current[j])colors[n*24+:24]=24'h180000;
   else if(upcoming[j])colors[n*24+:24]=24'h000010;
  end
 end
 always @(posedge clk)begin
  if(rst)begin prefix<=1;order<=24'hfac688;lead<=4800;invalid_config_count<=0;end
  else if(cfg_valid)begin
   if(permutation_ok)begin prefix<=cfg_prefix;order<=cfg_order;lead<=cfg_lead;end
   else invalid_config_count<=invalid_config_count+1;
  end
 end
endmodule
