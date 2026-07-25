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

    // Pipeline Register Widths
    localparam IF_ID_WID  = 96;
    localparam ID_EX_WID  = 184;
    localparam EX_MEM_WID = 111;
    localparam MEM_WB_WID = 104;

    wire flush_if_id;
    wire flush_id_ex;

    // 为 load-use 冒险准备停滞
    wire pipe_stall;
    assign pipe_stall = load_use_hazard;

    // ============================================================
    // IF Stage
    // ============================================================
    wire [31:0] pc;
    wire [31:0] pc4;

    assign ifetch_req  = 1'b1;
    assign ifetch_addr = pc;
    assign pc4 = pc + 32'h4;

    wire if_stall;
    assign if_stall = !ifetch_valid | pipe_stall;

    wire [31:0] if_inst;
    assign if_inst = ifetch_valid ? ifetch_inst : 32'h13;

    // IF/ID Pipeline Register
    wire [IF_ID_WID-1:0] if_id_dout;

    pipeline_reg #(.WIDTH(IF_ID_WID)) U_IF_ID (
        .clk      (cpu_clk),
        .rst      (cpu_rst),
        .stall    (if_stall),
        .flush    (flush_if_id),
        .din      ({pc, pc4, if_inst}),
        .dout     (if_id_dout)
    );

    wire [31:0] id_pc   = if_id_dout[95:64];
    wire [31:0] id_pc4  = if_id_dout[63:32];
    wire [31:0] id_inst = if_id_dout[31:0];
    

    // 获取更多有关寄存器的信息以判断冒险
    wire [4:0] id_rs1 = id_inst[19:15];
    wire [4:0] id_rs2 = id_inst[24:20];
    wire [4:0] id_rd = id_inst[11:7];

    wire [6:0] id_opcode = id_inst[6:0];

    // 是否要读寄存器1，2
    wire id_rf1;
    assign id_rf1 = !(id_opcode == 7'b0110111 ||   // LUI
                    id_opcode == 7'b0010111 ||   // AUIPC
                    id_opcode == 7'b1101111);    // JAL

    wire id_rf2;
    assign id_rf2 = (id_opcode == 7'b0110011) ||   // R-type
                    (id_opcode == 7'b1100011) ||   // B-type (BEQ, BNE, etc.)
                    (id_opcode == 7'b0100011);     // S-type (SW, SB, SH)
    // ============================================================
    // ID Stage
    // ============================================================

    // Controller
    wire [ 1:0] npc_op;
    wire [ 1:0] rf_wsel;
    wire [ 2:0] sext_op;
    wire [ 4:0] alu_op;
    wire        alua_sel;
    wire        alub_sel;
    wire [ 2:0] ram_rop;
    wire [ 3:0] ram_wop;
    wire        is_mul;
    wire        is_div;
    wire        rf_we;

    Controller U_CU (
        .opcode         (id_inst[6:0]),
        .funct3         (id_inst[14:12]),
        .funct7         (id_inst[31:25]),
        .npc_op         (npc_op),
        .sext_op        (sext_op),
        .alu_op         (alu_op),
        .alua_sel       (alua_sel),
        .alub_sel       (alub_sel),
        .is_mul         (is_mul),
        .is_div         (is_div),
        .ram_r_op       (ram_rop),
        .ram_w_op       (ram_wop),
        .rf_we          (rf_we),
        .rf_wsel        (rf_wsel)
    );

    // Register File
    wire [31:0] rf_rd1;
    wire [31:0] rf_rd2;

    wire        rf_we1;
    wire [ 4:0] rf_wR;
    reg  [31:0] rf_wD;

    RF U_RF (
        .clk        (cpu_clk),
        .rR1        (id_inst[19:15]),
        .rR2        (id_inst[24:20]),
        .rD1        (rf_rd1),
        .rD2        (rf_rd2),
        .we         (rf_we1),
        .wR         (rf_wR),
        .wD         (rf_wD)
    );

    // Sign Extension
    wire [31:0] ext;

    SEXT U_SEXT (
        .op         (sext_op),
        .imm        (id_inst[31:7]),
        .ext        (ext)
    );

    // JAL target & redirect (ID stage)
    wire [31:0] id_jal_target;
    wire        jal_redirect;
    assign id_jal_target = id_pc + ext;
    assign jal_redirect  = (npc_op == `NPC_JMP);

    // ID/EX Pipeline Register
    wire [ID_EX_WID-1:0] id_ex_din;
    wire [ID_EX_WID-1:0] id_ex_dout;

    assign id_ex_din = {
        id_inst[11:7],
        ext,
        op_datB,
        op_datA,
        id_pc4,
        id_pc,
        rf_we,
        rf_wsel,
        alub_sel,
        alua_sel,
        alu_op,
        npc_op,
        ram_rop,
        ram_wop
    };

    pipeline_reg #(.WIDTH(ID_EX_WID)) U_ID_EX (
        .clk      (cpu_clk),
        .rst      (cpu_rst),
        .stall    (1'b0),
        .flush    (flush_id_ex | pipe_stall),
        .din      (id_ex_din),
        .dout     (id_ex_dout)
    );

    // ============================================================
    // EX Stage
    // ============================================================

    // Unpack ID/EX
    wire [ 4:0] ex_rd       = id_ex_dout[183:179];
    wire [31:0] ex_ext      = id_ex_dout[178:147];
    wire [31:0] ex_rf_rd2   = id_ex_dout[146:115];
    wire [31:0] ex_rf_rd1   = id_ex_dout[114:83];
    wire [31:0] ex_pc4      = id_ex_dout[82:51];
    wire [31:0] ex_pc       = id_ex_dout[50:19];
    wire        ex_rf_we    = id_ex_dout[18];
    wire [ 1:0] ex_rf_wsel  = id_ex_dout[17:16];
    wire        ex_alub_sel = id_ex_dout[15];
    wire        ex_alua_sel = id_ex_dout[14];
    wire [ 4:0] ex_alu_op   = id_ex_dout[13:9];
    wire [ 1:0] ex_npc_op   = id_ex_dout[8:7];
    wire [ 2:0] ex_ram_rop  = id_ex_dout[6:4];
    wire [ 3:0] ex_ram_wop  = id_ex_dout[3:0];


    // 从流水寄存器中获取操作寄存器信息
    wire [4:0] id_ex_rd = id_ex_dout[183:179];
    wire       id_ex_rf_we = id_ex_dout[18];
    wire [1:0] id_ex_rf_wsel = id_ex_dout[17:16];   // EX 段指令的写回选择


    // 判断数据冒险
    wire rs1_ex_hazard;
    wire rs2_ex_hazard;
    assign rs1_ex_hazard = (id_ex_rd == id_rs1) & id_ex_rf_we & id_rf1 & (id_ex_rd != 5'h0);
    assign rs2_ex_hazard = (id_ex_rd == id_rs2) & id_ex_rf_we & id_rf2 & (id_ex_rd != 5'h0);
    
    // 判断load-use 冒险
    wire [2:0] id_ex_ram_rop = id_ex_dout[6:4];

    wire load_use_hazard;
    assign load_use_hazard = 
        (id_ex_ram_rop != `RAM_EXT_N) &&
        (id_ex_rd != 5'h0)            &&
        ((id_ex_rd == id_rs1 & id_rf1) ||
         (id_ex_rd == id_rs2 & id_rf2));

    // ALU
    wire [31:0] alu_a;
    wire [31:0] alu_b;
    assign alu_a = ex_alua_sel ? ex_pc : ex_rf_rd1;
    assign alu_b = ex_alub_sel ? ex_ext : ex_rf_rd2;

    wire [31:0] alu_c;
    wire        br;
    wire        mul_div_busy;

    ALU U_ALU (
        .rst        (cpu_rst),
        .clk        (cpu_clk),
        .op         (ex_alu_op),
        .a          (alu_a),
        .b          (alu_b),
        .br         (br),
        .c          (alu_c),
        .busy       (mul_div_busy)
    );

    // ---- 访存请求：在 EX 阶段发出，MEM 阶段数据就绪 ----
    // DRAM 为寄存器输出（1 拍延迟），提前到 EX 发请求以消除停顿
    wire [ 3:0] da_ren;
    wire [31:0] da_addr;
    wire [ 3:0] da_wen;
    wire [31:0] da_wdata;

    MREQ U_MEM_REQ (
        .ram_addr   (alu_c),        // EX 阶段 ALU 结果 = 访存地址
        .ram_rop    (ex_ram_rop),   // EX 阶段 load 类型
        .ram_wop    (ex_ram_wop),   // EX 阶段 store 类型
        .ram_wdata  (ex_rf_rd2),    // EX 阶段 store data（已前推）
        .da_ren     (da_ren),
        .da_addr    (da_addr),
        .da_wen     (da_wen),
        .da_wdata   (da_wdata)
    );

    // Branch target & redirect (EX stage)
    wire [31:0] ex_br_target;
    wire        br_redirect;
    wire        jalr_redirect;
    assign ex_br_target   = ex_pc + ex_ext;
    assign br_redirect    = (ex_npc_op == `NPC_BRA) && br;
    assign jalr_redirect  = (ex_npc_op == `NPC_JALR);

    // EX/MEM Pipeline Register
    wire [EX_MEM_WID-1:0] ex_mem_din;
    wire [EX_MEM_WID-1:0] ex_mem_dout;

    assign ex_mem_din = {
        ex_rd,
        ex_ext,
        ex_pc4,
        alu_c,
        ex_rf_we,
        ex_rf_wsel,
        ex_ram_rop,
        ex_ram_wop
    };

    pipeline_reg #(.WIDTH(EX_MEM_WID)) U_EX_MEM (
        .clk      (cpu_clk),
        .rst      (cpu_rst),
        .stall    (1'b0),
        .flush    (1'b0),
        .din      (ex_mem_din),
        .dout     (ex_mem_dout)
    );

    // ============================================================
    // MEM Stage
    // ============================================================

    wire [ 4:0] mem_rd      = ex_mem_dout[110:106];
    wire [31:0] mem_ext     = ex_mem_dout[105:74];
    wire [31:0] mem_pc4     = ex_mem_dout[73:42];
    wire [31:0] mem_alu_c   = ex_mem_dout[41:10];
    wire        mem_rf_we   = ex_mem_dout[9];
    wire [ 1:0] mem_rf_wsel = ex_mem_dout[8:7];
    wire [ 2:0] mem_ram_rop = ex_mem_dout[6:4];
    wire [ 3:0] mem_ram_wop = ex_mem_dout[3:0];

    // 检测数据冒险用
    wire [4:0] ex_mem_rd    = ex_mem_dout[110:106];
    wire       ex_mem_rf_we = ex_mem_dout[9];

    wire rs1_mem_hazard;
    wire rs2_mem_hazard;
    assign rs1_mem_hazard = (ex_mem_rd == id_rs1) & ex_mem_rf_we & id_rf1 & (ex_mem_rd != 5'h0);
    assign rs2_mem_hazard = (ex_mem_rd == id_rs2) & ex_mem_rf_we & id_rf2 & (ex_mem_rd != 5'h0);

    // ---- 根据 producer 的 rf_wsel 选择正确的前推数据 ----
    // 情形 A: producer 在 EX，根据 id_ex_rf_wsel 选
    wire [31:0] ex_fwd_data;
    assign ex_fwd_data = (id_ex_rf_wsel == `WB_ALU) ? alu_c                :
                         (id_ex_rf_wsel == `WB_PC4) ? id_ex_dout[82:51]  : // ex_pc4
                         (id_ex_rf_wsel == `WB_EXT) ? id_ex_dout[178:147]: // ex_ext
                         (id_ex_rf_wsel == `WB_RAM) ? 32'h0 :  // load: 数据未就绪，由 stall 处理
                                                      alu_c;    // 默认

    // 情形 B: producer 在 MEM，根据 mem_rf_wsel 选
    wire [31:0] mem_fwd_data;
    assign mem_fwd_data = (mem_rf_wsel == `WB_ALU) ? mem_alu_c  :
                          (mem_rf_wsel == `WB_PC4) ? mem_pc4    :
                          (mem_rf_wsel == `WB_EXT) ? mem_ext    :
                          (mem_rf_wsel == `WB_RAM) ? ram_ext    :  // load: 前推内存数据
                                                     mem_alu_c;    // 默认

    // ---- 前推 MUX ----
    // rs1的数据前递
    wire [31:0] op_datA;
    assign op_datA = rs1_ex_hazard ? ex_fwd_data :
                     rs1_mem_hazard ? mem_fwd_data :
                     rs1_wb_hazard ? rf_wD :
                                     rf_rd1;

    // rs2的数据前递
    wire [31:0] op_datB;
    assign op_datB = rs2_ex_hazard ? ex_fwd_data :
                     rs2_mem_hazard ? mem_fwd_data :
                     rs2_wb_hazard ? rf_wD :
                                     rf_rd2;
    // MEXT: 总线返回数据 → 对齐 + 符号扩展
    // daccess_rdata 在 MEM 阶段已就绪（DRAM 读在 EX→MEM posedge 完成）
    wire [31:0] ram_ext;

    MEXT U_MEM_EXT (
        .op         (mem_ram_rop),       // 当前 load 类型
        .din        (daccess_rdata),     // DRAM 返回数据（EX 阶段已发出读请求）
        .byte_offs  (mem_alu_c[1:0]),
        .ext        (ram_ext)
    );

    // ---- MEM/WB 数据选择 ----
    // load: 写回 ram_ext（从内存读出的数据）
    // 其他: 写回 mem_alu_c（ALU 结果）
    wire [31:0] mem_wb_data;
    assign mem_wb_data = (mem_ram_rop != `RAM_EXT_N) ? ram_ext : mem_alu_c;


    // MEM/WB Pipeline Register
    wire [MEM_WB_WID-1:0] mem_wb_din;
    wire [MEM_WB_WID-1:0] mem_wb_dout;

    assign mem_wb_din = {
        mem_rd,
        mem_ext,
        mem_pc4,
        mem_wb_data,    // ← load=ram_ext, ALU=mem_alu_c
        mem_rf_we,
        mem_rf_wsel
    };

    pipeline_reg #(.WIDTH(MEM_WB_WID)) U_MEM_WB (
        .clk      (cpu_clk),
        .rst      (cpu_rst),
        .stall    (1'b0),
        .flush    (1'b0),
        .din      (mem_wb_din),
        .dout     (mem_wb_dout)
    );

    // ============================================================
    // WB Stage
    // ============================================================

    wire [ 4:0] wb_rd      = mem_wb_dout[103:99];
    wire [31:0] wb_ext     = mem_wb_dout[98:67];
    wire [31:0] wb_pc4     = mem_wb_dout[66:35];
    wire [31:0] wb_alu_c   = mem_wb_dout[34:3];
    wire        wb_rf_we   = mem_wb_dout[2];
    wire [ 1:0] wb_rf_wsel = mem_wb_dout[1:0]; 


    // 检测数据冒险用
    wire [4:0] mem_wb_rd = mem_wb_dout[103:99];
    wire    mem_wb_rf_we = mem_wb_dout[2];

    wire rs1_wb_hazard;
    wire rs2_wb_hazard;
    assign rs1_wb_hazard = (mem_wb_rd == id_rs1) & mem_wb_rf_we & id_rf1 & (mem_wb_rd != 5'h0);
    assign rs2_wb_hazard = (mem_wb_rd == id_rs2) & mem_wb_rf_we & id_rf2 & (mem_wb_rd != 5'h0);


    assign rf_we1 = wb_rf_we;
    assign rf_wR  = wb_rd;

    always @(*) begin
        case (wb_rf_wsel)
            `WB_ALU: rf_wD = wb_alu_c;
            `WB_RAM: rf_wD = wb_alu_c;   // load 数据存在 alu_c 字段
            `WB_PC4: rf_wD = wb_pc4;
            `WB_EXT: rf_wD = wb_ext;
            default: rf_wD = 32'h0;
        endcase
    end

    // ============================================================
    // PC & Redirect
    // ============================================================

    assign flush_if_id = jal_redirect | br_redirect | jalr_redirect;
    assign flush_id_ex = br_redirect | jalr_redirect;

    wire [31:0] next_pc;
    assign next_pc = br_redirect   ? ex_br_target :
                     jalr_redirect ? alu_c :
                     jal_redirect  ? id_jal_target :
                                     pc + 32'h4;

    // Redirects must always update PC, even during an IF stall
    wire pc_fetch;
    assign pc_fetch = (!if_stall && !pipe_stall) | jal_redirect | br_redirect | jalr_redirect;

    PC U_PC (
        .clk        (cpu_clk),
        .rst        (cpu_rst),
        .npc        (next_pc),
        .fetch      (pc_fetch),
        .pc         (pc)
    );

    // ============================================================
    // Data Access Interface — 连接到总线
    // ============================================================
    // daccess_addr: load 用组合逻辑（EX 阶段立即读），store 用寄存器（保持到 MEM 写完成）
    reg [31:0] daccess_addr_s;
    always @(posedge cpu_clk) begin
        if (da_wen != 4'h0)
            daccess_addr_s <= da_addr;   // 保存 store 地址
    end
    always @(*) begin
        // store 在 MEM 时使用寄存器地址，否则使用组合逻辑地址
        daccess_addr = cpu_rst ? 32'h0 :
                       (daccess_wen != 4'h0) ? daccess_addr_s : da_addr;
    end

    // daccess_ren/wen/wdata: 寄存器（对齐黄金模型 MEM 阶段时序）
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            daccess_ren   <= 4'h0;
            daccess_wen   <= 4'h0;
            daccess_wdata <= 32'h0;
        end else begin
            daccess_ren   <= da_ren;
            daccess_wen   <= da_wen;
            daccess_wdata <= da_wdata;
        end
    end

    // ============================================================
    // Debug Trace
    // ============================================================
`ifdef RUN_TRACE
    wire [31:0] debug_wb_pc    /* verilator public */ ;
    wire        debug_wb_rf_we /* verilator public */ ;
    wire [ 4:0] debug_wb_rf_wR /* verilator public */ ;
    wire [31:0] debug_wb_rf_wD /* verilator public */ ;

    wire [31:0] debug_mem_pc    /* verilator public */ ;
    wire [ 3:0] debug_mem_we    /* verilator public */ ;
    wire [31:0] debug_mem_waddr /* verilator public */ ;
    wire [31:0] debug_mem_wdata /* verilator public */ ;

    assign debug_wb_pc    = wb_pc4 - 32'h4;
    assign debug_wb_rf_we = wb_rf_we;
    assign debug_wb_rf_wR = wb_rd;
    assign debug_wb_rf_wD = rf_wD;

    assign debug_mem_pc    = mem_pc4 - 32'h4;
    assign debug_mem_we    = daccess_wen;
    assign debug_mem_waddr = daccess_addr;
    assign debug_mem_wdata = daccess_wdata;
`endif

endmodule
