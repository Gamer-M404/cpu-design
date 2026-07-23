`timescale 1ns / 1ps

module multiplier #(
    parameter WIDTH = 32
)(
    input  wire        clk,
	input  wire        rst,
	input  wire [WIDTH-1:0] x,
	input  wire [WIDTH-1:0] y,
	input  wire        start,
	output reg  [O_WID-1:0] z,
	output wire        busy 
);

	localparam O_WID = 2*WIDTH;

     // 状态定义
    localparam IDLE = 2'b00;
    localparam CALC = 2'b01;
    localparam DONE = 2'b10;

    reg [1:0]  state;
    // 计数器位宽：$clog2(WIDTH+1) 自动计算所需的最小位宽
    reg [$clog2(WIDTH+1)-1:0] count; 
    
    reg [WIDTH-1:0]   reg_x;     // 锁存被乘数
    // temp_z 结构: [A部分(WIDTH位), Q部分(WIDTH位), Q_-1(1位)]，总共 2*WIDTH + 1 位
    reg [WIDTH*2:0]   temp_z;    

    // 忙信号输出
    assign busy = (state != IDLE);

    // 组合逻辑：计算 A 部分加减 x 的结果（带符号位扩展，多出 1 位用于处理进位/移位）
    wire [WIDTH:0] sum_next = {temp_z[WIDTH*2], temp_z[WIDTH*2:WIDTH+1]} + {reg_x[WIDTH-1], reg_x};
    wire [WIDTH:0] sub_next = {temp_z[WIDTH*2], temp_z[WIDTH*2:WIDTH+1]} - {reg_x[WIDTH-1], reg_x};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= IDLE;
            count   <= 0;
            z       <= 0;
            temp_z  <= 0;
            reg_x   <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        state   <= CALC;
                        count   <= 0;
                        reg_x   <= x;
                        // 初始化 temp_z: A=0, Q=y, Q_-1=0
                        temp_z  <= { {WIDTH{1'b0}}, y, 1'b0 };
                    end
                end

                CALC: begin
                    if (count == WIDTH) begin
                        state <= DONE;
                    end else begin
                        count <= count + 1'b1;
                        // Booth 算法判断 temp_z[1:0]
                        case (temp_z[1:0])
                            2'b01: begin // 加 x 并右移
                                // {加法结果的前 WIDTH 位, Q 部分的前 WIDTH 位}
                                temp_z <= {sum_next, temp_z[WIDTH:1]};
                            end
                            2'b10: begin // 减 x 并右移
                                temp_z <= {sub_next, temp_z[WIDTH:1]};
                            end
                            default: begin // 00 或 11，仅算术右移
                                temp_z <= $signed(temp_z) >>> 1;
                            end
                        endcase
                    end
                end

                DONE: begin
                    z     <= temp_z[WIDTH*2:1]; // 提取乘积部分
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    
endmodule
