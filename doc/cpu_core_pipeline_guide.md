# cpu_core.v → 五级理想流水线 修改指南

## 0. 前置条件

- 已添加 `pipeline_reg.v`（通用流水寄存器模块，见 `doc/pipeline_design.md`）
- 只支持**单周期指令**，无访存、无乘除法，无 stall
- 不支持数据前推，程序需自行保证**无 RAW 相关性**（或手动插 NOP）

支持指令：所有 R-type/I-type ALU、LUI、AUIPC、JAL、JALR、所有 Branch。

---

## 1. 各流水寄存器信号（只保留功能必需的）

### 1.1 IF/ID — 96 bit

```
┌──────────┬──────────┬──────────┐
│  pc(32)  │ pc4(32)  │ inst(32) │
│ [95:64]  │ [63:32]  │ [31:0]   │
└──────────┴──────────┴──────────┘
```

| 信号 | 要它干嘛 |
|---|---|
| `pc` | ID 阶段算 JAL target；传到 EX 用于 AUIPC 和分支 target |
| `pc4` | JAL/JALR 的返回地址，一路传到 WB 写回 |
| `inst` | Controller 译码 |

### 1.2 ID/EX — 184 bit

```
┌──────┬──────────┬──────────┬──────────┬──────────┬──────────┬───────┬─────────┬─────────┬─────────┬────────┬────────┬──────────┬──────────┐
│rd(5) │ ext(32)  │rf_rd2(32)│rf_rd1(32)│id_pc4(32)│id_pc(32) │rf_we(1)│rf_wsel(2)│alub_sel(1)│alua_sel(1)│alu_op(5)│npc_op(2)│ram_rop(3)│ram_wop(4)│
│[183] │ [178:147]│[146:115] │[114:83]  │[82:51]   │[50:19]   │ [18]   │ [17:16]  │  [15]    │  [14]    │ [13:9]  │ [8:7]   │  [6:4]   │  [3:0]   │
└──────┴──────────┴──────────┴──────────┴──────────┴──────────┴───────┴─────────┴─────────┴─────────┴────────┴────────┴──────────┴──────────┘
```

| 信号 | 要它干嘛 |
|---|---|
| `npc_op` | EX 阶段判断分支/JALR 跳转 |
| `alu_op` | ALU 操作码 |
| `alua_sel` | ALU A 口选 RS1 还是 PC |
| `alub_sel` | ALU B 口选 RS2 还是立即数 |
| `rf_wsel` | WB 阶段写回数据来源 |
| `rf_we` | WB 阶段是否写寄存器 |
| `id_pc` | AUIPC（`pc+ext`）、分支 target（`pc+ext`） |
| `id_pc4` | JAL/JALR 返回地址 |
| `rf_rd1` | ALU A 口 |
| `rf_rd2` | ALU B 口 |
| `ext` | ALU B 口（立即数）、分支 offset、LUI 写回值 |
| `rd` | WB 目标寄存器号 |
| `ram_rop` | MEM 阶段访存读类型，一路传到 MREQ |
| `ram_wop` | MEM 阶段访存写类型，一路传到 MREQ |

> 没有 `rs1`/`rs2`（前推时再加），没有 `debug_pc`（可用 `pc4-4` 反推）。

### 1.3 EX/MEM — 111 bit

```
┌──────┬──────────┬──────────┬──────────┬───────┬─────────┬──────────┬──────────┐
│rd(5) │ ext(32)  │ pc4(32)  │ alu_c(32)│rf_we(1)│rf_wsel(2)│ram_rop(3)│ram_wop(4)│
│[110] │ [105:74] │ [73:42]  │ [41:10]  │  [9]   │  [8:7]   │  [6:4]   │  [3:0]   │
└──────┴──────────┴──────────┴──────────┴───────┴─────────┴──────────┴──────────┘
```

