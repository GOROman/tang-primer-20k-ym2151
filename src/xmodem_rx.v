module xmodem_rx (
    input wire clk, input wire rst_n, input wire rx,
    input wire upload_ready, output reg [7:0] upload_byte,
    output reg upload_valid, output reg loaded,
    output reg command_valid, output reg [7:0] command_data,
    output wire tx
);
    wire [7:0] rx_data; wire rx_valid;
    uart_rx u_rx(.clk(clk), .rst_n(rst_n), .rx(rx), .data(rx_data), .valid(rx_valid));
    reg tx_start; wire tx_busy; reg [7:0] tx_data;
    uart_tx u_tx(.clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
                 .tx(tx), .busy(tx_busy));
    reg [7:0] mem [0:1023];
    reg [3:0] state; reg [7:0] seq; reg [7:0] packet_seq;
    reg [10:0] count; reg [10:0] packet_last; reg [15:0] crc; reg [7:0] crc_hi;
    reg [24:0] nak_timer;
    reg transfer_started;
    localparam WAIT_START=0, WAIT_SEQ=1, WAIT_INV=2, DATA=3, CRC_HI=4,
               CRC_LO=5, SEND=6, WAIT_UPLOAD_BUSY=7,
               WAIT_UPLOAD_READY=8;
    function [15:0] crc_byte;
        input [15:0] c; input [7:0] d; integer i; reg [15:0] x;
        begin x=c ^ {d,8'h00}; for(i=0;i<8;i=i+1) x=x[15] ? ((x<<1)^16'h1021) : (x<<1); crc_byte=x; end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=WAIT_START; seq<=0; packet_seq<=0; count<=0; crc<=0;
            crc_hi<=0; upload_byte<=0; upload_valid<=0; loaded<=0;
            tx_start<=1'b0; tx_data<=8'h15; nak_timer<=0;
            command_valid<=1'b0; command_data<=8'd0;
            transfer_started<=1'b0;
        end else begin
            tx_start<=1'b0; upload_valid<=1'b0; command_valid<=1'b0;
            if (nak_timer != 0) nak_timer <= nak_timer - 1'b1;
            case(state)
                WAIT_START: begin
                    if (rx_valid && (rx_data=="P" || rx_data=="p" ||
                                     rx_data=="R" || rx_data=="r" ||
                                     rx_data=="S" || rx_data=="s")) begin
                        command_data <= rx_data;
                        command_valid <= 1'b1;
                        if (!tx_busy) begin
                            tx_data <= "K";
                            tx_start <= 1'b1;
                        end
                    end else if (rx_valid && (rx_data==8'h01 || rx_data==8'h02)) begin
                        packet_last <= (rx_data==8'h01) ? 11'd127 : 11'd1023;
                        transfer_started <= 1'b1;
                        state<=WAIT_SEQ;
                    end
                    else if (!transfer_started && nak_timer==0 && !tx_busy) begin
                        tx_data<=8'h15; tx_start<=1'b1; nak_timer<=25'd26_999_999;
                    end
                end
                WAIT_SEQ: if(rx_valid) begin packet_seq<=rx_data; state<=WAIT_INV; end
                WAIT_INV: if(rx_valid) begin
                    if (rx_data != ~packet_seq) begin tx_data<=8'h15; tx_start<=1; state<=WAIT_START; end
                    else begin count<=0; crc<=0; state<=DATA; end
                end
                DATA: if(rx_valid) begin
                    mem[count[9:0]]<=rx_data; crc<=crc_byte(crc,rx_data);
                    if(count==packet_last) state<=CRC_HI; else count<=count+1'b1;
                end
                CRC_HI: if(rx_valid) begin crc_hi<=rx_data; state<=CRC_LO; end
                CRC_LO: if(rx_valid) begin
                    if ((({crc_hi,rx_data}==crc) || ({rx_data,crc_hi}==crc)) && packet_seq==seq) begin
                        count<=0; state<=SEND;
                    end
                    else if ((({crc_hi,rx_data}==crc) || ({rx_data,crc_hi}==crc)) &&
                             packet_seq==(seq-1'b1)) begin
                        // The previous ACK may have been lost.  The packet is
                        // already in DDR, so acknowledge the duplicate without
                        // writing it a second time.
                        tx_data<=8'h06; tx_start<=1'b1; state<=WAIT_START;
                    end
                    else begin tx_data<=8'h15; tx_start<=1; state<=WAIT_START; end
                end
                SEND: if(upload_ready) begin
                    // Present one byte for a full clock.  Do not advance the
                    // packet index until the DDR toggle handshake has gone
                    // busy and returned ready.
                    upload_byte<=mem[count[9:0]];
                    upload_valid<=1'b1;
                    state<=WAIT_UPLOAD_BUSY;
                end
                WAIT_UPLOAD_BUSY: begin
                    if(!upload_ready)
                        state<=WAIT_UPLOAD_READY;
                end
                WAIT_UPLOAD_READY: begin
                    if(upload_ready) begin
                        if(count==packet_last) begin
                            tx_data<=8'h06;
                            tx_start<=1'b1;
                            seq<=seq+1'b1;
                            state<=WAIT_START;
                        end else begin
                            count<=count+1'b1;
                            state<=SEND;
                        end
                    end
                end
                default: state<=WAIT_START;
            endcase
        end
    end
endmodule
