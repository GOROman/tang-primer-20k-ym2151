//pt8211驱动
module pt8211_drive(
    input        clk_1p536m,//bit时钟，每个采样点占32个clk_1p536m(左右声道各16)
    input        rst_n     ,//低电平有效异步复位信号
    //用户数据接口
    input [15:0] idata     ,
    output       req       ,//数据请求信号，可接外部FIFO的读请求(为避免空读，尽量和!fifo_empty相与后作为fifo_rd)
    //pt8211接口
    output       HP_BCK   ,//同clk_1p536m
    output       HP_WS    ,//左右声道切换信号，低电平对应右声道
    output       HP_DIN    //dac串行数据输入信号
);
reg [4:0] b_cnt;
reg       req_r,req_r1;//req_r1延迟req_r一个时钟
reg [15:0] idata_r;//暂存idata,用于移位并转串时的中间变量
reg HP_WS_r,HP_DIN_r;
assign HP_BCK = clk_1p536m;
assign HP_WS  = HP_WS_r   ;
assign HP_DIN = HP_DIN_r  ;
assign req    = req_r     ;
//b_cnt
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    b_cnt    <= 5'd0;
else
    b_cnt <= b_cnt+1'b1;
end
//req_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    req_r <= 1'b0;
else
    req_r <= (b_cnt == 5'd0) || (b_cnt == 5'd16);//每16个时钟读入一个数据
end
//idata_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    begin
    req_r1  <= 1'b0;
    idata_r <= 16'd0;
    end
else
    begin
    req_r1  <= req_r;
    idata_r <= req_r1?idata:idata_r<<1;
    end
end
//HP_DIN_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    HP_DIN_r <= 1'b0;
else
    HP_DIN_r <= idata_r[15];
end
//HP_WS_r
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    HP_WS_r <= 1'b0;
else
    HP_WS_r <= (b_cnt == 5'd3)?1'b0: ((b_cnt == 5'd19)?1'b1:HP_WS_r);//对齐数据
end
endmodule

// Stereo PT8211 driver.  The left and right samples are latched together at
// the beginning of each 32-bit frame, then shifted out as right followed by
// left while preserving the original PT8211 timing.
module pt8211_stereo_drive(
    input        clk_1p536m,
    input        rst_n,
    input [15:0] idata_l,
    input [15:0] idata_r,
    output       req,
    output       HP_BCK,
    output       HP_WS,
    output       HP_DIN
);
reg [4:0] b_cnt;
reg       req_r, req_r1;
reg       right_slot;
reg [15:0] frame_l, frame_r;
reg [15:0] shift_r;
reg HP_WS_r, HP_DIN_r;

// PT8211 samples DIN on the rising edge of BCK.  The serializer updates DIN
// on clk_1p536m's rising edge, so invert BCK to provide half a cycle of setup.
assign HP_BCK = ~clk_1p536m;
assign HP_WS  = HP_WS_r;
assign HP_DIN = HP_DIN_r;
assign req    = req_r;

always @(posedge clk_1p536m or negedge rst_n) begin
    if(!rst_n) begin
        b_cnt     <= 5'd0;
        req_r     <= 1'b0;
        right_slot <= 1'b1;
        frame_l   <= 16'd0;
        frame_r   <= 16'd0;
    end else begin
        b_cnt <= b_cnt + 1'b1;
        req_r <= (b_cnt == 5'd0) || (b_cnt == 5'd16);

        if (b_cnt == 5'd0) begin
            // PT8211 selects the right input while WS is low.
            right_slot <= 1'b1;
            frame_l <= idata_l;
            frame_r <= idata_r;
        end else if (b_cnt == 5'd16) begin
            // PT8211 selects the left input while WS is high.
            right_slot <= 1'b0;
        end
    end
end

always @(posedge clk_1p536m or negedge rst_n) begin
    if(!rst_n) begin
        req_r1  <= 1'b0;
        shift_r <= 16'd0;
    end else begin
        req_r1 <= req_r;
        if (req_r1)
            shift_r <= right_slot ? frame_r : frame_l;
        else
            shift_r <= shift_r << 1;
    end
end

always @(posedge clk_1p536m or negedge rst_n) begin
    if(!rst_n)
        HP_DIN_r <= 1'b0;
    else
        HP_DIN_r <= shift_r[15];
end

always @(posedge clk_1p536m or negedge rst_n) begin
    if(!rst_n)
        HP_WS_r <= 1'b0;
    else
        HP_WS_r <= (b_cnt == 5'd3) ? 1'b0 :
                   ((b_cnt == 5'd19) ? 1'b1 : HP_WS_r);
end
endmodule
