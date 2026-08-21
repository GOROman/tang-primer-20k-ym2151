module lzss_stream (
    input  wire       clk,
    input  wire       rst,
    input  wire       out_ready,
    output reg        out_valid,
    output reg [7:0]  out_data,
    output reg        done,
    output reg [16:0] rom_addr,
    output reg        rom_req_toggle,
    input  wire        rom_done_toggle,
    input  wire [7:0]  rom_data
);
    `include "song_meta.vh"

    localparam S_CTRL_REQ  = 4'd0;
    localparam S_CTRL_WAIT = 4'd1;
    localparam S_TOKEN     = 4'd2;
    localparam S_LIT_REQ   = 4'd3;
    localparam S_LIT_WAIT  = 4'd4;
    localparam S_M1_REQ    = 4'd5;
    localparam S_M1_WAIT   = 4'd6;
    localparam S_M2_REQ    = 4'd7;
    localparam S_M2_WAIT   = 4'd8;
    localparam S_MATCH_REQ = 4'd9;
    localparam S_MATCH_WAIT= 4'd10;
    localparam S_MATCH_OUT = 4'd11;
    localparam S_HOLD      = 4'd12;

    reg [3:0] state;
    reg [7:0] control;
    reg [3:0] token_count;
    reg [7:0] match_lo;
    reg [11:0] match_dist;
    reg [4:0] match_left;
    reg [19:0] raw_count;
    reg rom_done_seen;

    reg [7:0] window [0:4095];
    reg [11:0] win_pos;
    reg [11:0] win_rd_addr;
    reg [7:0] win_rd_data;

    always @(posedge clk) begin
        win_rd_data <= window[win_rd_addr];
        if (out_valid && out_ready)
            window[win_pos] <= out_data;
    end

    task advance_token;
        begin
            control <= {1'b0, control[7:1]};
            token_count <= token_count - 1'b1;
            state <= S_TOKEN;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_CTRL_REQ;
            rom_addr    <= 17'd0;
            rom_req_toggle <= 1'b0;
            rom_done_seen <= 1'b0;
            control     <= 8'd0;
            token_count <= 4'd0;
            out_valid   <= 1'b0;
            out_data    <= 8'd0;
            done        <= 1'b0;
            win_pos     <= 12'd0;
            raw_count   <= 20'd0;
            match_left  <= 5'd0;
        end else if (!done) begin
            case (state)
                S_CTRL_REQ: begin
                    if (raw_count >= SONG_RAW_BYTES) begin
                        done <= 1'b1;
                    end else begin
                        rom_req_toggle <= ~rom_req_toggle;
                        state <= S_CTRL_WAIT;
                    end
                end
                S_CTRL_WAIT: begin
                    if (rom_done_toggle != rom_done_seen) begin
                        rom_done_seen <= rom_done_toggle;
                        control <= rom_data;
                        token_count <= 4'd8;
                        rom_addr <= rom_addr + 1'b1;
                        state <= S_TOKEN;
                    end
                end
                S_TOKEN: begin
                    if (raw_count >= SONG_RAW_BYTES) begin
                        done <= 1'b1;
                    end else if (token_count == 0) begin
                        state <= S_CTRL_REQ;
                    end else if (control[0]) begin
                        state <= S_LIT_REQ;
                    end else begin
                        state <= S_M1_REQ;
                    end
                end
                S_LIT_REQ: begin
                    rom_req_toggle <= ~rom_req_toggle;
                    state <= S_LIT_WAIT;
                end
                S_LIT_WAIT: begin
                    if (rom_done_toggle != rom_done_seen) begin
                        rom_done_seen <= rom_done_toggle;
                        out_data <= rom_data;
                        out_valid <= 1'b1;
                        rom_addr <= rom_addr + 1'b1;
                        state <= S_HOLD;
                    end
                end
                S_M1_REQ: begin
                    rom_req_toggle <= ~rom_req_toggle;
                    state <= S_M1_WAIT;
                end
                S_M1_WAIT: begin
                    if (rom_done_toggle != rom_done_seen) begin
                        rom_done_seen <= rom_done_toggle;
                        match_lo <= rom_data;
                        rom_addr <= rom_addr + 1'b1;
                        state <= S_M2_REQ;
                    end
                end
                S_M2_REQ: begin
                    rom_req_toggle <= ~rom_req_toggle;
                    state <= S_M2_WAIT;
                end
                S_M2_WAIT: begin
                    if (rom_done_toggle != rom_done_seen) begin
                        rom_done_seen <= rom_done_toggle;
                        match_dist <= {rom_data[7:4], match_lo} + 1'b1;
                        match_left <= {1'b0, rom_data[3:0]} + 5'd3;
                        rom_addr <= rom_addr + 1'b1;
                        state <= S_MATCH_REQ;
                    end
                end
                S_MATCH_REQ: begin
                    win_rd_addr <= win_pos - match_dist;
                    state <= S_MATCH_WAIT;
                end
                S_MATCH_WAIT: state <= S_MATCH_OUT;
                S_MATCH_OUT: begin
                    out_data <= win_rd_data;
                    out_valid <= 1'b1;
                    state <= S_HOLD;
                end
                S_HOLD: begin
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        win_pos <= win_pos + 1'b1;
                        raw_count <= raw_count + 1'b1;
                        if (match_left != 0) begin
                            if (match_left == 1) begin
                                match_left <= 0;
                                advance_token();
                            end else begin
                                match_left <= match_left - 1'b1;
                                state <= S_MATCH_REQ;
                            end
                        end else begin
                            advance_token();
                        end
                    end
                end
                default: state <= S_CTRL_REQ;
            endcase
        end
    end
endmodule
