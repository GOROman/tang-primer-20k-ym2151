module ddr_song_rom (
    input wire clk, input wire rst_n, input wire uart_rx_i,
    input wire [16:0] addr, input wire req_toggle,
    output reg [7:0] data, output reg done_toggle, output wire loaded,
    output wire [3:0] crc_kind,
    output wire command_valid, output wire [7:0] command_data,
    output wire [13:0] ddr_addr, output wire [2:0] ddr_bank,
    output wire ddr_cs, output wire ddr_ras, output wire ddr_cas,
    output wire ddr_we, output wire ddr_ck, output wire ddr_ck_n,
    output wire ddr_cke, output wire ddr_odt, output wire ddr_reset_n,
    output wire [1:0] ddr_dm, inout wire [15:0] ddr_dq,
    inout wire [1:0] ddr_dqs, inout wire [1:0] ddr_dqs_n,
    output wire uart_txp
);
    wire [7:0] upload_byte;
    wire upload_valid, upload_ready;
    wire init_done;
    wire upload_started;
    wire [31:0] crc_value;
    wire [255:0] debug_beat_crc;
    wire read_done;
    wire [7:0] read_data;
    wire [16:0] read_addr;
    assign read_addr = addr;

    wire xmodem_tx;
    xmodem_rx u_xmodem(.clk(clk), .rst_n(rst_n), .rx(uart_rx_i),
                       .upload_ready(upload_ready), .upload_byte(upload_byte),
                       .upload_valid(upload_valid), .loaded(),
                       .command_valid(command_valid), .command_data(command_data),
                       .tx(xmodem_tx));
    ddr_audio_store u_store(
        .clk27(clk), .clk2m(clk), .rst_n(rst_n), .reader_rst_n(rst_n),
        .upload_byte(upload_byte), .upload_valid(upload_valid),
        .upload_ready(upload_ready),
        .read_addr(read_addr), .read_req_toggle(req_toggle),
        .read_data(read_data), .read_done_toggle(read_done),
        .loaded(loaded), .crc_kind(crc_kind), .crc_value(crc_value),
        .debug_beat_crc(debug_beat_crc),
        .init_done(init_done), .upload_started(upload_started),
        .ddr_addr(ddr_addr), .ddr_bank(ddr_bank), .ddr_cs(ddr_cs),
        .ddr_ras(ddr_ras), .ddr_cas(ddr_cas), .ddr_we(ddr_we),
        .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n), .ddr_cke(ddr_cke),
        .ddr_odt(ddr_odt), .ddr_reset_n(ddr_reset_n), .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq), .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n));

    // Report the post-upload DDR readback result on the same UART.  The
    // message is emitted once when crc_kind changes from zero.
    reg [3:0] crc_kind_prev;
    reg [5:0] debug_pos;
    reg debug_pending;
    wire debug_start;
    wire debug_tx;
    wire debug_busy;
    reg [7:0] debug_data;
    function [7:0] hex_char;
        input [3:0] value;
        begin
            hex_char = (value < 10) ? (8'h30 + value) : (8'h41 + value - 10);
        end
    endfunction
    always @(*) begin
        case (debug_pos)
            0: debug_data="C"; 1: debug_data="R"; 2: debug_data="C";
            3: debug_data=" "; 4: debug_data=(crc_kind==1) ? "O" : (crc_kind==2) ? "R" : (crc_kind==3) ? "S" : (crc_kind==4) ? "W" : (crc_kind==5) ? "B" : "E";
            5: debug_data=(crc_kind==1) ? "K" : (crc_kind==2) ? "V" : (crc_kind==3) ? "W" : (crc_kind==4) ? "R" : (crc_kind==5) ? "R" : "R";
            6: debug_data=" "; 7: debug_data="=";
            8: debug_data=hex_char(crc_value[31:28]); 9: debug_data=hex_char(crc_value[27:24]);
            10: debug_data=hex_char(crc_value[23:20]); 11: debug_data=hex_char(crc_value[19:16]);
            12: debug_data=hex_char(crc_value[15:12]); 13: debug_data=hex_char(crc_value[11:8]);
            14: debug_data=hex_char(crc_value[7:4]); 15: debug_data=hex_char(crc_value[3:0]);
            16: debug_data=8'h0d;
            17: debug_data=8'h0a;
            50: debug_data=8'h0d;
            51: debug_data=8'h0a;
            default: debug_data = (debug_pos >= 18 && debug_pos < 50) ?
                debug_beat_crc[(debug_pos-18)*8 +: 8] : 8'h20;
        endcase
    end
    assign debug_start = debug_pending && !debug_busy;
    uart_tx u_debug_tx(.clk(clk), .rst_n(rst_n), .start(debug_start),
                       .data(debug_data), .tx(debug_tx), .busy(debug_busy));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_kind_prev <= 0;
            debug_pos <= 0;
            debug_pending <= 0;
        end else begin
            if (crc_kind != crc_kind_prev && crc_kind != 0) begin
                crc_kind_prev <= crc_kind;
                debug_pos <= 0;
                debug_pending <= 1;
            end else if (debug_pending && !debug_busy) begin
                if (debug_pos == 6'd51)
                    debug_pending <= 0;
                else
                    debug_pos <= debug_pos + 1'b1;
            end
        end
    end
    assign uart_txp = (debug_pending || debug_busy) ? debug_tx : xmodem_tx;

    reg done_s1, done_s2, done_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_s1 <= 0; done_s2 <= 0; done_seen <= 0;
            done_toggle <= 0; data <= 0;
        end else begin
            done_s1 <= read_done;
            done_s2 <= done_s1;
            if (done_s2 != done_seen) begin
                done_seen <= done_s2;
                data <= read_data;
                done_toggle <= ~done_toggle;
            end
        end
    end
endmodule