| 信号 | 要它干嘛 |
|---|---|
| `rf_wsel` | WB 写回选择 |
| `rf_we` | WB 写使能 |
| `alu_c` | ALU 运算结果 |
| `pc4` | JAL/JALR 返回地址 |
| `ext` | LUI 写回值 |
| `rd` | 目标寄存器 |
| `ram_rop` | 访存读类型，送入 MEM 阶段 MREQ |
| `ram_wop` | 访存写类型，送入 MEM 阶段 MREQ |

> 没有 `npc_op`/`br`/`br_target`——重定向在 EX 阶段当场处理（见 §3），不等 MEM。

### 1.4 MEM/WB — 104 bit

和 EX/MEM 完全相同。

---

## 2. 三个关键的时序修正

### 2.1 PC 重定向用 EX 当前值，不用 EX/MEM 旧值

这是最容易犯的错。分支指令在 EX 阶段的**当拍**就要算出 target 并改 PC，而不是等它进入 EX/MEM 之后。

```verilog
// ✓ 正确：用 EX 当拍的值
wire ex_br_target;
assign ex_br_target = ex_pc + ex_ext;       // ← EX 当拍算出来的

assign br_redirect   = (ex_npc_op == `NPC_BRA) && br;
assign jalr_redirect = (ex_npc_op == `NPC_JALR);

assign next_pc = br_redirect   ? ex_br_target :   // EX 当拍值
                 jalr_redirect ? alu_c :           // EX 当拍值（ALU 输出）
                 jal_redirect  ? id_jal_target :   // ID 当拍值
                                 pc + 32'h4;

// ✗ 错误：用 mem_br_target / mem_alu_c
// 原因是分支当拍还在 EX，没进 EX/MEM，mem_* 是上一条指令的值
```

### 2.2 JAL 在 ID 阶段跳、分支在 EX 阶段跳

- **JAL**：target = `pc + offset`，offset 就是指令里的立即数，SEXT 在 ID 就算完了 → ID 就能重定向，只浪费 IF/ID 里那 1 条
- **分支**：条件 `br` 要等 ALU 算 → 必须等到 EX，浪费 IF/ID + ID/EX 共 2 条
- **JALR**：target = `rs1 + offset` 也要等 ALU → 同上，浪费 2 条

时序：
```
JAL（ID 跳，浪费 1 条）:
  Cycle N:   JAL 在 IF
  Cycle N+1: JAL 在 ID → jal_redirect=1 → flush IF/ID, PC ← id_jal_target
  Cycle N+2: JAL 在 EX, target 在 ID

分支（EX 跳，浪费 2 条）:
  Cycle N:   BEQ 在 IF
  Cycle N+1: BEQ 在 ID,  BEQ+1 在 IF
  Cycle N+2: BEQ 在 EX → br=1 → flush IF/ID + ID/EX, PC ← ex_br_target
  Cycle N+3: BEQ 在 MEM, target 在 ID
```

### 2.3 冲刷只影响 IF/ID 和 ID/EX，不动后面的

```verilog
assign flush_if_id = jal_redirect | br_redirect | jalr_redirect;
assign flush_id_ex = br_redirect | jalr_redirect;   // JAL 不冲 ID/EX
// EX/MEM 和 MEM/WB 永远不冲
```

跳转指令本身需要正常走完 EX→MEM→WB（JAL/JALR 要写回 `pc4`），所以只冲它后面的指令。

---

## 3. 完整 cpu_core.v 代码

```verilog
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

    // 冲刷信号（各级流水寄存器使用，在 PC 部分赋值）
    wire flush_if_id;
    wire flush_id_ex;

    // ============================================================
    // IF Stage
    // ============================================================
    wire [31:0] pc;
    wire [31:0] pc4;

    assign ifetch_req  = 1'b1;
    assign ifetch_addr = pc;
    assign pc4 = pc + 32'h4;

    wire [31:0] if_inst;
    assign if_inst = ifetch_valid ? ifetch_inst : 32'h13;  // NOP

    // ============================================================
    // IF/ID Pipeline Register
    // ============================================================
    wire [IF_ID_WID-1:0] if_id_dout;

    pipeline_reg #(.WIDTH(IF_ID_WID)) U_IF_ID (
        .clk      (cpu_clk),
        .rst      (cpu_rst),
        .stall    (1'b0),
        .flush    (flush_if_id),
        .din      ({pc, pc4, if_inst}),
        .dout     (if_id_dout)
    );

    wire [31:0] id_pc   = if_id_dout[95:64];
    wire [31:0] id_pc4  = if_id_dout[63:32];
    wire [31:0] id_inst = if_id_dout[31:0];

    // ============================================================
    // ID Stage
    // ============================================================

    // ---- Controller ----
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

    // ---- Register File ----
    wire [31:0] rf_rd1;
    wire [31:0] rf_rd2;

    // 写回信号（在 WB 阶段赋值，此处前向声明供 RF 例化连接）
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

    // ---- Sign Extension ----
    wire [31:0] ext;

    SEXT U_SEXT (
        .op         (sext_op),
        .imm        (id_inst[31:7]),
        .ext        (ext)
    );

    // ---- JAL target & redirect (ID 阶段) ----
    wire [31:0] id_jal_target;
    wire        jal_redirect;
    assign id_jal_target = id_pc + ext;
    assign jal_redirect  = (npc_op == `NPC_JMP);

    // ============================================================
    // ID/EX Pipeline Register
    // ============================================================
    wire [ID_EX_WID-1:0] id_ex_din;
    wire [ID_EX_WID-1:0] id_ex_dout;

    assign id_ex_din = {
        id_inst[11:7],  // rd
        ext,
        rf_rd2,
        rf_rd1,
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
        .flush    (flush_id_ex),
        .din      (id_ex_din),
        .dout     (id_ex_dout)
    );

    // ============================================================
    // EX Stage
    // ============================================================

    // ---- 拆包 ID/EX ----
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

    // ---- ALU ----
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

    // ---- 分支 target & 重定向（EX 阶段） ----
    wire [31:0] ex_br_target;
    wire        br_redirect;
    wire        jalr_redirect;
    assign ex_br_target   = ex_pc + ex_ext;
    assign br_redirect    = (ex_npc_op == `NPC_BRA) && br;
    assign jalr_redirect  = (ex_npc_op == `NPC_JALR);

    // ============================================================
    // EX/MEM Pipeline Register
    // ============================================================
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

    // MREQ: 访存请求 → 总线协议翻译
    wire [ 3:0] da_ren;
    wire [31:0] da_addr;
    wire [ 3:0] da_wen;
    wire [31:0] da_wdata;

    MREQ U_MEM_REQ (
        .ram_addr   (mem_alu_c),
        .ram_rop    (mem_ram_rop),
        .da_ren     (da_ren),
        .da_addr    (da_addr),
        .ram_wop    (mem_ram_wop),
        .ram_wdata  (32'h0),
        .da_wen     (da_wen),
        .da_wdata   (da_wdata)
    );

    // MEXT: 总线返回数据 → 对齐 + 符号扩展
    wire [31:0] ram_ext;
    reg  [ 2:0] mem_ram_rop_r;
    reg  [31:0] mem_alu_c_r;

    MEXT U_MEM_EXT (
        .op         (mem_ram_rop_r),
        .din        (daccess_rdata),
        .byte_offs  (mem_alu_c_r[1:0]),
        .ext        (ram_ext)
    );

    // 保留读类型和地址偏移，供 MEXT 在总线返回时使用
    wire is_ld_st = (mem_ram_rop != `RAM_EXT_N) | (mem_ram_wop != `RAM_WE_N);
    always @(posedge cpu_clk) begin
        if (is_ld_st) begin
            mem_ram_rop_r <= mem_ram_rop;
            mem_alu_c_r   <= mem_alu_c;
        end
    end

    // ============================================================
    // MEM/WB Pipeline Register
    // ============================================================
    wire [MEM_WB_WID-1:0] mem_wb_din;
    wire [MEM_WB_WID-1:0] mem_wb_dout;

    assign mem_wb_din = {
        mem_rd,         // [103:99]
        mem_ext,        // [98:67]
        mem_pc4,        // [66:35]
        mem_alu_c,      // [34:3]
        mem_rf_we,      // [2]
        mem_rf_wsel     // [1:0]
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

    assign rf_we1 = wb_rf_we;
    assign rf_wR  = wb_rd;

    always @(*) begin
        case (wb_rf_wsel)
            `WB_ALU: rf_wD = wb_alu_c;
            `WB_PC4: rf_wD = wb_pc4;
            `WB_EXT: rf_wD = wb_ext;
            default: rf_wD = 32'h0;
        endcase
    end

    // ============================================================
    // PC & 重定向
    // ============================================================

    assign flush_if_id = jal_redirect | br_redirect | jalr_redirect;
    assign flush_id_ex = br_redirect | jalr_redirect;

    wire [31:0] next_pc;
    assign next_pc = br_redirect   ? ex_br_target :
                     jalr_redirect ? alu_c :
                     jal_redirect  ? id_jal_target :
                                     pc + 32'h4;

    PC U_PC (
        .clk        (cpu_clk),
        .rst        (cpu_rst),
        .npc        (next_pc),
        .fetch      (1'b1),
        .pc         (pc)
    );

    // ============================================================
    // Data Access Interface — 连接到总线
    // ============================================================
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            daccess_ren   <= 4'h0;
            daccess_wen   <= 4'h0;
        end else begin
            daccess_ren   <= da_ren;
            daccess_addr  <= da_addr;
            daccess_wen   <= da_wen;
            daccess_wdata <= da_wdata;
        end
    end

    // ============================================================
    // Debug Trace（用 pc4-4 反推 PC，不额外传 debug_pc）
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

    assign debug_wb_pc    = wb_pc4 - 32'h4;      // pc4 - 4 = 原 PC
    assign debug_wb_rf_we = wb_rf_we;
    assign debug_wb_rf_wR = wb_rd;
    assign debug_wb_rf_wD = rf_wD;

    assign debug_mem_pc    = mem_pc4 - 32'h4;    // 同上
    assign debug_mem_we    = daccess_wen;
    assign debug_mem_waddr = daccess_addr;
    assign debug_mem_wdata = daccess_wdata;
`endif

endmodule
```

---



## 4. 测试程序示例

无数据相关，可验证流水线基本通路：

```asm
# ===== ALU 测试（寄存器间无相关） =====
addi x1, x0, 0x100        # x1 由 x0 生成，x0 始终为 0 无冒险
addi x2, x0, 0x200
addi x3, x0, 0x300
# 注意：如果 add x4, x1, x2 紧跟在 addi x2 后面，
# x2 还没写回，x4 会读到旧值 → 需要间隔 ≥2 条指令

# ===== LUI / AUIPC 测试 =====
lui   x5, 0x12345         # x5 = 0x12345000
auipc x6, 0x10000         # x6 = pc + 0x10000000

# ===== JAL 测试 =====
jal x7, skip              # x7 = pc+4, PC 跳转
addi x8, x0, 0x999        # ← 被冲刷
skip:
addi x9, x0, 0x111        # x9 = 0x111

# ===== 分支测试 =====
addi x10, x0, 5           # 等 2 拍
addi x11, x0, 5
nop
nop
beq x10, x11, equal       # 5==5 → 跳转
addi x12, x0, 0xBAD       # ← 被冲刷
equal:
addi x13, x0, 0x222

# ===== JALR 测试 =====
addi x14, x0, 0
nop
nop
jalr x15, x14, 0x40       # x15 = pc+4, PC = x14+0x40
```

> 同一寄存器的写后读必须隔 ≥ 2 条独立指令（WB 在第 5 拍 clk 上升沿写，ID 在第 3 拍组合读，此时读到的是旧值）。

---

