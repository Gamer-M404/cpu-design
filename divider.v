`timescale 1ns / 1ps

module divider #(
    parameter WIDTH = 32
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire [WIDTH-1:0]     x,          // 原码: {符号, 绝对值} (signed) 或 {0, 值} (unsigned)
    input  wire [WIDTH-1:0]     y,
    input  wire                 start,
    output reg  [WIDTH-1:0]     z,          // 商
    output reg  [WIDTH-1:0]     r,          // 余数
    output reg                  busy
);

    // 绝对值位宽 = WIDTH - 1 (去掉符号位)
    localparam MAG_WID = WIDTH - 1;

    localparam IDLE = 2'b00;
    localparam CALC = 2'b01;
    localparam DONE = 2'b10;

    reg [1:0]                       state;
    reg [$clog2(MAG_WID+1)-1:0]     count;
    reg                             x_sign, y_sign;     // 符号位
    reg [MAG_WID-1:0]               divisor_mag;        // 除数绝对值
    reg [MAG_WID:0]                 remainder;          // 余数，多 1 位检测借位
    reg [MAG_WID-1:0]               quotient;           // 商绝对值

    // --- 组合逻辑 ---

    wire [MAG_WID:0]   rem_shifted = {remainder[MAG_WID-1:0], quotient[MAG_WID-1]};
    wire [MAG_WID-1:0] quo_shifted = {quotient[MAG_WID-2:0], 1'b0};
    wire [MAG_WID:0]   sub_result  = rem_shifted - {1'b0, divisor_mag};
    wire               negative    = sub_result[MAG_WID];
    wire [MAG_WID:0]   next_rem    = negative ? (sub_result + {1'b0, divisor_mag}) : sub_result;
    wire [MAG_WID-1:0] next_quo    = negative ? {quo_shifted[MAG_WID-1:1], 1'b0}
                                               : {quo_shifted[MAG_WID-1:1], 1'b1};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= IDLE;
            count       <= 0;
            x_sign      <= 0;
            y_sign      <= 0;
            divisor_mag <= 0;
            remainder   <= 0;
            quotient    <= 0;
            z           <= 0;
            r           <= 0;
            busy        <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        if (y[MAG_WID-1:0] == 0) begin
                            // 除零: 商 = 全 1，余数 = x
                            z    <= {WIDTH{1'b1}};
                            r    <= x;
                        end else begin
                            // 提取符号位
                            x_sign      <= x[WIDTH-1];
                            y_sign      <= y[WIDTH-1];
                            // 取绝对值 (低 MAG_WID 位)
                            divisor_mag <= y[MAG_WID-1:0];
                            remainder   <= {(MAG_WID+1){1'b0}};
                            quotient    <= x[MAG_WID-1:0];
                            // 多周期状态
                            state       <= CALC;
                            count       <= 0;
                            busy        <= 1'b1;
                        end
                    end
                end

                CALC: begin
                    if (count == MAG_WID) begin
                        state <= DONE;
                    end else begin
                        count     <= count + 1'b1;
                        remainder <= next_rem;
                        quotient  <= next_quo;
                    end
                end

                DONE: begin
                    // 商的符号 = 被除数符号 ^ 除数符号
                    // 余数的符号 = 被除数符号
                    z    <= {x_sign ^ y_sign, quotient};
                    r    <= {x_sign, remainder[MAG_WID-1:0]};
                    busy <= 1'b0;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
