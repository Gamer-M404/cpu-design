`timescale 1ns / 1ps

`include "defines.vh"

module axi_master(
    input  wire         aclk,
    input  wire         areset,     // high active

    // ICache Interface
    output reg          ic_dev_rrdy,
    input  wire [ 3:0]  ic_cpu_ren,
    input  wire [31:0]  ic_cpu_raddr,
    output reg          ic_dev_rvalid,
    output reg  [`IC_BLK_SIZE-1:0]  ic_dev_rdata,
    // DCache Interface
    output reg          dc_dev_wrdy,
    input  wire [ 3:0]  dc_cpu_wen,
    input  wire [31:0]  dc_cpu_waddr,
    input  wire [31:0]  dc_cpu_wdata,
    output reg          dc_dev_rrdy,
    input  wire [ 3:0]  dc_cpu_ren,
    input  wire [31:0]  dc_cpu_raddr,
    output reg          dc_dev_rvalid,
    output reg  [`DC_BLK_SIZE-1:0]  dc_dev_rdata,

    // AXI4 Master Interface
    // write address channel
    output reg  [31:0]  m_axi_awaddr,
    output reg  [ 7:0]  m_axi_awlen,
    output reg  [ 2:0]  m_axi_awsize,
    output reg  [ 1:0]  m_axi_awburst,
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    // write data channel
    output reg  [31:0]  m_axi_wdata,
    output reg  [ 3:0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    // write response channel
    output reg          m_axi_bready,
    input  wire [ 1:0]  m_axi_bresp,
    input  wire         m_axi_bvalid,
    // read address channel
    output reg  [31:0]  m_axi_araddr,
    output reg  [ 7:0]  m_axi_arlen,
    output reg  [ 2:0]  m_axi_arsize,
    output reg  [ 1:0]  m_axi_arburst,
    output reg          m_axi_arvalid,
    input  wire         m_axi_arready,
    // read data channel
    output reg          m_axi_rready,
    input  wire [31:0]  m_axi_rdata,
    input  wire [ 1:0]  m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid
);

    // ============================================================
    // FSM State Definitions
    // ============================================================
    localparam S_IDLE    = 3'd0;   // Wait for Cache request
    localparam S_RD_ADDR = 3'd1;   // AR channel handshake
    localparam S_RD_DATA = 3'd2;   // R channel data reception
    localparam S_RD_RET  = 3'd3;   // Return read data to Cache
    localparam S_WR_ADDR = 3'd4;   // AW channel handshake
    localparam S_WR_DATA = 3'd5;   // W channel data transmission
    localparam S_WR_RESP = 3'd6;   // B channel response

    // ============================================================
    // Internal Registers
    // ============================================================
    reg [ 2:0] state, state_next;

    // Latched request info
    reg [31:0] req_addr;          // Request address
    reg [31:0] req_wdata;         // Write data (from DCache)
    reg [ 3:0] req_wstrb;         // Write strobe (from DCache)
    reg        req_is_dc;         // 1 = DCache request, 0 = ICache request

    // Beat counter for burst transfers
    reg [ 7:0] beat_cnt;

    // Read data assembly buffer (128-bit worst case)
    reg [127:0] rd_data_buf;

    // ============================================================
    // Burst Configuration (from defines.vh)
    // ============================================================
    wire [7:0] ic_burst_len = `IC_BLK_LEN - 1;   // 0 (1 beat) or 3 (4 beats)
    wire [7:0] dc_burst_len = `DC_BLK_LEN - 1;
    wire [7:0] burst_len    = req_is_dc ? dc_burst_len : ic_burst_len;

    // ============================================================
    // AXI Simplifications (per tutorial)
    // ============================================================
    // rready, bready always high after reset
    // Use constant arsize/awsize = 3'd2 (4 bytes per beat)
    // Use constant arburst/awburst = 2'd1 (INCR address mode)

    // wlast: asserted on the last write data beat
    assign m_axi_wlast = (beat_cnt == burst_len);

    // ============================================================
    // Sequential Logic: State Register + Data Path
    // ============================================================
    always @(posedge aclk or posedge areset) begin
        if (areset) begin
            state       <= S_IDLE;
            beat_cnt    <= 8'd0;
            req_addr    <= 32'd0;
            req_wdata   <= 32'd0;
            req_wstrb   <= 4'd0;
            req_is_dc   <= 1'b0;
            rd_data_buf <= 128'd0;
        end else begin
            state <= state_next;

            // --- Latch request info when leaving IDLE ---
            if (state == S_IDLE) begin
                // Priority: DCache write > DCache read > ICache read
                if (dc_cpu_wen != 4'h0) begin
                    // DCache write request
                    req_addr   <= dc_cpu_waddr;
                    req_wdata  <= dc_cpu_wdata;
                    req_wstrb  <= dc_cpu_wen;
                    req_is_dc  <= 1'b1;
                end else if (dc_cpu_ren != 4'h0) begin
                    // DCache read request
                    req_addr  <= dc_cpu_raddr;
                    req_is_dc <= 1'b1;
                end else if (ic_cpu_ren != 4'h0) begin
                    // ICache read request
                    req_addr  <= ic_cpu_raddr;
                    req_is_dc <= 1'b0;
                end
            end

            // --- Beat counter ---
            if (state == S_IDLE)
                beat_cnt <= 8'd0;
            else if ((state == S_RD_DATA) && m_axi_rvalid)
                beat_cnt <= beat_cnt + 8'd1;
            else if ((state == S_WR_DATA) && m_axi_wready)
                beat_cnt <= beat_cnt + 8'd1;

            // --- Read data assembly during RD_DATA ---
            if (state == S_RD_DATA && m_axi_rvalid)
                rd_data_buf[beat_cnt*32 +: 32] <= m_axi_rdata;
        end
    end

    // ============================================================
    // Combinational Logic: Next State + All Outputs
    // ============================================================
    always @(*) begin
        // ---- Default Values ----
        state_next = state;

        // Cache interface defaults: not ready, not valid
        ic_dev_rrdy   = 1'b0;
        ic_dev_rvalid = 1'b0;
        ic_dev_rdata  = {`IC_BLK_SIZE{1'b0}};
        dc_dev_wrdy   = 1'b0;
        dc_dev_rrdy   = 1'b0;
        dc_dev_rvalid = 1'b0;
        dc_dev_rdata  = {`DC_BLK_SIZE{1'b0}};

        // AXI defaults: all channels inactive
        m_axi_awaddr  = 32'd0;
        m_axi_awlen   = burst_len;
        m_axi_awsize  = 3'd2;    // 4 bytes per beat
        m_axi_awburst = 2'd1;    // INCR
        m_axi_awvalid = 1'b0;
        m_axi_wdata   = 32'd0;
        m_axi_wstrb   = 4'd0;
        m_axi_wvalid  = 1'b0;
        m_axi_bready  = 1'b1;    // Always ready for write response
        m_axi_araddr  = 32'd0;
        m_axi_arlen   = burst_len;
        m_axi_arsize  = 3'd2;
        m_axi_arburst = 2'd1;
        m_axi_arvalid = 1'b0;
        m_axi_rready  = 1'b1;    // Always ready for read data

        // ============================================================
        // State Machine
        // ============================================================
        case (state)

            // ----- IDLE: wait for Cache request -----
            S_IDLE: begin
                // Assert ready to all cache interfaces
                ic_dev_rrdy = 1'b1;
                dc_dev_rrdy = 1'b1;
                dc_dev_wrdy = 1'b1;

                // Priority: DCache write > DCache read > ICache read
                if (dc_cpu_wen != 4'h0)
                    state_next = S_WR_ADDR;
                else if (dc_cpu_ren != 4'h0)
                    state_next = S_RD_ADDR;
                else if (ic_cpu_ren != 4'h0)
                    state_next = S_RD_ADDR;
                // else stay in IDLE
            end

            // ----- RD_ADDR: AR channel handshake -----
            S_RD_ADDR: begin
                m_axi_araddr  = req_addr;
                m_axi_arlen   = burst_len;
                m_axi_arsize  = 3'd2;
                m_axi_arburst = 2'd1;
                m_axi_arvalid = 1'b1;

                if (m_axi_arready)
                    state_next = S_RD_DATA;
            end

            // ----- RD_DATA: R channel data reception -----
            S_RD_DATA: begin
                // No AR channel activity
                // Data is latched in sequential block when rvalid
                if (m_axi_rvalid && m_axi_rlast)
                    state_next = S_RD_RET;
            end

            // ----- RD_RET: return data to Cache (1 cycle pulse) -----
            S_RD_RET: begin
                if (req_is_dc) begin
                    dc_dev_rvalid = 1'b1;
                    dc_dev_rdata  = rd_data_buf[`DC_BLK_SIZE-1:0];
                end else begin
                    ic_dev_rvalid = 1'b1;
                    ic_dev_rdata  = rd_data_buf[`IC_BLK_SIZE-1:0];
                end
                state_next = S_IDLE;
            end

            // ----- WR_ADDR: AW channel handshake -----
            S_WR_ADDR: begin
                m_axi_awaddr  = req_addr;
                m_axi_awlen   = burst_len;
                m_axi_awsize  = 3'd2;
                m_axi_awburst = 2'd1;
                m_axi_awvalid = 1'b1;

                if (m_axi_awready)
                    state_next = S_WR_DATA;
            end

            // ----- WR_DATA: W channel data transmission -----
            S_WR_DATA: begin
                // Note: AW channel deasserted (awvalid = 0)
                m_axi_wdata  = req_wdata;
                m_axi_wstrb  = req_wstrb;
                m_axi_wvalid = 1'b1;

                if (m_axi_wready) begin
                    if (m_axi_wlast)
                        state_next = S_WR_RESP;
                    // else: stay in WR_DATA for next beat
                    //   (burst write: DCache line of 4 words
                    //    — not needed for current lab,
                    //    single-beat writes are sufficient)
                end
            end

            // ----- WR_RESP: B channel response -----
            S_WR_RESP: begin
                if (m_axi_bvalid)
                    state_next = S_IDLE;
            end

            default: state_next = S_IDLE;

        endcase
    end

endmodule
