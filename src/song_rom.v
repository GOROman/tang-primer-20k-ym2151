module song_rom (
    input  wire        clk,
    input  wire [15:0] addr,
    output reg  [7:0]  data
);
    `include "song_meta.vh"
    reg [7:0] mem [0:SONG_PACKED_BYTES-1];

    initial $readmemh("../music/bos_flash_lzss.hex", mem);

    always @(posedge clk)
        data <= mem[addr];
endmodule
