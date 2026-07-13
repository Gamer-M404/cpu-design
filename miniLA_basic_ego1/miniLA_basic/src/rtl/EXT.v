`timescale 1ns / 1ps

`include "defines.vh"

module EXT (
    input  wire [ 2:0]  op,
    input  wire [25:0]  imm,
    output reg  [31:0]  ext
);

always @(*) begin
    case (op)
        `EXT_5  : ext = {27'h0, imm[14:10]};
        `EXT_12U: ext = {20'h0, imm[21:10]};
        `EXT_12 : ext = {{20{imm[21]}}, imm[21:10]};
        `EXT_20 : ext = {imm[24:5], 12'h0};
        `EXT_16 : ext = {{14{imm[25]}}, imm[25:10], 2'h0};
        `EXT_26 : ext = {{4{imm[9]}}, imm[9:0], imm[25:10], 2'h0};
        default : ext = {27'h0, imm[14:10]};
    endcase
end

endmodule
