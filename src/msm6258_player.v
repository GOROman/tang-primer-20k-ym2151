// One-channel X68000 MSM6258-compatible 4-bit ADPCM player for BOS15.MDX.
// The source rate used by this song is 15.625 kHz.  Four-point linear
// interpolation converts it to the PT8211's 62.5 kHz frame rate.
module msm6258_player (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire               song_enable,
    input  wire               s4_n,
    input  wire               frame_tick,
    input  wire [4:0]         master_volume,
    input  wire [7:0]         aux_read_data,
    input  wire               aux_read_done_toggle,
    output reg [14:0]         aux_read_addr,
    output reg                aux_read_req_toggle,
    output reg                startup_done,
    output reg                s4_playing,
    output wire signed [15:0] pcm_left,
    output wire signed [15:0] pcm_right
);
    `include "bos_adpcm_meta.vh"
    `include "bos_adpcm_events.vh"
    `include "aux_adpcm_meta.vh"

    reg [31:0] frame_count;
    reg [9:0] event_index;
    wire [39:0] event_word = adpcm_event(event_index);
    wire [31:0] event_frame = event_word[39:8];
    wire [1:0] event_kind = event_word[7:6];
    wire [5:0] event_value = event_word[5:0];
    wire event_due = song_enable && event_index < ADPCM_EVENT_COUNT &&
                     frame_count >= event_frame;

    function [31:0] sample_info;
        input [5:0] index;
        begin
            case (index)
                6'd0:  sample_info = {ADPCM_OFS_0,  ADPCM_LEN_0};
                6'd1:  sample_info = {ADPCM_OFS_1,  ADPCM_LEN_1};
                6'd3:  sample_info = {ADPCM_OFS_3,  ADPCM_LEN_3};
                6'd4:  sample_info = {ADPCM_OFS_4,  ADPCM_LEN_4};
                6'd9:  sample_info = {ADPCM_OFS_9,  ADPCM_LEN_9};
                6'd15: sample_info = {ADPCM_OFS_15, ADPCM_LEN_15};
                6'd16: sample_info = {ADPCM_OFS_16, ADPCM_LEN_16};
                6'd17: sample_info = {ADPCM_OFS_17, ADPCM_LEN_17};
                6'd24: sample_info = {ADPCM_OFS_24, ADPCM_LEN_24};
                6'd63: sample_info = {ADPCM_OFS_63, ADPCM_LEN_63};
                default: sample_info = 32'd0;
            endcase
        end
    endfunction

    function [11:0] step_size;
        input [5:0] index;
        begin
            case (index)
                0:step_size=16; 1:step_size=17; 2:step_size=19;
                3:step_size=21; 4:step_size=23; 5:step_size=25;
                6:step_size=28; 7:step_size=31; 8:step_size=34;
                9:step_size=37; 10:step_size=41; 11:step_size=45;
                12:step_size=50; 13:step_size=55; 14:step_size=60;
                15:step_size=66; 16:step_size=73; 17:step_size=80;
                18:step_size=88; 19:step_size=97; 20:step_size=107;
                21:step_size=118; 22:step_size=130; 23:step_size=143;
                24:step_size=157; 25:step_size=173; 26:step_size=190;
                27:step_size=209; 28:step_size=230; 29:step_size=253;
                30:step_size=279; 31:step_size=307; 32:step_size=337;
                33:step_size=371; 34:step_size=408; 35:step_size=449;
                36:step_size=494; 37:step_size=544; 38:step_size=598;
                39:step_size=658; 40:step_size=724; 41:step_size=796;
                42:step_size=876; 43:step_size=963; 44:step_size=1060;
                45:step_size=1166; 46:step_size=1282; 47:step_size=1411;
                default:step_size=1552;
            endcase
        end
    endfunction

    function [13:0] volume_gain;
        input [3:0] value;
        begin
            case (value)
                0:volume_gain=267; 1:volume_gain=410;
                2:volume_gain=492; 3:volume_gain=656;
                4:volume_gain=799; 5:volume_gain=1045;
                6:volume_gain=1270; 7:volume_gain=1536;
                8:volume_gain=2048; 9:volume_gain=2479;
                10:volume_gain=2991; 11:volume_gain=3994;
                12:volume_gain=5325; 13:volume_gain=6431;
                14:volume_gain=8561; default:volume_gain=10363;
            endcase
        end
    endfunction

    reg [15:0] rom_addr;
    wire [7:0] rom_data;
    bos_adpcm_rom u_rom(.clk(clk), .addr(rom_addr), .data(rom_data));
    reg [1:0] aux_done_sync;
    reg aux_done_seen;
    reg [7:0] aux_byte;
    reg aux_byte_valid;

    reg active;
    reg aux_source;
    reg startup_started;
    reg startup_playing;
    reg [2:0] s4_sync;
    reg [2:0] load_wait;
    reg [16:0] nibbles_left;
    reg high_nibble;
    reg [1:0] sample_div;
    reg [3:0] track_volume;
    reg signed [12:0] predictor;
    reg [5:0] step_index;
    reg signed [12:0] interp_prev;
    reg signed [12:0] interp_target;
    reg [1:0] interp_phase;

    wire [7:0] selected_rom_data = aux_source ? aux_byte : rom_data;
    wire [3:0] code = high_nibble ? selected_rom_data[7:4] : selected_rom_data[3:0];
    wire [11:0] step = step_size(step_index);
    wire [12:0] delta_mag = (step >> 3) +
                            (code[0] ? (step >> 2) : 0) +
                            (code[1] ? (step >> 1) : 0) +
                            (code[2] ? step : 0);
    wire signed [13:0] predictor_sum = code[3] ?
        $signed({predictor[12], predictor}) - $signed({1'b0, delta_mag}) :
        $signed({predictor[12], predictor}) + $signed({1'b0, delta_mag});
    wire signed [12:0] predictor_next = predictor_sum > 14'sd2047 ? 13'sd2047 :
                                        predictor_sum < -14'sd2048 ? -13'sd2048 :
                                        predictor_sum[12:0];
    wire signed [6:0] index_sum = $signed({1'b0, step_index}) +
        (code[2:0] < 4 ? -7'sd1 :
         code[2:0] == 4 ? 7'sd2 :
         code[2:0] == 5 ? 7'sd4 :
         code[2:0] == 6 ? 7'sd6 : 7'sd8);
    wire [5:0] index_next = index_sum < 0 ? 0 :
                            index_sum > 48 ? 48 : index_sum[5:0];

    wire signed [13:0] interp_delta =
        $signed({interp_target[12], interp_target}) -
        $signed({interp_prev[12], interp_prev});
    wire signed [15:0] interp_product = interp_delta * $signed({1'b0, interp_phase});
    wire signed [15:0] interpolated_wide =
        $signed({interp_prev[12], interp_prev}) + (interp_product >>> 2);
    wire signed [13:0] interpolated = interpolated_wide[13:0];
    wire signed [28:0] track_product = interpolated * $signed({1'b0, volume_gain(track_volume)});
    wire signed [18:0] track_pcm = track_product >>> 10;
    // The MSM6258 decoder produces a signed 12-bit estimate.  Expand it to
    // the PT8211's 16-bit range before applying the shared master volume.
    wire signed [22:0] track_pcm_16 = track_pcm <<< 4;
    wire signed [28:0] master_product = track_pcm_16 * $signed({1'b0, master_volume});
    wire signed [28:0] scaled_pcm_wide = master_product / 29'sd20;
    wire signed [19:0] scaled_pcm = scaled_pcm_wide[19:0];
    wire signed [15:0] clipped_pcm = scaled_pcm > 20'sd32767 ? 16'sd32767 :
                                     scaled_pcm < -20'sd32768 ? -16'sd32768 :
                                     scaled_pcm[15:0];
    assign pcm_left = clipped_pcm;
    assign pcm_right = clipped_pcm;

    wire [31:0] selected_info = sample_info(event_value);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !enable) begin
            frame_count <= 0;
            event_index <= 0;
            active <= 0;
            aux_source <= 0;
            aux_read_addr <= 0;
            aux_read_req_toggle <= 0;
            aux_done_sync <= 0;
            aux_done_seen <= 0;
            aux_byte <= 0;
            aux_byte_valid <= 0;
            startup_started <= 0;
            startup_playing <= 0;
            startup_done <= 0;
            s4_playing <= 0;
            s4_sync <= 3'b111;
            load_wait <= 0;
            rom_addr <= 0;
            nibbles_left <= 0;
            high_nibble <= 0;
            sample_div <= 0;
            track_volume <= 4'd8;
            predictor <= 0;
            step_index <= 0;
            interp_prev <= 0;
            interp_target <= 0;
            interp_phase <= 0;
        end else begin
            aux_done_sync <= {aux_done_sync[0], aux_read_done_toggle};
            if (aux_done_sync[1] != aux_done_seen) begin
                aux_done_seen <= aux_done_sync[1];
                aux_byte <= aux_read_data;
                aux_byte_valid <= 1'b1;
            end
            s4_sync <= {s4_sync[1:0], s4_n};
            if (frame_tick && song_enable)
                frame_count <= frame_count + 1'b1;
            if (load_wait != 0)
                load_wait <= load_wait - 1'b1;

            if (!startup_started) begin
                startup_started <= 1'b1;
                startup_playing <= 1'b0;
                startup_done <= 1'b1;
                s4_playing <= 1'b0;
                aux_source <= 1'b0;
                active <= 1'b0;
            end else if (event_due) begin
                event_index <= event_index + 1'b1;
                // The X68000 has one ADPCM channel.  While the user-triggered
                // S4 voice owns it, consume scheduled song events without
                // letting them cut the voice off midway.
                if (!(aux_source && active)) case (event_kind)
                    2'd0: begin // PLAY
                        aux_source <= 1'b0;
                        rom_addr <= selected_info[31:16];
                        nibbles_left <= {selected_info[15:0], 1'b0};
                        high_nibble <= 0;
                        sample_div <= 0;
                        predictor <= 0;
                        step_index <= 0;
                        interp_prev <= 0;
                        interp_target <= 0;
                        interp_phase <= 0;
                        load_wait <= 3;
                        active <= selected_info[15:0] != 0;
                    end
                    2'd1: begin // STOP
                        active <= 0;
                        interp_prev <= interp_target;
                        interp_target <= 0;
                        interp_phase <= 0;
                    end
                    2'd2: track_volume <= event_value[3:0];
                    default: ;
                endcase
            end else if (frame_tick) begin
                if (interp_phase != 3)
                    interp_phase <= interp_phase + 1'b1;
                if (active && load_wait == 0 && (!aux_source || aux_byte_valid)) begin
                    sample_div <= sample_div + 1'b1;
                    if (sample_div == 0) begin
                        predictor <= predictor_next;
                        step_index <= index_next;
                        interp_prev <= interp_target;
                        interp_target <= predictor_next;
                        interp_phase <= 0;
                        nibbles_left <= nibbles_left - 1'b1;
                        if (high_nibble) begin
                            high_nibble <= 0;
                            if (aux_source)
                            begin
                                aux_read_addr <= aux_read_addr + 1'b1;
                                aux_read_req_toggle <= ~aux_read_req_toggle;
                                aux_byte_valid <= 1'b0;
                            end
                            else
                                rom_addr <= rom_addr + 1'b1;
                        end else begin
                            high_nibble <= 1;
                        end
                        if (nibbles_left == 1) begin
                            active <= 0;
                            s4_playing <= 1'b0;
                            interp_prev <= 0;
                            interp_target <= 0;
                            interp_phase <= 0;
                            if (startup_playing) begin
                                startup_playing <= 1'b0;
                                startup_done <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
