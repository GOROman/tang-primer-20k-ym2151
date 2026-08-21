module top (
    input  wire clk,
    input  wire rst_n,
    input  wire vol_down_n,
    input  wire vol_up_n,
    input  wire wav_trig_n,
    input  wire uart_rx_i,
    output wire uart_txp,
    output wire HP_BCK,
    output wire HP_WS,
    output wire HP_DIN,
    output wire PA_EN,
    output reg [3:0] led,
    output wire O_tmds_clk_p, output wire O_tmds_clk_n,
    output wire [2:0] O_tmds_data_p, output wire [2:0] O_tmds_data_n
    ,output wire [13:0] ddr_addr, output wire [2:0] ddr_bank,
    output wire ddr_cs, output wire ddr_ras, output wire ddr_cas,
    output wire ddr_we, output wire ddr_ck, output wire ddr_ck_n,
    output wire ddr_cke, output wire ddr_odt, output wire ddr_reset_n,
    output wire [1:0] ddr_dm, inout wire [15:0] ddr_dq,
    inout wire [1:0] ddr_dqs, inout wire [1:0] ddr_dqs_n
);
    wire rst = ~rst_n;

    // Keep the analog amplifier muted while clocks and the DAC settle.
    reg [22:0] mute_counter;
    reg audio_ready;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mute_counter <= 23'd0;
            audio_ready <= 1'b0;
        end else if (!audio_ready) begin
            if (mute_counter == 23'd6_749_999)
                audio_ready <= 1'b1;
            else
                mute_counter <= mute_counter + 1'b1;
        end
    end

    reg song_enable;
    reg [24:0] song_delay;
    reg auto_start_pending;
    reg restart_pending;
    wire uart_command_valid;
    wire [7:0] uart_command_data;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            song_enable <= 1'b0;
            song_delay <= 25'd0;
            auto_start_pending <= 1'b1;
            restart_pending <= 1'b0;
        end else if (uart_command_valid &&
                     (uart_command_data == "S" || uart_command_data == "s")) begin
            song_enable <= 1'b0;
            auto_start_pending <= 1'b0;
            restart_pending <= 1'b0;
        end else if (uart_command_valid && ddr_loaded &&
                    (uart_command_data == "P" || uart_command_data == "p" ||
                     uart_command_data == "R" || uart_command_data == "r")) begin
            // Hold reset for one clock so the stream, decoder and JT51 all
            // return to byte zero before playback is released again.
            song_enable <= 1'b0;
            auto_start_pending <= 1'b0;
            restart_pending <= 1'b1;
        end else if (restart_pending) begin
            song_enable <= 1'b1;
            restart_pending <= 1'b0;
        end else if (auto_start_pending && !song_enable && ddr_loaded) begin
            if (song_delay == 25'd26_999_999) begin
                song_enable <= 1'b1;
                auto_start_pending <= 1'b0;
            end else begin
                song_delay <= song_delay + 1'b1;
            end
        end
    end

    // Hold the music core while the two-second direct-DAC diagnostic scale
    // plays, then start the YM2151 stream from its first byte.
    reg [25:0] dac_test_hold_count;
    reg dac_test_hold;
    reg dac_test_completed;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dac_test_hold_count <= 26'd0;
            dac_test_hold <= 1'b1;
            dac_test_completed <= 1'b0;
        end else if (!song_enable && !dac_test_completed) begin
            dac_test_hold_count <= 26'd0;
            dac_test_hold <= 1'b1;
        end else if (dac_test_hold) begin
            if (dac_test_hold_count == 26'd59_399_999) begin
                dac_test_hold <= 1'b0;
                dac_test_completed <= 1'b1;
            end else
                dac_test_hold_count <= dac_test_hold_count + 1'b1;
        end else if (dac_test_completed) begin
            dac_test_hold <= 1'b0;
        end
    end

    wire core_rst = rst | ~song_enable | dac_test_hold;

    // S2/S3 volume control in 5% steps, limited to 5%..25%.
    // The Dock amplifier is already loud, so keep both JT51 and the stored
    // voice sample in the range proven clean by the startup DAC test.
    reg [1:0] down_sync;
    reg [1:0] up_sync;
    reg down_prev;
    reg up_prev;
    reg [20:0] button_lockout;
    reg [4:0] volume;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            down_sync <= 2'b11;
            up_sync <= 2'b11;
            down_prev <= 1'b1;
            up_prev <= 1'b1;
            button_lockout <= 21'd0;
            volume <= 5'd1; // 5% (1 x 5%)
        end else begin
            down_sync <= {down_sync[0], vol_down_n};
            up_sync <= {up_sync[0], vol_up_n};
            down_prev <= down_sync[1];
            up_prev <= up_sync[1];
            if (button_lockout != 0) begin
                button_lockout <= button_lockout - 1'b1;
            end else if (down_prev && !down_sync[1]) begin
                if (volume > 1)
                    volume <= volume - 1'b1;
                button_lockout <= 21'd1_349_999;
            end else if (up_prev && !up_sync[1]) begin
                if (volume < 5)
                    volume <= volume + 1'b1;
                button_lockout <= 21'd1_349_999;
            end
        end
    end

    // Fractional 4 MHz clock enable from the board's 27 MHz clock.
    reg [24:0] cen_acc;
    reg opm_cen;
    reg opm_half;
    reg opm_cen_p1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cen_acc <= 0;
            opm_cen <= 0;
            opm_half <= 0;
            opm_cen_p1 <= 0;
        end else begin
            opm_cen <= 0;
            opm_cen_p1 <= 0;
            if (cen_acc + 25'd4_000_000 >= 25'd27_000_000) begin
                cen_acc <= cen_acc + 25'd4_000_000 - 25'd27_000_000;
                opm_cen <= 1;
                opm_half <= ~opm_half;
                if (!opm_half)
                    opm_cen_p1 <= 1;
            end else begin
                cen_acc <= cen_acc + 25'd4_000_000;
            end
        end
    end

    wire [7:0] rom_data;
    wire [16:0] rom_addr;
    wire rom_req_toggle;
    wire rom_done_toggle;
    wire ddr_loaded;
    wire [3:0] ddr_crc_kind;
    wire stream_valid;
    wire [7:0] stream_data;
    wire stream_ready;
    wire stream_done;
    reg rom_req_seen;
    reg rom_done_seen_debug;
    reg rom_req_prev_debug;
    reg rom_done_prev_debug;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rom_req_seen <= 1'b0;
            rom_done_seen_debug <= 1'b0;
            rom_req_prev_debug <= 1'b0;
            rom_done_prev_debug <= 1'b0;
        end else begin
            rom_req_prev_debug <= rom_req_toggle;
            rom_done_prev_debug <= rom_done_toggle;
            if (rom_req_toggle != rom_req_prev_debug)
                rom_req_seen <= 1'b1;
            if (rom_done_toggle != rom_done_prev_debug)
                rom_done_seen_debug <= 1'b1;
        end
    end

    ddr_song_rom u_song_rom(
        .clk(clk), .rst_n(rst_n), .uart_rx_i(uart_rx_i),
        .addr(rom_addr), .req_toggle(rom_req_toggle),
        .data(rom_data), .done_toggle(rom_done_toggle), .loaded(ddr_loaded),
        .crc_kind(ddr_crc_kind),
        .command_valid(uart_command_valid), .command_data(uart_command_data),
        .ddr_addr(ddr_addr), .ddr_bank(ddr_bank), .ddr_cs(ddr_cs),
        .ddr_ras(ddr_ras), .ddr_cas(ddr_cas), .ddr_we(ddr_we),
        .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n), .ddr_cke(ddr_cke),
        .ddr_odt(ddr_odt), .ddr_reset_n(ddr_reset_n), .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq), .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n),
        .uart_txp(uart_txp));
    lzss_stream u_stream(
        .clk(clk), .rst(core_rst), .out_ready(stream_ready),
        .out_valid(stream_valid), .out_data(stream_data), .done(stream_done),
        .rom_addr(rom_addr), .rom_req_toggle(rom_req_toggle),
        .rom_done_toggle(rom_done_toggle), .rom_data(rom_data)
    );

    wire jt_cs_n, jt_wr_n, jt_a0;
    wire [7:0] jt_din;
    wire playing;
    reg opm_write_seen;
    always @(posedge clk or posedge rst) begin
        if (rst)
            opm_write_seen <= 1'b0;
        else if (!jt_cs_n && !jt_wr_n && jt_a0)
            opm_write_seen <= 1'b1;
    end

    nlg_player u_player(
        .clk(clk), .rst(core_rst), .opm_cen(opm_cen),
        .stream_valid(stream_valid), .stream_data(stream_data),
        .stream_ready(stream_ready), .cs_n(jt_cs_n), .wr_n(jt_wr_n),
        .a0(jt_a0), .din(jt_din), .playing(playing)
    );

    wire [7:0] jt_dout;
    wire sample;
    wire signed [15:0] left;
    wire signed [15:0] right;
    wire signed [15:0] xleft;
    wire signed [15:0] xright;
    jt51 u_jt51(
        .rst(core_rst), .clk(clk), .cen(opm_cen), .cen_p1(opm_cen_p1),
        .cs_n(jt_cs_n), .wr_n(jt_wr_n), .a0(jt_a0), .din(jt_din),
        .dout(jt_dout), .ct1(), .ct2(), .irq_n(), .sample(sample),
        .left(left), .right(right), .xleft(xleft), .xright(xright)
    );

    wire signed [22:0] left_wide = {{7{xleft[15]}}, xleft};
    wire signed [22:0] right_wide = {{7{xright[15]}}, xright};
    wire signed [22:0] volume_wide = {18'd0, volume};
    wire signed [22:0] left_product = left_wide * volume_wide;
    wire signed [22:0] right_product = right_wide * volume_wide;
    reg signed [22:0] scaled_left;
    reg signed [22:0] scaled_right;
    reg signed [15:0] pcm_left;
    reg signed [15:0] pcm_right;
    reg pcm_toggle;
    always @(*) begin
        scaled_left = left_product / 23'sd20;
        scaled_right = right_product / 23'sd20;
    end

    // Saturate each channel instead of wrapping at high output levels.
    always @(posedge clk or posedge core_rst) begin
        if (core_rst) begin
            pcm_left <= 16'sd0;
            pcm_right <= 16'sd0;
            pcm_toggle <= 1'b0;
        end else if (stream_done) begin
            pcm_left <= 16'sd0;
            pcm_right <= 16'sd0;
            pcm_toggle <= ~pcm_toggle;
        end else if (sample) begin
            pcm_toggle <= ~pcm_toggle;
            if (scaled_left > 23'sd32767)
                pcm_left <= 16'sd32767;
            else if (scaled_left < -23'sd32768)
                pcm_left <= -16'sd32768;
            else
                pcm_left <= scaled_left[15:0];

            if (scaled_right > 23'sd32767)
                pcm_right <= 16'sd32767;
            else if (scaled_right < -23'sd32768)
                pcm_right <= -16'sd32768;
            else
                pcm_right <= scaled_right[15:0];
        end
    end

    // Primer 20K Dock onboard PT8211 stereo DAC.
    // The PLL produces 48 MHz and its dedicated /24 output produces a
    // 2 MHz BCK, giving a 62.5 kHz stereo frame rate.
    // This matches JT51 at a 4 MHz OPM clock (4 MHz / 64).
    wire clk_48m;
    wire clk_2m;
    wire audio_pll_lock;
    wire dac_req;
    // Once playback has been released, keep the Dock amplifier enabled even
    // if the startup-delay flag failed to cross its terminal count.
    wire amp_enable = audio_ready | song_enable;
    assign PA_EN = amp_enable;

    Gowin_rPLL u_audio_pll(
        .clkout(clk_48m),
        .clkoutd(clk_2m),
        .lock(audio_pll_lock),
        .reset(rst),
        .clkin(clk)
    );

    // Transfer each complete stereo sample into the DAC clock domain.
    // The source registers remain stable until the next toggle, so the
    // synchronized event prevents mixed-bit captures across the CDC.
    reg pcm_toggle_sync1;
    reg pcm_toggle_sync2;
    reg pcm_toggle_sync2_d;
    reg signed [15:0] jt_dac_left;
    reg signed [15:0] jt_dac_right;
    always @(posedge clk_2m or negedge rst_n) begin
        if (!rst_n) begin
            pcm_toggle_sync1 <= 1'b0;
            pcm_toggle_sync2 <= 1'b0;
            pcm_toggle_sync2_d <= 1'b0;
            jt_dac_left <= 16'sd0;
            jt_dac_right <= 16'sd0;
        end else begin
            pcm_toggle_sync1 <= pcm_toggle;
            pcm_toggle_sync2 <= pcm_toggle_sync1;
            pcm_toggle_sync2_d <= pcm_toggle_sync2;
            if (pcm_toggle_sync2 != pcm_toggle_sync2_d) begin
                jt_dac_left <= pcm_left;
                jt_dac_right <= pcm_right;
            end
        end
    end

    hdmi_opm_debug u_hdmi_debug(
        .clk27(clk), .rst_n(rst_n),
        .opm_cs_n(jt_cs_n), .opm_wr_n(jt_wr_n), .opm_a0(jt_a0),
        .opm_data(jt_din),
        .tmds_clk_p(O_tmds_clk_p), .tmds_clk_n(O_tmds_clk_n),
        .tmds_data_p(O_tmds_data_p), .tmds_data_n(O_tmds_data_n));

    wire dac_test_active;
    wire signed [15:0] dac_test_left;
    wire signed [15:0] dac_test_right;
    dac_scale_test u_dac_scale_test(
        .clk(clk_2m), .rst_n(rst_n), .enable(song_enable), .req(dac_req),
        .active(dac_test_active), .pcm_left(dac_test_left),
        .pcm_right(dac_test_right)
    );

    wire signed [15:0] dac_left = dac_test_active ? dac_test_left : jt_dac_left;
    wire signed [15:0] dac_right = dac_test_active ? dac_test_right : jt_dac_right;

    pt8211_stereo_drive u_pt8211(
        .clk_1p536m(clk_2m),
        .rst_n(rst_n),
        .idata_l(dac_left),
        .idata_r(dac_right),
        .req(dac_req),
        .HP_BCK(HP_BCK),
        .HP_WS(HP_WS),
        .HP_DIN(HP_DIN)
    );

    // A CRC failure is a hard stop.  Blink all four LEDs quickly so it is
    // distinguishable from the normal one-LED CRC-passed indication.
    reg [21:0] error_blink_counter;
    reg error_blink_phase;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            error_blink_counter <= 22'd0;
            error_blink_phase <= 1'b0;
        end else if (ddr_crc_kind == 4'b1111) begin
            if (error_blink_counter == 22'd2_699_999) begin
                error_blink_counter <= 22'd0;
                error_blink_phase <= ~error_blink_phase;
            end else begin
                error_blink_counter <= error_blink_counter + 1'b1;
            end
        end else begin
            error_blink_counter <= 22'd0;
            error_blink_phase <= 1'b0;
        end
    end

    always @(*) begin
        if (ddr_crc_kind == 4'b1111)
            led = error_blink_phase ? 4'b1111 : 4'b0000;
        else
            led = ddr_crc_kind;
    end
endmodule
