`timescale 1ns / 1ps

`include "defines.vh"

module MREQ (
    input  wire [31:0]  ram_addr,

    input  wire [ 2:0]  ram_rop,
    output reg  [ 3:0]  da_ren,
    output wire [31:0]  da_addr,

    input  wire [ 3:0]  ram_wop,
    input  wire [31:0]  ram_wdata,
    output reg  [ 3:0]  da_wen,
    output reg  [31:0]  da_wdata
);

    wire [1:0] offset = ram_addr[1:0];

    assign da_addr = ram_addr;

    // 产生写访存请求（da_wen、da_wdata）
    always @(*) begin
        // default value
        da_wen   = 4'h0;
        da_wdata = ram_wdata;

        case (ram_wop)
            `RAM_WE_B: begin                            // sb
                // TODO: 根据字节偏移量offset，分别使用ram_wop、ram_wdata产生da_wen、da_wdata
                
            end
            `RAM_WE_H: begin                            // sh
                // TODO: 根据16位半节偏移量offset[1]，分别使用ram_wop、ram_wdata产生da_wen、da_wdata
                
            end
            `RAM_WE_W:                                  // sw
                if (offset == 2'h0) begin
                    da_wen   = ram_wop;
                end
        endcase
    end

    // 产生读访存请求（da_ren）
    always @(*) begin
        if (ram_rop != `RAM_EXT_N) begin
            case (ram_rop)
                // TODO: 根据访存指令类型，判断偏移量offset是否满足对齐条件（字节对齐、半字对齐），
                //       只有在对齐时才能访存
                
                default    : da_ren = (offset == 2'h0) ? 4'hF : 4'h0;                       // lw
            endcase
        end else
            da_ren = 4'h0;
    end

endmodule
