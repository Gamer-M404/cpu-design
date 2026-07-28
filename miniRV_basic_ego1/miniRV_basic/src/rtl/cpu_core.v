`timescale 1ns / 1ps

`include "defines.vh"

module cpu_core(
    input  wire         cpu_rst,
    input  wire         cpu_clk,

    // Instruction Fetch Interface
    output wire         ifetch_req   /* verilator public */ ,
    output wire [31:0]  ifetch_addr  /* verilator public */ ,
    input  wire         ifetch_valid /* verilator public */ ,
    input  wire [31:0]  ifetch_inst,

    // Data Access Interface
    output reg  [ 3:0]  daccess_ren,
    output reg  [31:0]  daccess_addr,
    input  wire         daccess_rvalid,
    input  wire [31:0]  daccess_rdata,
    output reg  [ 3:0]  daccess_wen,
    output reg  [31:0]  daccess_wdata,
    input  wire         daccess_wresp
);

    //==========================================================================
    // IF (Instruction Fetch) Stage
    //==========================================================================
    reg  [31:0] pc;

    reg  rst_r;
    wire first_req = rst_r & !cpu_rst;
    always @(posedge cpu_clk) rst_r <= cpu_rst;

    // Track the PC of the most recent fetch request (for correct IF/ID PC)
    reg [31:0] fetch_req_pc;
    always @(posedge cpu_clk) begin
        if (ifetch_req)
            fetch_req_pc <= ifetch_addr;
    end

    //==========================================================================
    // IF/ID Pipeline Registers
    //==========================================================================
    reg [31:0] fd_pc;
    reg [31:0] fd_inst;

    //==========================================================================
    // ID (Instruction Decode) Stage
    //==========================================================================
    wire [ 6:0] id_opcode = fd_inst[6:0];
    wire [ 2:0] id_funct3 = fd_inst[14:12];
    wire [ 6:0] id_funct7 = fd_inst[31:25];
    wire [ 4:0] id_rs1    = fd_inst[19:15];
    wire [ 4:0] id_rs2    = fd_inst[24:20];
    wire [ 4:0] id_rd     = fd_inst[11:7];

    // Controller
    wire [ 1:0] id_npc_op;
    wire [ 2:0] id_sext_op;
    wire [ 4:0] id_alu_op;
    wire        id_alua_sel;
    wire        id_alub_sel;
    wire        id_is_mul;
    wire        id_is_div;
    wire [ 2:0] id_ram_rop;
    wire [ 3:0] id_ram_wop;
    wire        id_rf_we;
    wire [ 1:0] id_rf_wsel;

    Controller U_CU (
        .opcode     (id_opcode),
        .funct3     (id_funct3),
        .funct7     (id_funct7),
        .npc_op     (id_npc_op),
        .sext_op    (id_sext_op),
        .alu_op     (id_alu_op),
        .alua_sel   (id_alua_sel),
        .alub_sel   (id_alub_sel),
        .is_mul     (id_is_mul),
        .is_div     (id_is_div),
        .ram_r_op   (id_ram_rop),
        .ram_w_op   (id_ram_wop),
        .rf_we      (id_rf_we),
        .rf_wsel    (id_rf_wsel)
    );

    wire id_is_ld_st   = (id_ram_rop != `RAM_EXT_N) | (id_ram_wop != `RAM_WE_N);
    wire id_is_mul_div = id_is_mul | id_is_div;

    // Read flags
    wire id_rf1 = (id_opcode != 7'b0110111) &&
                  (id_opcode != 7'b0010111) &&
                  (id_opcode != 7'b1101111);
    wire id_rf2 = (id_opcode == 7'b0110011) ||
                  (id_opcode == 7'b0100011) ||
                  (id_opcode == 7'b1100011);

    // Register File
    wire [31:0] rf_rd1_raw;
    wire [31:0] rf_rd2_raw;
    RF U_RF (
        .clk    (cpu_clk),
        .rR1    (id_rs1),
        .rR2    (id_rs2),
        .rD1    (rf_rd1_raw),
        .rD2    (rf_rd2_raw),
        .we     (rf_we_gated),
        .wR     (mw_rd),
        .wD     (mw_wb_data)
    );

    // Immediate Extension
    wire [31:0] id_ext;
    SEXT U_SEXT (
        .op     (id_sext_op),
        .imm    (fd_inst[31:7]),
        .ext    (id_ext)
    );

    //==========================================================================
    // ID/EX Pipeline Registers
    //==========================================================================
    reg [31:0] de_pc;
    reg [31:0] de_rf_rd1;
    reg [31:0] de_rf_rd2;
    reg [31:0] de_ext;
    reg [ 4:0] de_rs1;
    reg [ 4:0] de_rs2;
    reg [ 4:0] de_rd;
    reg [ 1:0] de_npc_op;
    reg [ 4:0] de_alu_op;
    reg        de_alua_sel;
    reg        de_alub_sel;
    reg [ 2:0] de_ram_rop;
    reg [ 3:0] de_ram_wop;
    reg        de_rf_we;
    reg [ 1:0] de_rf_wsel;
    reg        de_is_ld_st;
    reg        de_is_mul_div;
    reg [31:0] de_pc4;

    //==========================================================================
    // Data Hazard Detection & Forwarding
    //==========================================================================
    // EX forwarding: disabled for mul/div (not ready) AND loads (alu_c = address, not data).
    // Load data is only available via WB forwarding (ram_ext in WB stage).
    wire ex_result_ready = !de_is_mul_div && !de_is_ld_st && !mul_div_busy;

    wire rs1_ex_hazard = de_rf_we && (de_rd != 5'h0) && (de_rd == id_rs1) && id_rf1 && ex_result_ready;
    wire rs2_ex_hazard = de_rf_we && (de_rd != 5'h0) && (de_rd == id_rs2) && id_rf2 && ex_result_ready;

    // MEM forwarding: disabled for loads (ram_ext in MEM is stale from DRAM latency).
    // Load data is only valid in WB stage (where ram_ext is correct combinationally).
    wire rs1_mem_hazard = em_rf_we && !em_is_ld_st && (em_rd != 5'h0) && (em_rd == id_rs1) && id_rf1;
    wire rs2_mem_hazard = em_rf_we && !em_is_ld_st && (em_rd != 5'h0) && (em_rd == id_rs2) && id_rf2;

    wire rs1_wb_hazard = mw_rf_we && (mw_rd != 5'h0) && (mw_rd == id_rs1) && id_rf1;
    wire rs2_wb_hazard = mw_rf_we && (mw_rd != 5'h0) && (mw_rd == id_rs2) && id_rf2;

    // Forward data sources: select correct value based on what the instruction produces
    wire [31:0] ex_forward_data  = (de_rf_wsel == `WB_EXT) ? de_ext :
                                    (de_rf_wsel == `WB_PC4) ? de_pc4 : alu_c;
    wire [31:0] mem_forward_data = (em_rf_wsel == `WB_RAM) ? ram_ext :
                                    (em_rf_wsel == `WB_EXT) ? em_ext :
                                    (em_rf_wsel == `WB_PC4) ? em_pc4 : em_alu_c;
    wire [31:0] wb_forward_data  = mw_wb_data;

    wire [31:0] rf_rd1_fw = rs1_ex_hazard  ? ex_forward_data  :
                             rs1_mem_hazard ? mem_forward_data :
                             rs1_wb_hazard  ? wb_forward_data  : rf_rd1_raw;
    wire [31:0] rf_rd2_fw = rs2_ex_hazard  ? ex_forward_data  :
                             rs2_mem_hazard ? mem_forward_data :
                             rs2_wb_hazard  ? wb_forward_data  : rf_rd2_raw;

    //==========================================================================
    // Pipeline Stall & Flush Control
    //==========================================================================
    // Load-use: consumer in ID needs load result from EX or MEM.
    // Must stall until load reaches WB (ram_ext is only correct in WB).
    wire load_use_hazard =
        (de_is_ld_st && de_rf_we && (de_rd != 5'h0) &&
         ((de_rd == id_rs1 && id_rf1) || (de_rd == id_rs2 && id_rf2))) ||
        (em_is_ld_st && em_rf_we && (em_rd != 5'h0) &&
         ((em_rd == id_rs1 && id_rf1) || (em_rd == id_rs2 && id_rf2)));

    // 2-cycle load-use stall via 1-cycle delayed copy.
    // load_use_hazard fires when load is in EX → stall + bubble for 1 cycle.
    // load_use_stall_r fires next cycle → stall + bubble for 1 more cycle.
    // Total 2 bubbles: load reaches WB before consumer enters EX.
    reg load_use_stall_r;
    always @(posedge cpu_clk) begin
        if (cpu_rst || ex_flush)
            load_use_stall_r <= 1'b0;
        else
            load_use_stall_r <= load_use_hazard;
    end

    // Mul/div stall: freeze EX/MEM, MEM/WB, and ID/EX while a multi-cycle
    // op is in EX.  Combinational detection avoids the 1-cycle gap of
    // registered pre-stall and handles back-to-back mul/div correctly.
    wire stall_all      = de_is_mul_div && (mul_div_busy || !mul_div_active);
    wire stall_load_use = load_use_hazard || load_use_stall_r;
    wire stall_if_id    = stall_all || stall_load_use;
    wire flush_id_ex    = stall_load_use || ex_flush;

    //==========================================================================
    // Branch Resolution (in EX stage)
    //==========================================================================
    wire ex_is_branch = (de_npc_op == `NPC_BRA);
    wire ex_is_jal    = (de_npc_op == `NPC_JMP);
    wire ex_is_jalr   = (de_npc_op == `NPC_JALR);
    wire ex_bj_f      = (ex_is_branch && alu_br) || ex_is_jal || ex_is_jalr;
    wire [31:0] ex_bj_target = (de_npc_op == `NPC_JALR) ? {alu_c[31:1], 1'b0} : (de_pc + de_ext);
    wire ex_flush = ex_bj_f && !stall_all;

    //==========================================================================
    // IF Stage: Fetch & PC
    //==========================================================================
    // Pause fetch only on the FIRST load-use stall cycle.
    // On the second cycle, start fetch early so the next instruction
    // is ready when the stall ends (no extra bubble).
    wire pause_ifetch = stall_all || load_use_hazard || ex_flush;
    assign ifetch_req  = !pause_ifetch;
    assign ifetch_addr = ex_bj_f ? ex_bj_target : pc;

    wire [31:0] pc4 = fd_pc + 32'h4;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            pc <= `PC_INIT_VAL;
        else if (ex_bj_f)
            pc <= ex_bj_target;
        else if (!stall_if_id)
            pc <= pc + 32'h4;
    end

    //==========================================================================
    // Buffer for instruction whose fetch response arrived during a stall.
    // Without this, the instruction is lost (fd was frozen when it arrived).
    reg [31:0] stalled_inst;
    reg        stalled_valid;
    reg [31:0] stalled_pc;
    always @(posedge cpu_clk) begin
        if (cpu_rst || ex_flush) begin
            stalled_valid <= 1'b0;
        end else if (ifetch_valid && stall_if_id && !stalled_valid) begin
            stalled_inst  <= ifetch_inst;
            stalled_valid <= 1'b1;
            stalled_pc    <= fetch_req_pc;
        end else if (!stall_if_id) begin
            stalled_valid <= 1'b0;
        end
    end

    // IF/ID Register Update
    //==========================================================================
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            fd_pc   <= 32'h0;
            fd_inst <= 32'h13;
        end else if (ex_flush) begin
            fd_pc   <= ex_bj_target;
            fd_inst <= 32'h13;
        end else if (!stall_if_id) begin
            if (stalled_valid) begin
                fd_pc   <= stalled_pc;
                fd_inst <= stalled_inst;
            end else begin
                fd_pc   <= fetch_req_pc;
                fd_inst <= ifetch_valid ? ifetch_inst : 32'h13;
            end
        end
    end

    //==========================================================================
    // ID/EX Register Update
    //==========================================================================
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst || ex_flush || flush_id_ex) begin
            de_pc         <= 32'h0;
            de_rf_rd1     <= 32'h0;
            de_rf_rd2     <= 32'h0;
            de_ext        <= 32'h0;
            de_rs1        <= 5'h0;
            de_rs2        <= 5'h0;
            de_rd         <= 5'h0;
            de_npc_op     <= `NPC_PC4;
            de_alu_op     <= `ALU_ADD;
            de_alua_sel   <= `ALU_A_RS1;
            de_alub_sel   <= `ALU_B_RS2;
            de_ram_rop    <= `RAM_EXT_N;
            de_ram_wop    <= `RAM_WE_N;
            de_rf_we      <= 1'b0;
            de_rf_wsel    <= `WB_ALU;
            de_is_ld_st   <= 1'b0;
            de_is_mul_div <= 1'b0;
            de_pc4        <= 32'h0;
        end else if (!stall_all) begin
            de_pc         <= fd_pc;
            de_rf_rd1     <= rf_rd1_fw;
            de_rf_rd2     <= rf_rd2_fw;
            de_ext        <= id_ext;
            de_rs1        <= id_rs1;
            de_rs2        <= id_rs2;
            de_rd         <= id_rd;
            de_npc_op     <= id_npc_op;
            de_alu_op     <= id_alu_op;
            de_alua_sel   <= id_alua_sel;
            de_alub_sel   <= id_alub_sel;
            de_ram_rop    <= id_ram_rop;
            de_ram_wop    <= id_ram_wop;
            de_rf_we      <= id_rf_we;
            de_rf_wsel    <= id_rf_wsel;
            de_is_ld_st   <= id_is_ld_st;
            de_is_mul_div <= id_is_mul_div;
            de_pc4        <= pc4;
        end
    end

    //==========================================================================
    // EX (Execute) Stage
    //==========================================================================
    wire [31:0] alu_a = de_alua_sel ? de_pc  : de_rf_rd1;
    wire [31:0] alu_b = de_alub_sel ? de_ext : de_rf_rd2;
    wire [31:0] alu_c;
    wire        alu_br;
    wire        mul_div_busy;
    wire        mul_div_active;

    ALU U_ALU (
        .rst            (cpu_rst),
        .clk            (cpu_clk),
        .op             (de_alu_op),
        .a              (alu_a),
        .b              (alu_b),
        .br             (alu_br),
        .c              (alu_c),
        .busy           (mul_div_busy),
        .mul_div_active (mul_div_active)
    );

    // MREQ uses EX-stage signals so memory request is ready at start of MEM
    wire [ 3:0] da_ren;
    wire [31:0] da_addr;
    wire [ 3:0] da_wen;
    wire [31:0] da_wdata;
    MREQ U_MEM_REQ (
        .ram_addr   (alu_c),
        .ram_rop    (de_ram_rop),
        .da_ren     (da_ren),
        .da_addr    (da_addr),
        .ram_wop    (de_ram_wop),
        .ram_wdata  (de_rf_rd2),
        .da_wen     (da_wen),
        .da_wdata   (da_wdata)
    );

    // MEXT: combinational from DRAM read data
    wire [31:0] ram_ext;
    MEXT U_MEM_EXT (
        .op         (em_ram_rop),
        .din        (daccess_rdata),
        .byte_offs  (em_alu_c[1:0]),
        .ext        (ram_ext)
    );

    // Bus interface — freeze during mul/div stall so a load in MEM
    // doesn't have its DRAM request overwritten by the EX-stage instruction.
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            daccess_ren <= 4'h0;
            daccess_wen <= 4'h0;
        end else if (!stall_all) begin
            daccess_ren   <= da_ren;
            daccess_addr  <= da_addr;
            daccess_wen   <= da_wen;
            daccess_wdata <= da_wdata;
        end
    end

    //==========================================================================
    // EX/MEM Pipeline Registers
    //==========================================================================
    reg [31:0] em_pc;
    reg [31:0] em_alu_c;
    reg [31:0] em_rf_rd2;
    reg [31:0] em_ext;
    reg [ 4:0] em_rd;
    reg [ 1:0] em_npc_op;
    reg [ 2:0] em_ram_rop;
    reg [ 3:0] em_ram_wop;
    reg        em_rf_we;
    reg [ 1:0] em_rf_wsel;
    reg        em_is_ld_st;
    reg        em_is_mul_div;
    reg        em_br;
    reg [31:0] em_pc4;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            em_pc         <= 32'h0;
            em_alu_c      <= 32'h0;
            em_rf_rd2     <= 32'h0;
            em_ext        <= 32'h0;
            em_rd         <= 5'h0;
            em_npc_op     <= `NPC_PC4;
            em_ram_rop    <= `RAM_EXT_N;
            em_ram_wop    <= `RAM_WE_N;
            em_rf_we      <= 1'b0;
            em_rf_wsel    <= `WB_ALU;
            em_is_ld_st   <= 1'b0;
            em_is_mul_div <= 1'b0;
            em_br         <= 1'b0;
            em_pc4        <= 32'h0;
        end else if (!stall_all) begin
            em_pc         <= de_pc;
            em_alu_c      <= alu_c;
            em_rf_rd2     <= de_rf_rd2;
            em_ext        <= de_ext;
            em_rd         <= de_rd;
            em_npc_op     <= de_npc_op;
            em_ram_rop    <= de_ram_rop;
            em_ram_wop    <= de_ram_wop;
            em_rf_we      <= de_rf_we;
            em_rf_wsel    <= de_rf_wsel;
            em_is_ld_st   <= de_is_ld_st;
            em_is_mul_div <= de_is_mul_div;
            em_br         <= alu_br;
            em_pc4        <= de_pc4;
        end
    end

    //==========================================================================
    // MEM/WB Pipeline Registers
    //==========================================================================
    reg [31:0] mw_pc;
    reg [31:0] mw_alu_c;
    reg [31:0] mw_ram_ext;
    reg [31:0] mw_ext;
    reg [ 4:0] mw_rd;
    reg        mw_rf_we;
    reg [ 1:0] mw_rf_wsel;
    reg [31:0] mw_pc4;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            mw_pc      <= 32'h0;
            mw_alu_c   <= 32'h0;
            mw_ram_ext <= 32'h0;
            mw_ext     <= 32'h0;
            mw_rd      <= 5'h0;
            mw_rf_we   <= 1'b0;
            mw_rf_wsel <= `WB_ALU;
            mw_pc4     <= 32'h0;
        end else if (!stall_all) begin
            mw_pc      <= em_pc;
            mw_alu_c   <= em_alu_c;
            mw_ram_ext <= ram_ext;
            mw_ext     <= em_ext;
            mw_rd      <= em_rd;
            mw_rf_we   <= em_rf_we;
            mw_rf_wsel <= em_rf_wsel;
            mw_pc4     <= em_pc4;
        end
    end

    //==========================================================================
    // WB (Write Back) Stage
    //==========================================================================
    // Capture byte_offs during load's MEM cycle for use in WB stage.
    // When the load reaches WB, em_* has changed to the next instruction,
    // so MEXT would use wrong byte_offs.  We store them here.
    reg [1:0] wb_byte_offs;
    reg [2:0] wb_ram_rop;
    always @(posedge cpu_clk) begin
        if (em_is_ld_st && !stall_all) begin
            wb_byte_offs <= em_alu_c[1:0];
            wb_ram_rop   <= em_ram_rop;
        end
    end

    // Second MEXT: processes current daccess_rdata with the load's stored byte_offs.
    // daccess_rdata during WB has correct DRAM data (DRAM latency resolved).
    wire [31:0] wb_ram_ext;
    MEXT U_MEXT_WB (
        .op         (wb_ram_rop),
        .din        (daccess_rdata),
        .byte_offs  (wb_byte_offs),
        .ext        (wb_ram_ext)
    );

    wire [31:0] mw_wb_data;
    assign mw_wb_data = (mw_rf_wsel == `WB_RAM) ? wb_ram_ext :
                        (mw_rf_wsel == `WB_PC4) ? mw_pc4     :
                        (mw_rf_wsel == `WB_EXT) ? mw_ext     :
                        mw_alu_c;

    wire mw_rf_we_actual = mw_rf_we && (mw_rd != 5'h0);

    // Prevent repeated RF write / debug event during mul/div stall.
    // MEM/WB is frozen by stall_all, so the same writeback would appear
    // every cycle.  wb_done is set on the first stall cycle to suppress
    // subsequent cycles.  It resets when MW updates (stall_all deasserts).
    reg wb_done;
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            wb_done <= 1'b0;
        else if (!stall_all)
            wb_done <= 1'b0;
        else if (stall_all && !wb_done)
            wb_done <= 1'b1;
    end

    wire rf_we_gated = mw_rf_we_actual && !wb_done;

    //==========================================================================
    // Debug / Trace Signals
    //==========================================================================
    // Pipeline state debug — always present (used by test.cpp debug prints)
    wire [31:0] debug_id_pc  /* verilator public */ ;
    wire [ 4:0] debug_id_rd  /* verilator public */ ;
    wire [31:0] debug_ex_pc  /* verilator public */ ;
    wire [ 4:0] debug_ex_rd  /* verilator public */ ;
    wire [ 4:0] debug_mem_rd /* verilator public */ ;

    assign debug_id_pc  = fd_pc;
    assign debug_id_rd  = id_rd;
    assign debug_ex_pc  = de_pc;
    assign debug_ex_rd  = de_rd;
    assign debug_mem_rd = em_rd;

`ifdef RUN_TRACE
    wire [31:0] debug_wb_pc    /* verilator public */ ;
    wire        debug_wb_rf_we /* verilator public */ ;
    wire [ 4:0] debug_wb_rf_wR /* verilator public */ ;
    wire [31:0] debug_wb_rf_wD /* verilator public */ ;

    wire [31:0] debug_mem_pc    /* verilator public */ ;
    wire [ 3:0] debug_mem_we    /* verilator public */ ;
    wire [31:0] debug_mem_waddr /* verilator public */ ;
    wire [31:0] debug_mem_wdata /* verilator public */ ;

    // Gate WB debug signals so a writeback frozen in MEM/WB during
    // mul/div stall is reported only once, not every stalled cycle.
    assign debug_wb_pc    = rf_we_gated ? mw_pc      : 32'h0;
    assign debug_wb_rf_we = rf_we_gated;
    assign debug_wb_rf_wR = rf_we_gated ? mw_rd      : 5'h0;
    assign debug_wb_rf_wD = rf_we_gated ? mw_wb_data : 32'h0;

    assign debug_mem_pc    = em_pc;
    assign debug_mem_we    = daccess_wen;
    assign debug_mem_waddr = daccess_addr;
    assign debug_mem_wdata = daccess_wdata;
`endif

endmodule
