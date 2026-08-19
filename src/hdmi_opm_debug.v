module hdmi_opm_debug (
    input wire clk27, input wire rst_n,
    input wire opm_cs_n, input wire opm_wr_n, input wire opm_a0,
    input wire [7:0] opm_data,
    output wire tmds_clk_p, output wire tmds_clk_n,
    output wire [2:0] tmds_data_p, output wire [2:0] tmds_data_n
);
    reg [7:0] opm_addr;
    reg [7:0] regs [0:255];
    reg [1:0] changed_age [0:255];
    reg [11:0] age_div;
    reg [7:0] age_scan;
    integer i;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            opm_addr <= 0;
            age_div <= 0; age_scan <= 0;
            for (i=0; i<256; i=i+1) begin
                regs[i] <= 0;
                changed_age[i] <= 0;
            end
        end else begin
            if (age_div == 12'd2699) begin
                age_div <= 0;
                age_scan <= age_scan + 1'b1;
                if (changed_age[age_scan] != 0)
                    changed_age[age_scan] <= changed_age[age_scan] - 1'b1;
            end else age_div <= age_div + 1'b1;
            if (!opm_cs_n && !opm_wr_n) begin
                if (!opm_a0) opm_addr <= opm_data;
                else begin
                    if (regs[opm_addr] != opm_data) changed_age[opm_addr] <= 3;
                    regs[opm_addr] <= opm_data;
                end
            end
        end
    end

    wire serial_clk, pll_lock, pix_clk;
    TMDS_rPLL u_video_pll(.clkin(clk27), .clkout(serial_clk), .lock(pll_lock));
    CLKDIV u_video_div(.RESETN(rst_n & pll_lock), .HCLKIN(serial_clk),
                       .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_video_div.DIV_MODE="5";
    defparam u_video_div.GSREN="false";

    reg [11:0] h;
    reg [9:0] v;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin h<=0; v<=0; end
        else if (h==1649) begin
            h<=0;
            if (v==749) v<=0; else v<=v+1'b1;
        end else h<=h+1'b1;
    end
    wire hs = h < 40;
    wire vs = v < 5;
    wire de = h>=260 && h<1540 && v>=25 && v<745;
    wire [10:0] x = h-260;
    wire [9:0] y = v-25;

    wire in_grid = x>=64 && x<1216 && y>=72 && y<648;
    wire [10:0] gx = x-64;
    wire [9:0] gy = y-72;
    wire [3:0] col = gx / 72;
    wire [3:0] row = gy / 36;
    wire [6:0] cx = gx % 72;
    wire [5:0] cy = gy % 36;
    wire [7:0] reg_value = regs[{row,col}];
    wire recently_changed = changed_age[{row,col}] != 0;

    function [7:0] title_char;
        input [4:0] pos;
        begin
            case(pos)
                0:title_char="Y"; 1:title_char="M"; 2:title_char="2";
                3:title_char="1"; 4:title_char="5"; 5:title_char="1";
                6:title_char=" "; 7:title_char="("; 8:title_char="O";
                9:title_char="P"; 10:title_char="M"; 11:title_char=")";
                12:title_char=" "; 13:title_char="R"; 14:title_char="E";
                15:title_char="G"; 16:title_char="I"; 17:title_char="S";
                18:title_char="T"; 19:title_char="O"; 20:title_char="R";
                default:title_char=" ";
            endcase
        end
    endfunction
    function [4:0] font_row;
        input [7:0] c; input [2:0] ry;
        begin
            case(c)
                "Y":case(ry) 0:font_row=5'b10001;1:font_row=5'b10001;2:font_row=5'b01010;3:font_row=5'b00100;4:font_row=5'b00100;5:font_row=5'b00100;default:font_row=5'b00100;endcase
                "M":case(ry) 0:font_row=5'b10001;1:font_row=5'b11011;2:font_row=5'b10101;default:font_row=5'b10001;endcase
                "O":case(ry) 0:font_row=5'b01110;6:font_row=5'b01110;default:font_row=5'b10001;endcase
                "P":case(ry) 0:font_row=5'b11110;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11110;default:font_row=5'b10000;endcase
                "R":case(ry) 0:font_row=5'b11110;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11110;4:font_row=5'b10100;5:font_row=5'b10010;default:font_row=5'b10001;endcase
                "E":case(ry) 0:font_row=5'b11111;3:font_row=5'b11110;6:font_row=5'b11111;default:font_row=5'b10000;endcase
                "G":case(ry) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10000;3:font_row=5'b10111;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b01110;endcase
                "I":case(ry) 0:font_row=5'b11111;6:font_row=5'b11111;default:font_row=5'b00100;endcase
                "S":case(ry) 0:font_row=5'b01111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b01110;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11110;endcase
                "T":case(ry) 0:font_row=5'b11111;default:font_row=5'b00100;endcase
                "1":case(ry) 0:font_row=5'b00100;1:font_row=5'b01100;6:font_row=5'b11111;default:font_row=5'b00100;endcase
                "2":case(ry) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b00001;3:font_row=5'b00010;4:font_row=5'b00100;5:font_row=5'b01000;default:font_row=5'b11111;endcase
                "5":case(ry) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b11110;3:font_row=5'b00001;4:font_row=5'b00001;5:font_row=5'b10001;default:font_row=5'b01110;endcase
                "(":case(ry) 0:font_row=5'b00010;1:font_row=5'b00100;2:font_row=5'b01000;3:font_row=5'b01000;4:font_row=5'b01000;5:font_row=5'b00100;default:font_row=5'b00010;endcase
                ")":case(ry) 0:font_row=5'b01000;1:font_row=5'b00100;2:font_row=5'b00010;3:font_row=5'b00010;4:font_row=5'b00010;5:font_row=5'b00100;default:font_row=5'b01000;endcase
                default:font_row=0;
            endcase
        end
    endfunction

    function [6:0] segments;
        input [3:0] n;
        begin
            case(n)
                0:segments=7'b1111110; 1:segments=7'b0110000;
                2:segments=7'b1101101; 3:segments=7'b1111001;
                4:segments=7'b0110011; 5:segments=7'b1011011;
                6:segments=7'b1011111; 7:segments=7'b1110000;
                8:segments=7'b1111111; 9:segments=7'b1111011;
                10:segments=7'b1110111; 11:segments=7'b0011111;
                12:segments=7'b1001110; 13:segments=7'b0111101;
                14:segments=7'b1001111; default:segments=7'b1000111;
            endcase
        end
    endfunction
    function digit_pixel;
        input [3:0] n; input [5:0] dx; input [5:0] dy;
        reg [6:0] s;
        begin
            s=segments(n);
            digit_pixel = (s[6] && dy<3 && dx>=3 && dx<15) ||
                          (s[5] && dx>=15 && dy>=3 && dy<11) ||
                          (s[4] && dx>=15 && dy>=13 && dy<21) ||
                          (s[3] && dy>=21 && dy<24 && dx>=3 && dx<15) ||
                          (s[2] && dx<3 && dy>=13 && dy<21) ||
                          (s[1] && dx<3 && dy>=3 && dy<11) ||
                          (s[0] && dy>=11 && dy<14 && dx>=3 && dx<15);
        end
    endfunction
    wire d0 = in_grid && cx>=14 && cx<32 && cy>=6 && cy<30 &&
              digit_pixel(reg_value[7:4],cx-14,cy-6);
    wire d1 = in_grid && cx>=38 && cx<56 && cy>=6 && cy<30 &&
              digit_pixel(reg_value[3:0],cx-38,cy-6);
    wire grid_line = in_grid && (cx==0 || cy==0);
    wire title_area = x>=64 && x<484 && y>=28 && y<42;
    wire [8:0] title_x = x-64;
    wire [4:0] title_pos = title_x / 20;
    wire [4:0] title_px = (title_x % 20) >> 1;
    wire [3:0] title_py = (y-28) >> 1;
    wire title_pixel = title_area && title_px<5 && title_py<7 &&
                       font_row(title_char(title_pos),title_py)[4-title_px];
    wire value_pixel = d0 || d1;
    wire [7:0] r = !de ? 0 : title_pixel ? 8'h80 : value_pixel ? (recently_changed?8'h30:8'h90) : grid_line ? 8'h18 : 8'h02;
    wire [7:0] g = !de ? 0 : title_pixel ? 8'he8 : value_pixel ? (recently_changed?8'he8:8'h98) : grid_line ? 8'h40 : 8'h08;
    wire [7:0] b = !de ? 0 : title_pixel ? 8'hff : value_pixel ? (recently_changed?8'hff:8'ha0) : grid_line ? 8'h58 : 8'h12;

    DVI_TX_Top u_dvi(
        .I_rst_n(rst_n & pll_lock), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs), .I_rgb_hs(hs), .I_rgb_de(de),
        .I_rgb_r(r), .I_rgb_g(g), .I_rgb_b(b),
        .O_tmds_clk_p(tmds_clk_p), .O_tmds_clk_n(tmds_clk_n),
        .O_tmds_data_p(tmds_data_p), .O_tmds_data_n(tmds_data_n));
endmodule
