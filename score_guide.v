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
 function note_equal(input [6:0] a,b);
  reg [3:0] matched /* synthesis syn_keep=1 */;
  begin
   matched[0]=(a[1:0]==b[1:0]);matched[1]=(a[3:2]==b[3:2]);
   matched[2]=(a[5:4]==b[5:4]);matched[3]=(a[6]==b[6]);
   note_equal=&matched;
  end
 endfunction
 reg [23:0] key_color[0:7];
 wire [3:0] lamp_position[0:7];
 generate for(genvar k=0;k<8;k=k+1)begin: fixed_position
  assign lamp_position[k]={1'b0,order[k*3+:3]}+{3'd0,prefix};
 end endgenerate
 always @(*)begin
  used=0;permutation_ok=cfg_lead<=9600;
  for(i=0;i<8;i=i+1)begin if(used[cfg_order[i*3+:3]])permutation_ok=0;used[cfg_order[i*3+:3]]=1;end
  current=0;upcoming=0;unmapped_count=0;found=0;
  for(i=0;i<32;i=i+1)if(held[i])begin
   found=0;for(j=0;j<8;j=j+1)if(note_equal(notes[i*7+:7],local_notes[j*7+:7]))begin current[j]=1;found=1;end
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
   key_color[j]=0;
   if(player_state==3)key_color[j]=24'h080800;
   else if(current[j])key_color[j]=24'h180000;
   else if(upcoming[j])key_color[j]=24'h000010;
  end
  // Fixed output slices avoid integer multiply and a variable 216-bit write.
  // Order remains an accepted permutation, and ascending-key overwrite wins.
  for(n=0;n<9;n=n+1)for(j=0;j<8;j=j+1)
   if(lamp_position[j]==n)begin
    colors[n*24+:24]=colors[n*24+:24]|key_color[j];
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
