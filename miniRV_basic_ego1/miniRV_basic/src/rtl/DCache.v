`timescale 1ns / 1ps

`include "defines.vh"

// Main memory: 32KB, effective address bits are addr[14:0].
// Cache size: 1KB. Block size: 16B = 128bit = 4 words.
// Line count: 1KB / 16B = 64.

module DCache(
    input  wire         cpu_clk,
    input  wire         cpu_rst,        // high active
    // Interface to CPU
    input  wire [ 3:0]  data_ren,
    input  wire [31:0]  data_addr,
    output reg          data_valid,
    output reg  [31:0]  data_rdata,
    input  wire [ 3:0]  data_wen,
    input  wire [31:0]  data_wdata,
    output reg          data_wresp,
    // Interface to Write Bus
    input  wire         dev_wrdy,       // device ready to be written (device: main memory or peripherals)
    output reg  [ 3:0]  cpu_wen,        // cpu write enable
    output reg  [31:0]  cpu_waddr,      // cpu write data address
    output reg  [31:0]  cpu_wdata,      // cpu write data
    // Interface to Read Bus
    input  wire         dev_rrdy,       // device ready to be read
    output reg  [ 3:0]  cpu_ren,        // cpu read mask
    output reg  [31:0]  cpu_raddr,      // cpu read data address
    input  wire         dev_rvalid,     // device data valid
    input  wire [127:0] dev_rdata       // data to be read
);

    // Peripherals access should be uncached.
    wire uncached = (data_addr[31:16] == 16'hFFFF) &&
                    ((data_ren != 4'h0) || (data_wen != 4'h0));

`ifdef ENABLE_DCACHE

    localparam R_IDLE    = 2'b00;
    localparam R_TAG_CHK = 2'b01;
    localparam R_REFILL  = 2'b10;
    localparam R_UNCACHE = 2'b11;

    localparam W_IDLE    = 2'b00;
    localparam W_TAG_CHK = 2'b01;
    localparam W_BUS_REQ = 2'b10;
    localparam W_BUS_WAIT= 2'b11;

    reg [1:0]  r_state, r_nstat;
    reg [31:0] r_addr;
    reg [3:0]  r_ren;
    reg        r_uncached;
    reg        r_req_sent;

    reg [1:0]  w_state, w_nstat;
    reg [31:0] w_addr;
    reg [31:0] w_data;
    reg [3:0]  w_wen;
    reg        w_uncached;
    reg        w_req_sent;

    wire [31:0] cache_addr    = (w_state != W_IDLE) ? w_addr : r_addr;
    wire [ 4:0] tag_from_cpu   = cache_addr[14:10];
    wire [ 5:0] index_from_cpu = cache_addr[9:4];
    wire [ 1:0] offset         = cache_addr[3:2];

    wire [133:0] cache_line_r;
    wire [133:0] cache_line_w;
    wire [  5:0] cache_index;
    wire         cache_we;

    wire       valid_bit      = cache_line_r[133];
    wire [4:0] tag_from_cache = cache_line_r[132:128];

    wire hit_r = (r_state == R_TAG_CHK) &&
                 valid_bit &&
                 (tag_from_cache == r_addr[14:10]);

    wire hit_w = (w_state == W_TAG_CHK) &&
                 !w_uncached &&
                 valid_bit &&
                 (tag_from_cache == w_addr[14:10]);

    reg [31:0] cache_word_r;
    reg [127:0] wr_cache_data;

    always @(*) begin
        case (r_addr[3:2])
            2'b00:   cache_word_r = cache_line_r[ 31:  0];
            2'b01:   cache_word_r = cache_line_r[ 63: 32];
            2'b10:   cache_word_r = cache_line_r[ 95: 64];
            2'b11:   cache_word_r = cache_line_r[127: 96];
            default: cache_word_r = 32'h0;
        endcase

        data_valid = hit_r || ((r_state == R_UNCACHE) && dev_rvalid);
        data_rdata = ((r_state == R_UNCACHE) && dev_rvalid) ? dev_rdata[31:0] : cache_word_r;
    end

    assign cache_we = ((r_state == R_REFILL) && dev_rvalid) ||
                      ((w_state == W_TAG_CHK) && hit_w);

    assign cache_index = ((r_state == R_REFILL) || (r_state == R_TAG_CHK)) ? r_addr[9:4] :
                         ((w_state != W_IDLE) ? w_addr[9:4] : data_addr[9:4]);

    assign cache_line_w = ((w_state == W_TAG_CHK) && hit_w) ?
                          {1'b1, w_addr[14:10], wr_cache_data} :
                          {1'b1, r_addr[14:10], dev_rdata};

    blk_mem_gen_1 U_dsram (
        .clka   (cpu_clk),
        .wea    (cache_we),
        .addra  (cache_index),
        .dina   (cache_line_w),
        .douta  (cache_line_r)
    );

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            r_state <= R_IDLE;
        else
            r_state <= r_nstat;
    end

    always @(*) begin
        case (r_state)
            R_IDLE:    r_nstat = (|data_ren) ? (uncached ? R_UNCACHE : R_TAG_CHK) : R_IDLE;
            R_TAG_CHK: r_nstat = hit_r ? R_IDLE : R_REFILL;
            R_REFILL:  r_nstat = dev_rvalid ? R_TAG_CHK : R_REFILL;
            R_UNCACHE: r_nstat = dev_rvalid ? R_IDLE : R_UNCACHE;
            default:   r_nstat = R_IDLE;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            r_addr     <= 32'h0;
            r_ren      <= 4'h0;
            r_uncached <= 1'b0;
            r_req_sent <= 1'b0;
            cpu_ren    <= 4'h0;
            cpu_raddr  <= 32'h0;
        end else begin
            cpu_ren <= 4'h0;

            case (r_state)
                R_IDLE: begin
                    r_req_sent <= 1'b0;
                    if (|data_ren) begin
                        r_addr     <= data_addr;
                        r_ren      <= data_ren;
                        r_uncached <= uncached;
                    end
                end
                R_TAG_CHK: begin
                    r_req_sent <= 1'b0;
                end
                R_REFILL: begin
                    if (!r_req_sent && dev_rrdy) begin
                        cpu_ren    <= 4'hF;
                        cpu_raddr  <= {r_addr[31:4], 4'b0000};
                        r_req_sent <= 1'b1;
                    end
                    if (dev_rvalid)
                        r_req_sent <= 1'b0;
                end
                R_UNCACHE: begin
                    if (!r_req_sent && dev_rrdy) begin
                        cpu_ren    <= r_ren;
                        cpu_raddr  <= r_addr;
                        r_req_sent <= 1'b1;
                    end
                    if (dev_rvalid)
                        r_req_sent <= 1'b0;
                end
                default: begin
                    r_req_sent <= 1'b0;
                end
            endcase
        end
    end

    wire wr_resp = dev_wrdy && (cpu_wen == 4'h0);

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            w_state <= W_IDLE;
        else
            w_state <= w_nstat;
    end

    always @(*) begin
        case (w_state)
            W_IDLE:     w_nstat = (|data_wen) ? (uncached ? W_BUS_REQ : W_TAG_CHK) : W_IDLE;
            W_TAG_CHK:  w_nstat = dev_wrdy ? W_BUS_WAIT : W_BUS_REQ;
            W_BUS_REQ:  w_nstat = dev_wrdy ? W_BUS_WAIT : W_BUS_REQ;
            W_BUS_WAIT: w_nstat = wr_resp ? W_IDLE : W_BUS_WAIT;
            default:    w_nstat = W_IDLE;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            w_addr      <= 32'h0;
            w_data      <= 32'h0;
            w_wen       <= 4'h0;
            w_uncached  <= 1'b0;
            w_req_sent  <= 1'b0;
            cpu_wen     <= 4'h0;
            cpu_waddr   <= 32'h0;
            cpu_wdata   <= 32'h0;
            data_wresp  <= 1'b0;
        end else begin
            cpu_wen    <= 4'h0;
            data_wresp <= 1'b0;

            case (w_state)
                W_IDLE: begin
                    w_req_sent <= 1'b0;
                    if (|data_wen) begin
                        w_addr     <= data_addr;
                        w_data     <= data_wdata;
                        w_wen      <= data_wen;
                        w_uncached <= uncached;
                    end
                end
                W_TAG_CHK: begin
                    if (dev_wrdy) begin
                        cpu_wen    <= w_wen;
                        cpu_waddr  <= w_addr;
                        cpu_wdata  <= w_data;
                        w_req_sent <= 1'b1;
                    end
                end
                W_BUS_REQ: begin
                    if (!w_req_sent && dev_wrdy) begin
                        cpu_wen    <= w_wen;
                        cpu_waddr  <= w_addr;
                        cpu_wdata  <= w_data;
                        w_req_sent <= 1'b1;
                    end
                end
                W_BUS_WAIT: begin
                    if (wr_resp) begin
                        data_wresp <= 1'b1;
                        w_req_sent <= 1'b0;
                    end
                end
                default: begin
                    w_req_sent <= 1'b0;
                end
            endcase
        end
    end

    always @(*) begin
        wr_cache_data = cache_line_r[127:0];

        case (w_addr[3:2])
            2'b00: begin
                if (w_wen[0]) wr_cache_data[  7:  0] = w_data[ 7: 0];
                if (w_wen[1]) wr_cache_data[ 15:  8] = w_data[15: 8];
                if (w_wen[2]) wr_cache_data[ 23: 16] = w_data[23:16];
                if (w_wen[3]) wr_cache_data[ 31: 24] = w_data[31:24];
            end
            2'b01: begin
                if (w_wen[0]) wr_cache_data[ 39: 32] = w_data[ 7: 0];
                if (w_wen[1]) wr_cache_data[ 47: 40] = w_data[15: 8];
                if (w_wen[2]) wr_cache_data[ 55: 48] = w_data[23:16];
                if (w_wen[3]) wr_cache_data[ 63: 56] = w_data[31:24];
            end
            2'b10: begin
                if (w_wen[0]) wr_cache_data[ 71: 64] = w_data[ 7: 0];
                if (w_wen[1]) wr_cache_data[ 79: 72] = w_data[15: 8];
                if (w_wen[2]) wr_cache_data[ 87: 80] = w_data[23:16];
                if (w_wen[3]) wr_cache_data[ 95: 88] = w_data[31:24];
            end
            2'b11: begin
                if (w_wen[0]) wr_cache_data[103: 96] = w_data[ 7: 0];
                if (w_wen[1]) wr_cache_data[111:104] = w_data[15: 8];
                if (w_wen[2]) wr_cache_data[119:112] = w_data[23:16];
                if (w_wen[3]) wr_cache_data[127:120] = w_data[31:24];
            end
            default: begin
                wr_cache_data = cache_line_r[127:0];
            end
        endcase
    end

`else

    localparam R_IDLE  = 2'b00;
    localparam R_STAT0 = 2'b01;
    localparam R_STAT1 = 2'b11;
    reg [1:0] r_state, r_nstat;
    reg [3:0] ren_r;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        r_state <= cpu_rst ? R_IDLE : r_nstat;
    end

    always @(*) begin
        case (r_state)
            R_IDLE:  r_nstat = (|data_ren) ? (dev_rrdy ? R_STAT1 : R_STAT0) : R_IDLE;
            R_STAT0: r_nstat = dev_rrdy ? R_STAT1 : R_STAT0;
            R_STAT1: r_nstat = dev_rvalid ? R_IDLE : R_STAT1;
            default: r_nstat = R_IDLE;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            data_valid <= 1'b0;
            cpu_ren    <= 4'h0;
        end else begin
            case (r_state)
                R_IDLE: begin
                    data_valid <= 1'b0;

                    if (|data_ren) begin
                        if (dev_rrdy)
                            cpu_ren <= data_ren;
                        else
                            ren_r   <= data_ren;

                        cpu_raddr <= data_addr;
                    end else
                        cpu_ren   <= 4'h0;
                end
                R_STAT0: begin
                    cpu_ren    <= dev_rrdy ? ren_r : 4'h0;
                end
                R_STAT1: begin
                    cpu_ren    <= 4'h0;
                    data_valid <= dev_rvalid ? 1'b1 : 1'b0;
                    data_rdata <= dev_rvalid ? dev_rdata : 32'h0;
                end
                default: begin
                    data_valid <= 1'b0;
                    cpu_ren    <= 4'h0;
                end
            endcase
        end
    end

    localparam W_IDLE  = 2'b00;
    localparam W_STAT0 = 2'b01;
    localparam W_STAT1 = 2'b11;
    reg  [1:0] w_state, w_nstat;
    reg  [3:0] wen_r;
    wire       wr_resp = dev_wrdy & (cpu_wen == 4'h0) ? 1'b1 : 1'b0;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        w_state <= cpu_rst ? W_IDLE : w_nstat;
    end

    always @(*) begin
        case (w_state)
            W_IDLE:  w_nstat = (|data_wen) ? (dev_wrdy ? W_STAT1 : W_STAT0) : W_IDLE;
            W_STAT0: w_nstat = dev_wrdy ? W_STAT1 : W_STAT0;
            W_STAT1: w_nstat = wr_resp ? W_IDLE : W_STAT1;
            default: w_nstat = W_IDLE;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            data_wresp <= 1'b0;
            cpu_wen    <= 4'h0;
        end else begin
            case (w_state)
                W_IDLE: begin
                    data_wresp <= 1'b0;

                    if (|data_wen) begin
                        if (dev_wrdy)
                            cpu_wen <= data_wen;
                        else
                            wen_r   <= data_wen;

                        cpu_waddr  <= data_addr;
                        cpu_wdata  <= data_wdata;
                    end else
                        cpu_wen    <= 4'h0;
                end
                W_STAT0: begin
                    cpu_wen    <= dev_wrdy ? wen_r : 4'h0;
                end
                W_STAT1: begin
                    cpu_wen    <= 4'h0;
                    data_wresp <= wr_resp ? 1'b1 : 1'b0;
                end
                default: begin
                    data_wresp <= 1'b0;
                    cpu_wen    <= 4'h0;
                end
            endcase
        end
    end

`endif

endmodule
