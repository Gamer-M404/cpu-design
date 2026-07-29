`timescale 1ns / 1ps

`include "defines.vh"

module ICache(
    input  wire         cpu_clk,
    input  wire         cpu_rst,        // high active
    // Interface to CPU
    input  wire         inst_rreq,
    input  wire [31:0]  inst_addr,
    output reg          inst_valid,
    output reg  [31:0]  inst_out,
    // Interface to Read Bus
    input  wire         dev_rrdy,       // device ready to be read
    output reg  [ 3:0]  cpu_ren,        // cpu read mask
    output reg  [31:0]  cpu_raddr,      // cpu read data address
    input  wire         dev_rvalid,     // device data valid
    input  wire [127:0] dev_rdata       // data to be read
);

`ifdef ENABLE_ICACHE

    localparam IDLE    = 2'b00;
    localparam TAG_CHK = 2'b01;
    localparam REFILL  = 2'b10;

    reg  [  1:0] state, nstat;
    reg  [ 31:0] addr_r;
    reg          refill_req_sent;

    wire [133:0] cache_line_r;
    wire [133:0] cache_line_w;
    wire [  5:0] cache_index;
    wire         cache_we;

    // CPU 给 inst_addr，只用到14位
    // -> ICache 拆 tag/index/offset
    // -> 用 index 读 cache_line_r
    // -> 用 valid + tag 判断 hit
    // -> hit 时用 offset 选出 inst_out
    // -> miss 时用 cpu_raddr/cpu_ren 去主存读 dev_rdata
    // -> dev_rvalid 后把 dev_rdata 写入 cache_line_w

    // Cache容量：1KB = 1024B = 8192b
    // Cache块大小：16B = 128b
    // 所以每个Cache能放 128/32 = 4 条指令
    // Cache块数： 1024B / 16B = 64
    // 地址分配：| tag(5) | index(6) | block offset(2) | word offset(2) | byte offset(2) |

    wire [4:0] tag_from_cpu   = addr_r[14:10];
    wire [5:0] index_from_cpu = addr_r[9:4];
    wire [1:0] offset         = addr_r[3:2];

    wire       valid_bit      = cache_line_r[133];
    wire [4:0] tag_from_cache = cache_line_r[132:128];

    // 命中条件：状态为 TAG_CHK，valid_bit 置位，且 tag 匹配
    wire       hit            = (state == TAG_CHK) &&
                                valid_bit &&
                                (tag_from_cache == tag_from_cpu);

    assign cache_we     = (state == REFILL) && dev_rvalid;
    assign cache_index  = (state == IDLE) ? inst_addr[9:4] : index_from_cpu;
    assign cache_line_w = {1'b1, tag_from_cpu, dev_rdata};

    always @(*) begin
        inst_valid = hit;
        case (offset)
            2'b00:   inst_out = cache_line_r[ 31:  0];
            2'b01:   inst_out = cache_line_r[ 63: 32];
            2'b10:   inst_out = cache_line_r[ 95: 64];
            2'b11:   inst_out = cache_line_r[127: 96];
            default: inst_out = 32'h0;
        endcase
    end

    blk_mem_gen_1 U_isram (
        .clka   (cpu_clk),
        .wea    (cache_we),
        .addra  (cache_index),
        .dina   (cache_line_w),
        .douta  (cache_line_r)
    );

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            state <= IDLE;
        else
            state <= nstat;
    end

    always @(*) begin
        case (state)
            IDLE:    nstat = inst_rreq ? TAG_CHK : IDLE;
            TAG_CHK: nstat = hit ? IDLE : REFILL;
            REFILL:  nstat = dev_rvalid ? TAG_CHK : REFILL;
            default: nstat = IDLE;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            addr_r          <= 32'h0;
            refill_req_sent <= 1'b0;
            cpu_ren         <= 4'h0;
            cpu_raddr       <= 32'h0;
        end else begin
            cpu_ren <= 4'h0;

            case (state)
                IDLE: begin
                    refill_req_sent <= 1'b0;
                    if (inst_rreq)
                        addr_r <= inst_addr;
                end
                TAG_CHK: begin
                    refill_req_sent <= 1'b0;
                end
                REFILL: begin
                    if (!refill_req_sent && dev_rrdy) begin
                        cpu_ren         <= 4'hF;
                        // 末尾要填0，因为每次读一个cache块大小的数据
                        cpu_raddr       <= {addr_r[31:4], 4'b0000};
                        refill_req_sent <= 1'b1;
                    end

                    if (dev_rvalid)
                        refill_req_sent <= 1'b0;
                end
                default: begin
                    refill_req_sent <= 1'b0;
                end
            endcase
        end
    end

`else

    localparam IDLE  = 2'b00;
    localparam STAT0 = 2'b01;
    localparam STAT1 = 2'b11;
    reg [1:0] state, nstat;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        state <= cpu_rst ? IDLE : nstat;
    end

    always @(*) begin
        case (state)
            IDLE:    nstat = inst_rreq ? (dev_rrdy ? STAT1 : STAT0) : IDLE;
            STAT0:   nstat = dev_rrdy ? STAT1 : STAT0;
            STAT1:   nstat = dev_rvalid ? IDLE : STAT1;
            default: nstat = IDLE;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            inst_valid <= 1'b0;
            cpu_ren    <= 4'h0;
        end else begin
            case (state)
                IDLE: begin
                    inst_valid <= 1'b0;
                    cpu_ren    <= (inst_rreq & dev_rrdy) ? 4'hF : 4'h0;
                    cpu_raddr  <= inst_rreq ? inst_addr : 32'h0;
                end
                STAT0: begin
                    cpu_ren    <= dev_rrdy ? 4'hF : 4'h0;
                end
                STAT1: begin
                    cpu_ren    <= 4'h0;
                    inst_valid <= dev_rvalid ? 1'b1 : 1'b0;
                    inst_out   <= dev_rvalid ? dev_rdata[31:0] : 32'h0;
                end
                default: begin
                    inst_valid <= 1'b0;
                    cpu_ren    <= 4'h0;
                end
            endcase
        end
    end

`endif

endmodule
