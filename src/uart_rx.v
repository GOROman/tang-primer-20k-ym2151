module uart_rx #(
    parameter CLK_HZ = 27000000,
    parameter BAUD = 230400
) (
    input wire clk, input wire rst_n, input wire rx,
    output reg [7:0] data, output reg valid
);
    localparam DIV = CLK_HZ / BAUD;
    reg [1:0] sync;
    reg [15:0] count;
    reg [3:0] bitno;
    reg [7:0] shift;
    reg busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync <= 2'b11; count <= 0; bitno <= 0; shift <= 0;
            busy <= 0; data <= 0; valid <= 0;
        end else begin
            sync <= {sync[0], rx};
            valid <= 0;
            if (!busy && !sync[1]) begin
                busy <= 1;
                count <= DIV + DIV/2 - 1;
                bitno <= 0;
            end else if (busy && count != 0) begin
                count <= count - 1'b1;
            end else if (busy) begin
                count <= DIV - 1;
                if (bitno < 8) begin
                    shift[bitno] <= sync[1];
                    bitno <= bitno + 1'b1;
                end else begin
                    busy <= 0;
                    if (sync[1]) begin data <= shift; valid <= 1; end
                end
            end
        end
    end
endmodule
