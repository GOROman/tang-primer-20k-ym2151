module nlg_player (
    input  wire       clk,
    input  wire       rst,
    input  wire       opm_cen,
    input  wire       stream_valid,
    input  wire [7:0] stream_data,
    output wire       stream_ready,
    output reg        cs_n,
    output reg        wr_n,
    output reg        a0,
    output reg [7:0]  din,
    output reg        playing
);
    localparam S_CMD      = 4'd0;
    localparam S_ADDR     = 4'd1;
    localparam S_DATA     = 4'd2;
    localparam S_ADDR_WR  = 4'd3;
    localparam S_ADDR_GAP = 4'd4;
    localparam S_DATA_WR  = 4'd5;
    localparam S_BUSY     = 4'd6;
    localparam S_WAIT     = 4'd7;
    localparam S_CTC0     = 4'd8;
    localparam S_CTC3     = 4'd9;
    localparam S_SKIP1    = 4'd10;
    localparam S_SKIP2    = 4'd11;

    reg [3:0] state;
    reg [7:0] reg_addr;
    reg [7:0] reg_data;
    reg [7:0] ctc0;
    reg [7:0] ctc3;
    reg [23:0] tick_period;
    reg [31:0] opm_time;
    reg [31:0] deadline;
    reg [5:0] busy_ticks;

    assign stream_ready = (state == S_CMD || state == S_ADDR ||
                           state == S_DATA || state == S_CTC0 ||
                           state == S_CTC3 || state == S_SKIP1 ||
                           state == S_SKIP2);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_CMD;
            cs_n <= 1'b1;
            wr_n <= 1'b1;
            a0 <= 1'b0;
            din <= 8'd0;
            ctc0 <= 8'd0;
            ctc3 <= 8'd0;
            tick_period <= 24'd0;
            opm_time <= 32'd0;
            deadline <= 32'd0;
            busy_ticks <= 6'd0;
            playing <= 1'b1;
        end else begin
            cs_n <= 1'b1;
            wr_n <= 1'b1;
            if (opm_cen)
                opm_time <= opm_time + 1'b1;

            case (state)
                S_CMD: if (stream_valid) begin
                    case (stream_data)
                        8'h01: state <= S_ADDR;
                        8'h80: begin
                            deadline <= deadline + tick_period;
                            state <= S_WAIT;
                        end
                        8'h81: state <= S_CTC0;
                        8'h82: state <= S_CTC3;
                        8'h00, 8'h02: state <= S_SKIP1;
                        default: state <= S_CMD;
                    endcase
                end
                S_ADDR: if (stream_valid) begin
                    reg_addr <= stream_data;
                    state <= S_DATA;
                end
                S_DATA: if (stream_valid) begin
                    reg_data <= stream_data;
                    state <= S_ADDR_WR;
                end
                S_ADDR_WR: begin
                    cs_n <= 1'b0;
                    wr_n <= 1'b0;
                    a0 <= 1'b0;
                    din <= reg_addr;
                    state <= S_ADDR_GAP;
                end
                S_ADDR_GAP: state <= S_DATA_WR;
                S_DATA_WR: begin
                    cs_n <= 1'b0;
                    wr_n <= 1'b0;
                    a0 <= 1'b1;
                    din <= reg_data;
                    busy_ticks <= 6'd40;
                    state <= S_BUSY;
                end
                S_BUSY: if (opm_cen) begin
                    if (busy_ticks == 0)
                        state <= S_CMD;
                    else
                        busy_ticks <= busy_ticks - 1'b1;
                end
                S_WAIT: if ($signed(opm_time - deadline) >= 0)
                    state <= S_CMD;
                S_CTC0: if (stream_valid) begin
                    ctc0 <= stream_data;
                    // Keep the intermediate products wide enough for the
                    // complete CTC0 * 256 * CTC3 period.
                    tick_period <= {16'd0, stream_data} * 24'd256 * {16'd0, ctc3};
                    state <= S_CMD;
                end
                S_CTC3: if (stream_valid) begin
                    ctc3 <= stream_data;
                    tick_period <= {16'd0, ctc0} * 24'd256 * {16'd0, stream_data};
                    state <= S_CMD;
                end
                S_SKIP1: if (stream_valid) state <= S_SKIP2;
                S_SKIP2: if (stream_valid) state <= S_CMD;
                default: state <= S_CMD;
            endcase
        end
    end
endmodule
