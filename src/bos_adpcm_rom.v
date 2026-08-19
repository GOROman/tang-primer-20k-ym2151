module bos_adpcm_rom (
    input  wire        clk,
    input  wire [15:0] addr,
    output reg  [7:0]  data
);
    `include "bos_adpcm_meta.vh"
    reg [7:0] mem [0:ADPCM_ROM_BYTES-1];
    initial $readmemh("../music/bos_adpcm.hex", mem);

    always @(posedge clk)
        data <= mem[addr];
endmodule
