// Low-level PT8211 path check: play C4 through C5 after PA_EN becomes active.
// The output is deliberately limited to 5% full-scale so the diagnostic tone
// cannot be used as a high-level audio source.
module dac_scale_test (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              enable,
    input  wire              req,
    output reg               active,
    output wire signed [15:0] pcm_left,
    output wire signed [15:0] pcm_right
);
    localparam [15:0] NOTE_FRAMES = 16'd15625; // 250 ms at 62.5 kHz
    localparam signed [15:0] TEST_AMPLITUDE = 16'sd819; // 2.5% of full scale

    // DDS phase increments for C4, D4, E4, F4, G4, A4, B4, C5.
    reg [15:0] phase_step;
    reg signed [15:0] pcm;
    reg [15:0] phase;
    reg [15:0] note_frames;
    reg [3:0]  note_index;
    reg        req_slot;
    reg        enable_sync1;
    reg        enable_sync2;
    reg        started;

    // C4..F4 play only on the left; G4..C5 play only on the right.
    assign pcm_left  = (note_index < 4) ? pcm : 16'sd0;
    assign pcm_right = (note_index < 4) ? 16'sd0 : pcm;

    always @(*) begin
        case (note_index)
            4'd0: phase_step = 16'd274;
            4'd1: phase_step = 16'd308;
            4'd2: phase_step = 16'd346;
            4'd3: phase_step = 16'd366;
            4'd4: phase_step = 16'd411;
            4'd5: phase_step = 16'd461;
            4'd6: phase_step = 16'd518;
            default: phase_step = 16'd549;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_sync1 <= 1'b0;
            enable_sync2 <= 1'b0;
            started <= 1'b0;
            active <= 1'b0;
            pcm <= 16'sd0;
            phase <= 16'd0;
            note_frames <= 16'd0;
            note_index <= 4'd0;
            req_slot <= 1'b0;
        end else begin
            enable_sync1 <= enable;
            enable_sync2 <= enable_sync1;

            if (!enable_sync2) begin
                started <= 1'b0;
                active <= 1'b0;
                pcm <= 16'sd0;
                phase <= 16'd0;
                note_frames <= 16'd0;
                note_index <= 4'd0;
                req_slot <= 1'b0;
            end else if (!started) begin
                started <= 1'b1;
                active <= 1'b1;
                pcm <= TEST_AMPLITUDE;
                phase <= 16'd0;
                note_frames <= 16'd0;
                note_index <= 4'd0;
                req_slot <= 1'b0;
            end else if (req) begin
                // PT8211 requests right and left slots separately.  Update
                // after the second slot so the next frame sees one sample
                // for both channels.
                if (req_slot) begin
                    req_slot <= 1'b0;
                    phase <= phase + phase_step;
                    if (phase[15])
                        pcm <= TEST_AMPLITUDE;
                    else
                        pcm <= -TEST_AMPLITUDE;

                    if (note_frames == NOTE_FRAMES - 1'b1) begin
                        note_frames <= 16'd0;
                        if (note_index == 4'd7) begin
                            active <= 1'b0;
                            pcm <= 16'sd0;
                        end else begin
                            note_index <= note_index + 1'b1;
                        end
                    end else begin
                        note_frames <= note_frames + 1'b1;
                    end
                end else begin
                    req_slot <= 1'b1;
                end
            end
        end
    end
endmodule
