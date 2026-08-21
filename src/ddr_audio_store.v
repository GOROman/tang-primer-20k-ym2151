module ddr_audio_store (
    input wire clk27, input wire clk2m, input wire rst_n,
    input wire reader_rst_n,
    input wire [7:0] upload_byte, input wire upload_valid,
    input wire [16:0] read_addr, input wire read_req_toggle,
    output reg [7:0] read_data, output reg read_done_toggle,
    output reg loaded, output reg [3:0] crc_kind,
    output reg [31:0] crc_value,
    output reg [255:0] debug_beat_crc,
    output wire init_done, output wire upload_started,
    output wire upload_ready,
    output wire [13:0] ddr_addr, output wire [2:0] ddr_bank,
    output wire ddr_cs, output wire ddr_ras, output wire ddr_cas,
    output wire ddr_we, output wire ddr_ck, output wire ddr_ck_n,
    output wire ddr_cke, output wire ddr_odt, output wire ddr_reset_n,
    output wire [1:0] ddr_dm, inout wire [15:0] ddr_dq,
    inout wire [1:0] ddr_dqs, inout wire [1:0] ddr_dqs_n
);
    // 31898-byte compressed YS II "TO MAKE THE END OF BATTLE" NLG stream,
    // padded to one complete 1 KiB XMODEM packet at the tail.
    localparam integer AUDIO_BYTES = 32768;
    localparam [31:0] AUDIO_CRC32 = 32'he67b77fb;
    // One verification line is one official 8-beat DDR burst = 128 bytes.
    localparam [12:0] AUDIO_LAST_LINE = 13'd255;

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] data_in;
        integer bit_index;
        reg [31:0] crc;
        begin
            crc = crc_in ^ data_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
            crc32_byte = crc;
        end
    endfunction

    function [31:0] crc32_block;
        input [31:0] crc_in;
        input [127:0] data_in;
        integer byte_index;
        reg [31:0] crc;
        begin
            crc = crc_in;
            for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                crc = crc32_byte(crc, data_in[byte_index*8 +: 8]);
            crc32_block = crc;
        end
    endfunction
    function [31:0] crc32_block_reverse;
        input [31:0] crc_in;
        input [127:0] data_in;
        integer byte_index;
        reg [31:0] crc;
        begin
            crc = crc_in;
            for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                crc = crc32_byte(crc, data_in[(15-byte_index)*8 +: 8]);
            crc32_block_reverse = crc;
        end
    endfunction
    function [31:0] crc32_block_swap16;
        input [31:0] crc_in;
        input [127:0] data_in;
        integer byte_index;
        reg [31:0] crc;
        begin
            crc = crc_in;
            for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                crc = crc32_byte(crc, data_in[(byte_index[3:1]*16) + ((byte_index[0] == 1'b0) ? 8 : 0) +: 8]);
            crc32_block_swap16 = crc;
        end
    endfunction
    function [31:0] crc32_block_reverse_words;
        input [31:0] crc_in;
        input [127:0] data_in;
        integer byte_index;
        reg [31:0] crc;
        begin
            crc = crc_in;
            for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                crc = crc32_byte(crc, data_in[((7-(byte_index >> 1))*16) + (byte_index[0]*8) +: 8]);
            crc32_block_reverse_words = crc;
        end
    endfunction
    // The official Tang Primer 20K DDR test keeps the PLL and DDR IP in
    // reset for 256 input-clock cycles after configuration.  The board reset
    // button is normally released while SRAM is programmed, so relying only
    // on rst_n can otherwise start the DDR PHY without any reset pulse.
    reg [7:0] ddr_por_count = 8'd0;
    reg ddr_por_done = 1'b0;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            ddr_por_count <= 8'd0;
            ddr_por_done <= 1'b0;
        end else if (!ddr_por_done) begin
            if (ddr_por_count == 8'hff)
                ddr_por_done <= 1'b1;
            else
                ddr_por_count <= ddr_por_count + 1'b1;
        end
    end
    wire ddr_rst_n = rst_n && ddr_por_done;

    wire memory_clk, pll_lock, app_clk, calib;
    assign init_done = calib;
    ddr_pll u_pll(.clkin(clk27), .reset(~ddr_rst_n),
                  .clkout(memory_clk), .lock(pll_lock));

    reg upload_toggle;
    reg [7:0] upload_hold;
    reg ack_s1, ack_s2;
    reg upload_ack;
    always @(posedge clk27 or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin upload_toggle<=0; upload_hold<=0; ack_s1<=0; ack_s2<=0; end
        else begin
            ack_s1 <= upload_ack; ack_s2 <= ack_s1;
            if (upload_valid && upload_toggle == ack_s2) begin
                upload_hold <= upload_byte; upload_toggle <= ~upload_toggle;
            end
        end
    end

    reg ut_s1, ut_s2;
    reg [127:0] pack;
    reg [3:0] pack_pos;
    reg [1023:0] burst_pack;
    reg [2:0] burst_beat;
    reg [16:0] byte_count;
    reg [31:0] upload_crc;
    assign upload_started = byte_count != 0;
    // Keep ready visible after the final DDR commit so the XMODEM sender can
    // observe completion and return the last packet ACK.  The write-side
    // acceptance condition below still rejects bytes once loaded is set.
    assign upload_ready = (upload_toggle == ack_s2) && !write_pending;
    reg write_pending;
    reg [26:0] raw_addr;
    // The Gowin DDR3 application port expects bank/row/column bits in this
    // order.  Keep raw_addr linear for the byte store and remap only at the IP.
    wire [26:0] app_addr;
    assign app_addr = {raw_addr[12:10], raw_addr[26:13], raw_addr[9:0]};
    reg cmd_en, wr_en, wr_end;
    reg [2:0] cmd;
    reg write_data_sent;
    reg [2:0] write_beat;
    // Register the selected 128-bit beat before asserting wr_en.  Driving the
    // 100 MHz DDR application port directly from a 1024-bit variable-select
    // mux caused marginal setup timing and run-to-run bit corruption.
    reg [127:0] wr_data;
    wire cmd_ready, wr_ready;
    wire rd_valid, rd_end;
    wire [127:0] rd_data;
    reg [5:0] burst_number;
    reg verifying;
    reg verify_cmd_pending;
    reg verify_read_pending;
    reg [12:0] verify_line;
    reg [2:0] verify_beat;
    reg [31:0] verify_crc;
    reg [1023:0] verify_burst_data;
    reg verify_crc_processing;
    reg [6:0] verify_crc_byte;
    wire [31:0] verify_crc_next =
        crc32_byte(verify_crc, verify_burst_data[7:0]);

    reg rr_s1, rr_s2, rr_seen;
    reg reader_rst_s1, reader_rst_s2;
    reg [16:0] read_addr_hold;
    reg read_cmd_pending;
    reg read_pending;
    reg [3:0] read_lane;
    reg [1:0] done_sync;
    always @(posedge app_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            ut_s1<=0; ut_s2<=0; upload_ack<=0; pack<=0; pack_pos<=0;
            burst_pack<=0; burst_beat<=0;
            byte_count<=0; upload_crc<=32'hffffffff; write_pending<=0; loaded<=0; crc_kind<=0; crc_value<=0; debug_beat_crc<=0; raw_addr<=0;
            cmd_en<=0; wr_en<=0; wr_end<=0; cmd<=0;
            write_data_sent<=0; write_beat<=0; wr_data<=0;
            burst_number<=0; rr_s1<=0; rr_s2<=0; rr_seen<=0;
            verifying<=0; verify_cmd_pending<=0; verify_read_pending<=0;
            verify_line<=0; verify_beat<=0; verify_crc<=32'hffffffff;
            verify_burst_data<=0; verify_crc_processing<=0;
            verify_crc_byte<=0;
            reader_rst_s1<=0; reader_rst_s2<=0;
            read_cmd_pending<=0; read_pending<=0; read_lane<=0; read_data<=0;
            read_done_toggle<=0;
        end else begin
            reader_rst_s1 <= reader_rst_n;
            reader_rst_s2 <= reader_rst_s1;
            ut_s1 <= upload_toggle; ut_s2 <= ut_s1;
            rr_s1 <= read_req_toggle; rr_s2 <= rr_s1;
            cmd_en <= 0; wr_en <= 0; wr_end <= 0;
            if (calib && ut_s2 != upload_ack && !loaded &&
                !verifying && !write_pending) begin
                pack[pack_pos*8 +: 8] <= upload_hold;
                upload_ack <= ut_s2;
                byte_count <= byte_count + 1'b1;
                upload_crc <= crc32_byte(upload_crc, upload_hold);
                if (byte_count + 1'b1 == AUDIO_BYTES)
                    debug_beat_crc[31:0] <=
                        crc32_byte(upload_crc, upload_hold) ^ 32'hffffffff;
                if (pack_pos == 15) begin
                    burst_pack[burst_beat*128 +: 128] <= {upload_hold, pack[119:0]};
                    pack_pos <= 0;
                    if (burst_beat == 3'd7) begin
                        // The official Gowin interface uses eight 128-bit
                        // data beats per command (app_burst_number=7).
                        raw_addr <= (({12'd0, byte_count} + 1'b1) >> 1) - 27'd64;
                        write_beat <= 0;
                        burst_beat <= 0;
                        write_pending <= 1;
                        write_data_sent <= 0;
                        burst_number <= 6'd7;
                    end else begin
                        burst_beat <= burst_beat + 1'b1;
                    end
                end else pack_pos <= pack_pos + 1'b1;
            end
            // Present each beat for a complete cycle.  Advance write_beat
            // only on the following edge where the DDR port observes the
            // already-high wr_en together with wr_ready.  Advancing it when
            // wr_en is first asserted would make the DDR capture the next
            // beat instead of the current one.
            if (write_pending && !write_data_sent) begin
                if (!wr_en) begin
                    wr_data <= burst_pack[write_beat*128 +: 128];
                    wr_en <= 1;
                    // The official Gowin example asserts wr_data_end for
                    // every 128-bit application word, not only the final
                    // word of the eight-beat command burst.
                    wr_end <= 1;
                end else if (wr_ready) begin
                    if (write_beat == 3'd7)
                        write_data_sent <= 1;
                    else
                        write_beat <= write_beat + 1'b1;
                end else begin
                    wr_en <= 1;
                    wr_end <= 1;
                end
            end
            if (write_pending && write_data_sent && cmd_ready) begin
                cmd <= 3'd0;
                cmd_en <= 1;
                write_pending <= 0;
                write_data_sent <= 0;
                if (byte_count == AUDIO_BYTES) begin
                    // Read every line back before allowing playback.  Keep
                    // upload_ready visible so XMODEM can ACK its final byte.
                    verifying <= 1'b1;
                    verify_cmd_pending <= 1'b0;
                    verify_read_pending <= 1'b0;
                    verify_line <= 13'd0;
                    verify_beat <= 3'd0;
                    verify_crc <= 32'hffffffff;
                    verify_burst_data <= 0;
                    verify_crc_processing <= 0;
                    verify_crc_byte <= 0;
                end
            end
            if (verifying && !verify_cmd_pending && !verify_read_pending &&
                !verify_crc_processing) begin
                raw_addr <= {8'd0, verify_line, 6'b000000};
                burst_number <= 6'd7;
                verify_cmd_pending <= 1;
            end
            if (verifying && verify_cmd_pending && cmd_ready) begin
                cmd <= 3'd1;
                cmd_en <= 1;
                burst_number <= 6'd7;
                verify_cmd_pending <= 0;
                verify_read_pending <= 1;
            end
            if (verifying && verify_read_pending && rd_valid) begin
                verify_burst_data[verify_beat*128 +: 128] <= rd_data;
                if (verify_beat == 3'd7) begin
                    verify_read_pending <= 0;
                    verify_crc_processing <= 1;
                    verify_crc_byte <= 0;
                end else begin
                    verify_beat <= verify_beat + 1'b1;
                end
            end
            // Process one byte per 100 MHz application clock.  The previous
            // implementation expanded 16 CRC byte steps into one cycle and
            // missed timing by more than 16 ns, making the result unstable.
            if (verifying && verify_crc_processing) begin
                verify_crc <= verify_crc_next;
                verify_burst_data <= verify_burst_data >> 8;
                if (verify_crc_byte == 7'd127) begin
                    if (verify_line == 13'd255)
                        debug_beat_crc[63:32] <= verify_crc_next ^ 32'hffffffff;
                    if (verify_line == 13'd511)
                        debug_beat_crc[95:64] <= verify_crc_next ^ 32'hffffffff;
                    if (verify_line == AUDIO_LAST_LINE)
                        debug_beat_crc[127:96] <= verify_crc_next ^ 32'hffffffff;
                    verify_crc_processing <= 0;
                    verify_beat <= 0;
                    if (verify_line == AUDIO_LAST_LINE) begin
                        crc_value <= verify_crc_next ^ 32'hffffffff;
                        if ((verify_crc_next ^ 32'hffffffff) == AUDIO_CRC32) begin
                            loaded <= 1'b1;
                            crc_kind <= 4'b0001;
                        end else begin
                            loaded <= 1'b0;
                            crc_kind <= 4'b1111;
                        end
                        verifying <= 0;
                    end else begin
                        verify_line <= verify_line + 1'b1;
                    end
                end else begin
                    verify_crc_byte <= verify_crc_byte + 1'b1;
                end
            end
            if (!reader_rst_s2) begin
                rr_s1 <= 0;
                rr_s2 <= 0;
                rr_seen <= 0;
                read_cmd_pending <= 0;
                read_pending <= 0;
                read_done_toggle <= 0;
            end else if (loaded && rr_s2 != rr_seen && !read_cmd_pending && !read_pending) begin
                read_addr_hold <= read_addr;
                case (crc_kind)
                    4'b0010: read_lane <= 4'd15 - read_addr[3:0];
                    4'b0011: read_lane <= {read_addr[3:1], ~read_addr[0]};
                    4'b0100: read_lane <= {~read_addr[3:1], read_addr[0]};
                    default: read_lane <= read_addr[3:0];
                endcase
                raw_addr <= {7'd0, read_addr[16:4], 3'b000};
                burst_number <= 0;
                read_cmd_pending <= 1;
                rr_seen <= rr_s2;
            end
            if (reader_rst_s2 && read_cmd_pending && cmd_ready) begin
                cmd <= 3'd1;
                cmd_en <= 1;
                read_cmd_pending <= 0;
                read_pending <= 1;
            end
            if (reader_rst_s2 && read_pending && rd_valid) begin
                read_data <= rd_data[read_lane*8 +: 8];
                read_done_toggle <= ~read_done_toggle;
                read_pending <= 0;
            end
        end
    end

    assign ddr_cs = 1'b0;
    DDR3_Memory_Interface_Top u_ddr(
        .clk(clk27), .memory_clk(memory_clk), .pll_lock(pll_lock), .rst_n(ddr_rst_n),
        .app_burst_number(burst_number), .cmd_ready(cmd_ready), .cmd(cmd),
        .cmd_en(cmd_en), .addr({1'b0,app_addr}), .wr_data_rdy(wr_ready),
        .wr_data(wr_data), .wr_data_en(wr_en), .wr_data_end(wr_end),
        .wr_data_mask(16'h0000), .rd_data(rd_data), .rd_data_valid(rd_valid),
        .rd_data_end(rd_end), .sr_req(1'b0), .ref_req(1'b0), .sr_ack(),
        .ref_ack(), .init_calib_complete(calib), .clk_out(app_clk), .burst(1'b1),
        .ddr_rst(), .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank),
        .O_ddr_cs_n(), .O_ddr_ras_n(ddr_ras), .O_ddr_cas_n(ddr_cas),
        .O_ddr_we_n(ddr_we), .O_ddr_clk(ddr_ck), .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke), .O_ddr_odt(ddr_odt), .O_ddr_reset_n(ddr_reset_n),
        .O_ddr_dqm(ddr_dm), .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs),
        .IO_ddr_dqs_n(ddr_dqs_n));
endmodule
