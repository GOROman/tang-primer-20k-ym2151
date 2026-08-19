module top (
    input  wire clk,
    input  wire rst_n,
    input  wire vol_down_n,
    input  wire vol_up_n,
    input  wire wav_trig_n,
    output wire HP_BCK,
    output wire HP_WS,
    output wire HP_DIN,
    output wire PA_EN,
    output reg [3:0] led,
    output wire O_tmds_clk_p, output wire O_tmds_clk_n,
    output wire [2:0] O_tmds_data_p, output wire [2:0] O_tmds_data_n
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
    wire startup_done;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            song_enable <= 1'b0;
            song_delay <= 25'd0;
        end else if (!song_enable && startup_done) begin
            if (song_delay == 25'd26_999_999)
                song_enable <= 1'b1;
            else
                song_delay <= song_delay + 1'b1;
        end
    end

    wire core_rst = rst | ~song_enable;

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
    wire [15:0] rom_addr;
    wire stream_valid;
    wire [7:0] stream_data;
    wire stream_ready;
    wire stream_done;

    song_rom u_song_rom(.clk(clk), .addr(rom_addr), .data(rom_data));
    lzss_stream u_stream(
        .clk(clk), .rst(core_rst), .out_ready(stream_ready),
        .out_valid(stream_valid), .out_data(stream_data), .done(stream_done),
        .rom_addr(rom_addr), .rom_data(rom_data)
    );

    wire jt_cs_n, jt_wr_n, jt_a0;
    wire [7:0] jt_din;
    wire playing;
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
    // Keep the YM2151-compatible left/right outputs separate for the
    // Dock's stereo PT8211 DAC.  Widen both operands before multiplying so
    // the volume product cannot be truncated by Verilog expression sizing.
    // PT8211 is a linear 16-bit DAC, so use JT51's full-resolution outputs.
    // left/right model the lower-resolution YM3012-compatible conversion.
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

    jt51 u_jt51(
        .rst(core_rst), .clk(clk), .cen(opm_cen), .cen_p1(opm_cen_p1),
        .cs_n(jt_cs_n), .wr_n(jt_wr_n), .a0(jt_a0), .din(jt_din),
        .dout(jt_dout), .ct1(), .ct2(), .irq_n(),
        .sample(sample), .left(left), .right(right),
        .xleft(xleft), .xright(xright)
    );

    // Primer 20K Dock onboard PT8211 stereo DAC.
    // The PLL produces 48 MHz and its dedicated /24 output produces a
    // 2 MHz BCK, giving a 62.5 kHz stereo frame rate.
    // This matches JT51 at a 4 MHz OPM clock (4 MHz / 64).
    wire clk_48m;
    wire clk_2m;
    wire dac_req;
    assign PA_EN = audio_ready;

    Gowin_rPLL u_audio_pll(
        .clkout(clk_48m),
        .clkoutd(clk_2m),
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

    // One pulse after each complete right/left PT8211 frame.
    reg dac_req_slot;
    always @(posedge clk_2m or negedge rst_n) begin
        if (!rst_n)
            dac_req_slot <= 1'b0;
        else if (dac_req)
            dac_req_slot <= ~dac_req_slot;
    end
    wire dac_frame_tick = dac_req && dac_req_slot;

    wire [14:0] aux_read_addr;
    wire aux_read_req_toggle;

    wire signed [15:0] adpcm_left;
    wire signed [15:0] adpcm_right;
    wire s4_playing;
    msm6258_player u_adpcm(
        .clk(clk_2m),
        .rst_n(rst_n),
        .enable(audio_ready),
        .song_enable(song_enable),
        .s4_n(wav_trig_n),
        .frame_tick(dac_frame_tick),
        .master_volume(volume),
        .aux_read_data(8'd0),
        .aux_read_done_toggle(aux_read_req_toggle),
        .aux_read_addr(aux_read_addr),
        .aux_read_req_toggle(aux_read_req_toggle),
        .startup_done(startup_done),
        .s4_playing(s4_playing),
        .pcm_left(adpcm_left),
        .pcm_right(adpcm_right)
    );

    hdmi_opm_debug u_hdmi_debug(
        .clk27(clk), .rst_n(rst_n),
        .opm_cs_n(jt_cs_n), .opm_wr_n(jt_wr_n), .opm_a0(jt_a0),
        .opm_data(jt_din),
        .tmds_clk_p(O_tmds_clk_p), .tmds_clk_n(O_tmds_clk_n),
        .tmds_data_p(O_tmds_data_p), .tmds_data_n(O_tmds_data_n));

    reg signed [16:0] mixed_left_wide;
    reg signed [16:0] mixed_right_wide;
    reg signed [15:0] song_left;
    reg signed [15:0] song_right;
    always @(*) begin
        mixed_left_wide = {jt_dac_left[15], jt_dac_left} +
                          {adpcm_left[15], adpcm_left};
        mixed_right_wide = {jt_dac_right[15], jt_dac_right} +
                           {adpcm_right[15], adpcm_right};
        if (mixed_left_wide > 17'sd32767)
            song_left = 16'sd32767;
        else if (mixed_left_wide < -17'sd32768)
            song_left = -16'sd32768;
        else
            song_left = mixed_left_wide[15:0];
        if (mixed_right_wide > 17'sd32767)
            song_right = 16'sd32767;
        else if (mixed_right_wide < -17'sd32768)
            song_right = -16'sd32768;
        else
            song_right = mixed_right_wide[15:0];
    end

    // S4 owns the single X68000 ADPCM channel while the voice is active.
    // Keep the MDX timeline running, but output only the S4 sample.
    wire signed [15:0] dac_left = s4_playing ? adpcm_left : song_left;
    wire signed [15:0] dac_right = s4_playing ? adpcm_right : song_right;

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

    // Status: song, S4 voice, audio enabled, configured.
    always @(*) begin
        led = {song_enable, s4_playing, audio_ready, 1'b1};
    end
endmodule
