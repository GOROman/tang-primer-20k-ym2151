module uart_tx #(
    parameter CLK_HZ = 27000000,
    parameter BAUD = 230400
) (
    input wire clk, input wire rst_n, input wire start, input wire [7:0] data,
    output reg tx, output reg busy
);
    localparam DIV = CLK_HZ / BAUD;
    reg [15:0] count;
    reg [3:0] bitno;
    reg [9:0] frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin tx<=1'b1; busy<=1'b0; count<=0; bitno<=0; frame<=0; end
        else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                frame <= {1'b1, data, 1'b0};
                busy <= 1'b1; bitno <= 0; count <= DIV-1;
                tx <= 1'b0;
            end
        end else if (count != 0) count <= count - 1'b1;
        else begin
            count <= DIV-1;
            if (bitno == 9) begin busy<=1'b0; tx<=1'b1; end
            else begin bitno<=bitno+1'b1; tx<=frame[bitno+1]; end
        end
    end
endmodule
