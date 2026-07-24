`timescale 1ns / 1ps

// 通用流水线寄存器
// stall=1: 保持当前值
// flush=1: 清零 (优先级: rst > flush > stall)
module pipeline_reg #(
    parameter WIDTH = 32
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 stall,
    input  wire                 flush,
    input  wire [WIDTH-1:0]     din,
    output reg  [WIDTH-1:0]     dout
);

    always @(posedge clk or posedge rst) begin
        if (rst)
            dout <= {WIDTH{1'b0}};
        else if (flush)
            dout <= {WIDTH{1'b0}};
        else if (!stall)
            dout <= din;
    end

endmodule
