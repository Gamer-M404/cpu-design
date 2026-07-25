# 数据前推 (Data Forwarding) 实现文档

> 参考：哈工大(深圳)「计算机设计与实践」课程 — [数据冒险的处理](https://cpu-design.p.cs-lab.top/lab2-A/4-handleDH/)

---

## 一、问题：RAW 数据冒险三种情形

课程将 RAW 冒险分为三种情形（**检测均发生在 ID 阶段**）：

```
情形 A: 相邻指令 — 第 K 条在 ID，第 K-1 条在 EX
情形 B: 间隔 1 条 — 第 K 条在 ID，第 K-2 条在 MEM
情形 C: 间隔 2 条 — 第 K 条在 ID，第 K-3 条在 WB
```

```
Cycle    IF       ID       EX       MEM      WB
C0       I1
C1       I2       I1
C2       I3       I2       I1                         ← I1 在 EX, I2 在 ID → 情形 A
C3       I4       I3       I2       I1                ← I1 在 MEM, I3 在 ID → 情形 B
C4       I5       I4       I3       I2       I1       ← I1 在 WB,  I4 在 ID → 情形 C
C5                I5       I4       I3       I2       ← I1 已写入 RF, I5 在 ID → 无冒险
```

| 情形 | 检测条件 | 前推来源 | 前推数据 |
|------|----------|----------|----------|
| A | `REG_ID/EX.RD == ID.RS1` 或 `ID.RS2` | EX 阶段 | `alu_c`（当前周期算出的） |
| B | `REG_EX/MEM.RD == ID.RS1` 或 `ID.RS2` | EX/MEM 寄存器 | `mem_alu_c` |
| C | `REG_MEM/WB.RD == ID.RS1` 或 `ID.RS2` | MEM/WB 寄存器 | `wb_alu_c` / `rf_wD` |

> **关键区别**：检测发生在 **ID 阶段**，rs1/rs2 直接从 `id_inst` 取，**不需要**把它们塞进 ID/EX 流水寄存器。

---

## 二、核心思路：在 ID 阶段检测 + 前推

### 2.1 数据通路（对应课程图 4-10）

```
                   ┌──────── 前推通路 ────────┐
                   │  情形 A: alu_c (EX)       │
                   │  情形 B: mem_alu_c (EX/MEM)│
                   │  情形 C: wb_alu_c (MEM/WB) │
                   │                            │
   IF       IF/ID   │   ID        ID/EX    EX   │   EX/MEM   MEM   MEM/WB   WB
  ┌──┐    ┌─────┐  │  ┌────┐    ┌─────┐ ┌────┐ │  ┌─────┐ ┌────┐ ┌─────┐ ┌────┐
  │PC├───→│IF/ID├──┴─→│CU  │    │     │ │ALU │ │  │     │ │    │ │     │ │    │
  └──┘    │     │     │    │    │ID/EX├→│    ├─┴─→│E→/M ├→│MEM ├→│M/WB├→│ WB ├→RF
  IROM→   │pc   │     │RF  │    │     │ │    │    │     │ │    │ │     │ │    │
          │pc4  │     │rD1 ├───→│rf_rd1│ │    │    │alu_c│ │    │ │alu_c│ │rf_wD
          │inst │     │rD2 ├───→│rf_rd2│ │    │    │rf_we│ │    │ │rf_we│
          └─────┘     │    │    │     │ │    │    │rd   │ │    │ │rd   │
                      └────┘    └─────┘ └────┘    └─────┘ └────┘ └─────┘
                         ↑                         ↑                 ↑
                         │    前推 MUX             │                 │
                         │  (插入在 RF 输出        │                 │
                         │   和 ID/EX 输入之间)     │                 │
                         └──────────┬──────────────┘                 │
                                    └────────────────────────────────┘
```

前推的 MUX 插入在 **RF 读输出 → ID/EX 输入** 之间。即：RF 读出的 `rf_rd1`/`rf_rd2` 不是直接送入 ID/EX，而是经过一个 MUX 选择（RF默认值 vs 前推值）后才成为 `id_ex_din` 的一部分。

### 2.2 与课程代码的对应

课程给出的参考实现（情形 C）：

```verilog
wire rs1_id_wb_hazard = (wb_rd == id_rs1) & wb_we & id_rf1 & (wb_rd != 5'h0);
wire rs2_id_wb_hazard = (wb_rd == id_rs2) & wb_we & id_rf2 & (wb_rd != 5'h0);
```

四个条件缺一不可：
1. **`wb_rd == id_rs1`** — 目标寄存器号匹配
2. **`wb_we`** — WB 阶段确实要写寄存器
3. **`id_rf1`** — ID 阶段确实要**读** rs1（防止误判）
4. **`wb_rd != 5'h0`** — x0 不可写，不存在 RAW 冒险

> **`id_rf1` / `id_rf2` 是什么？** 课程特别指出：I 型（除 load）、U 型、J 型指令不一定读两个源寄存器，不区分会导致**误判**。`id_rf1`/`id_rf2` 是"该指令是否确实读取 rs1/rs2"的标志信号。

---

## 三、实现步骤

### 3.1 修改清单

| 文件 | 改动 |
|------|------|
| `cpu_core.v` | ① ID 阶段提取 rs1/rs2；② 加 `id_rf1`/`id_rf2`；③ 加三种情形检测；④ op_datA/op_datB MUX；⑤ 改 id_ex_din；⑥ load-use stall |
| `Controller.v` | 不改（`id_rf1`/`id_rf2` 在 cpu_core 中用指令字段推导即可） |
| `pipeline_reg.v` | 不改 |
| 其他模块 | 不改 |

### 3.2 Step 1：ID 阶段提取 rs1/rs2 + 读写标志

当前 `cpu_core.v` 的 ID 阶段从 `if_id_dout` 中解包出 `id_inst`：

```verilog
wire [31:0] id_inst = if_id_dout[31:0];
```

在 ID 阶段新增以下信号（放在 Controller 例化附近，约 line 85 之后）：

```verilog
// ---- 寄存器号提取（用于前推检测） ----
wire [4:0] id_rs1 = id_inst[19:15];
wire [4:0] id_rs2 = id_inst[24:20];
wire [4:0] id_rd  = id_inst[11:7];

// ---- 读标志：该指令是否确实读取 rs1 / rs2 ----
// 不读取 rs1 的指令: LUI, AUIPC, JAL (只有 JAL 写 rd 但不读 rs1/rs2)
// 不读取 rs2 的指令: 所有 I 型 (ADDI, ORI, SLLI, SRLI, SRAI, XORI, ANDI, SLTI, SLTIU,
//                            LW, LB, LBU, LH, LHU, JALR),
//                    U 型 (LUI, AUIPC), J 型 (JAL)
//
// 简化判断：看 opcode
//   - rs1 被读: 除了 LUI, AUIPC, JAL 之外的所有指令
//   - rs2 被读: 仅 R 型 (opcode==7'b0110011) 和 B 型 (opcode==7'b1100011) 和 S 型 (opcode==7'b0100011)
//
wire [6:0] id_opcode = id_inst[6:0];

// rs1 是否需要读：排除 U 型和 J 型（LUI, AUIPC, JAL）
wire id_rf1;
assign id_rf1 = !(id_opcode == 7'b0110111 ||   // LUI
                  id_opcode == 7'b0010111 ||   // AUIPC
                  id_opcode == 7'b1101111);    // JAL

// rs2 是否需要读：只有 R 型、B 型、S 型
wire id_rf2;
assign id_rf2 = (id_opcode == 7'b0110011) ||   // R-type
                (id_opcode == 7'b1100011) ||   // B-type (BEQ, BNE, etc.)
                (id_opcode == 7'b0100011);     // S-type (SW, SB, SH)
```

### 3.3 Step 2：从 ID/EX、EX/MEM、MEM/WB 提取 rd 和 we

当前设计中，这些信号在 EX 和 MEM 阶段才解包。前推检测需要它们在 **ID 阶段就能被引用**。

**直接从 `id_ex_dout`、`ex_mem_dout`、`mem_wb_dout` 中按位截取**（放在 ID 阶段，约 line 85 之后）：

```verilog
// ---- 从流水寄存器中直接截取 rd 和 rf_we（供 ID 阶段前推检测用） ----

// ID/EX 中的 rd 和 rf_we
// id_ex_din 打包顺序（最高位到最低位）:
//   [183:179] rd (id_inst[11:7])
//   ...
//   [18]      rf_we
wire [4:0] id_ex_rd   = id_ex_dout[183:179];
wire       id_ex_rf_we = id_ex_dout[18];

// EX/MEM 中的 rd 和 rf_we
// ex_mem_din 打包顺序:
//   [110:106] rd
//   ...
//   [9]       rf_we
wire [4:0] ex_mem_rd   = ex_mem_dout[110:106];
wire       ex_mem_rf_we = ex_mem_dout[9];

// MEM/WB 中的 rd 和 rf_we
// mem_wb_din 打包顺序:
//   [103:99]  rd
//   ...
//   [2]       rf_we
wire [4:0] mem_wb_rd   = mem_wb_dout[103:99];
wire       mem_wb_rf_we = mem_wb_dout[2];
```

### 3.4 Step 3：三种 RAW 情形检测（课程 §1）

放在 ID 阶段，rs1/rs2 提取之后：

```verilog
// ============================================================
// RAW 数据冒险检测（全部在 ID 阶段）
// ============================================================

// ---- 情形 A：相邻指令，producer 在 EX ----
// 检测: REG_ID/EX.RD == ID.RS1/RS2
// 数据来源: alu_c（EX 阶段组合逻辑输出，当前周期）
wire rs1_ex_hazard;
wire rs2_ex_hazard;
assign rs1_ex_hazard = (id_ex_rd == id_rs1) & id_ex_rf_we & id_rf1 & (id_ex_rd != 5'h0);
assign rs2_ex_hazard = (id_ex_rd == id_rs2) & id_ex_rf_we & id_rf2 & (id_ex_rd != 5'h0);

// ---- 情形 B：间隔 1 条，producer 在 MEM ----
// 检测: REG_EX/MEM.RD == ID.RS1/RS2
// 数据来源: ex_mem_dout 中的 alu_c
wire rs1_mem_hazard;
wire rs2_mem_hazard;
assign rs1_mem_hazard = (ex_mem_rd == id_rs1) & ex_mem_rf_we & id_rf1 & (ex_mem_rd != 5'h0);
assign rs2_mem_hazard = (ex_mem_rd == id_rs2) & ex_mem_rf_we & id_rf2 & (ex_mem_rd != 5'h0);

// ---- 情形 C：间隔 2 条，producer 在 WB ----
// 检测: REG_MEM/WB.RD == ID.RS1/RS2
// 数据来源: rf_wD（WB 阶段组合逻辑输出，也就是 mem_wb_dout 中的 alu_c/pc4/ext）
wire rs1_wb_hazard;
wire rs2_wb_hazard;
assign rs1_wb_hazard = (mem_wb_rd == id_rs1) & mem_wb_rf_we & id_rf1 & (mem_wb_rd != 5'h0);
assign rs2_wb_hazard = (mem_wb_rd == id_rs2) & mem_wb_rf_we & id_rf2 & (mem_wb_rd != 5'h0);
```

### 3.5 Step 4：前推数据选择 → op_datA / op_datB

前推 MUX 在 ID 阶段，将选中的数据替换 RF 的 `rf_rd1`/`rf_rd2`，然后送入 ID/EX 的 `id_ex_din`。

**前推数据来源**：

| 情形 | 数据信号 | 说明 |
|------|----------|------|
| A (EX) | `alu_c` | EX 阶段 ALU 组合逻辑输出，当前周期即有效 |
| B (MEM) | `ex_mem_alu_c` | EX/MEM[41:10]，前一周期的 ALU 结果 |
| C (WB) | `rf_wD` | WB 阶段组合逻辑，综合了 ALU/PC4/EXT 选择 |

> **注意情形 A 的特殊性**：当 producer 在 EX 且 consumer 在 ID，producer 的 ALU 结果 `alu_c` 在当前周期是组合逻辑输出，**还没被锁存到 EX/MEM**。需要直接从 `alu_c` 连线到 ID 阶段的前推 MUX。

对应课程图 4-9 中"EXE→ID"的紫色箭头。

```verilog
// ---- 前推数据选择 ----
// 优先级：EX > MEM > WB（最近的結果優先）
// 每个源操作数一个 MUX

// EX/MEM 中的 alu_c（位号 [41:10]）
wire [31:0] ex_mem_alu_c = ex_mem_dout[41:10];

// A 口（rs1）的前推数据
wire [31:0] op_datA;
assign op_datA = rs1_ex_hazard ? alu_c        :   // 情形 A: 从 EX 的 alu_c 拿
                 rs1_mem_hazard ? ex_mem_alu_c :   // 情形 B: 从 EX/MEM 拿
                 rs1_wb_hazard ? rf_wD         :   // 情形 C: 从 WB 的 rf_wD 拿
                                 rf_rd1;           // 默认: RF 读出值

// B 口（rs2）的前推数据
wire [31:0] op_datB;
assign op_datB = rs2_ex_hazard ? alu_c        :
                 rs2_mem_hazard ? ex_mem_alu_c :
                 rs2_wb_hazard ? rf_wD         :
                                 rf_rd2;
```

### 3.6 Step 5：修改 id_ex_din 使用 op_datA / op_datB

```verilog
// 原来:
assign id_ex_din = {
    id_inst[11:7],
    ext,
    rf_rd2,       // ← 替换
    rf_rd1,       // ← 替换
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

// 改为:
assign id_ex_din = {
    id_inst[11:7],    // rd  (5 bits)
    ext,              // 32 bits
    op_datB,          // 32 bits — 前推后的 rs2 数据
    op_datA,          // 32 bits — 前推后的 rs1 数据
    id_pc4,           // 32 bits
    id_pc,            // 32 bits
    rf_we,            // 1 bit
    rf_wsel,          // 2 bits
    alub_sel,         // 1 bit
    alua_sel,         // 1 bit
    alu_op,           // 5 bits
    npc_op,           // 2 bits
    ram_rop,          // 3 bits
    ram_wop           // 4 bits
};
```

> **ID_EX_WID 不变，仍为 184！** 因为只替换了 rf_rd1/rf_rd2 的数据内容，没有增加新字段。

### 3.7 Step 6：Load-Use 冒险检测 + 停顿

**为什么前推无法解决 Load-Use**（课程思考题）：

```
lw  t0, 0(t1)    # t0 在 MEM 阶段末尾（daccess_rvalid=1 时）才拿到
add t2, t0, t3   # 在 EX 阶段就需要 t0 → 即使用前推也来不及
```

Load 数据要到 MEM 末尾才从总线返回，而 consumer 在 EX 阶段就需要。前推无法跨越这个时间差——**必须停顿 1 拍**。

```verilog
// ---- Load-Use 冒险检测 ----
// ID/EX 中是 load 指令，且其 rd == IF/ID 中指令的 rs1 或 rs2
wire [2:0] id_ex_ram_rop = id_ex_dout[6:4];   // ram_rop 在 ID/EX 中的位号不变

wire load_use_hazard;
assign load_use_hazard =
    (id_ex_ram_rop != `RAM_EXT_N) &&        // ID/EX 是 load (ram_rop != 0)
    (id_ex_rd != 5'h0) &&                   // 目标不是 x0
    ((id_ex_rd == id_rs1 & id_rf1) ||       // rd == rs1 且 rs1 确实被读
     (id_ex_rd == id_rs2 & id_rf2));        // rd == rs2 且 rs2 确实被读
```

**停顿控制逻辑**：

```verilog
// ---- 流水线 stall ----
wire pipe_stall;
assign pipe_stall = load_use_hazard;

// IF/ID: 原来只有 if_stall（取指未就绪）
// 原来:
// assign if_stall = !ifetch_valid;
// 改为：
wire if_stall;
assign if_stall = !ifetch_valid | pipe_stall;

// ID/EX: load-use 时插入气泡（flush）
// 原来:
pipeline_reg #(.WIDTH(ID_EX_WID)) U_ID_EX (
    .stall    (1'b0),
    .flush    (flush_id_ex),
    ...
);
// 改为:
pipeline_reg #(.WIDTH(ID_EX_WID)) U_ID_EX (
    .stall    (1'b0),
    .flush    (flush_id_ex | pipe_stall),
    ...
);

// PC 也要停顿（否则 load-use 停顿时会重复取指）
// 原来:
wire pc_fetch;
assign pc_fetch = !if_stall | jal_redirect | br_redirect | jalr_redirect;
// 改为:
wire pc_fetch;
assign pc_fetch = (!ifetch_valid && !pipe_stall)  // 改为 &&：两个条件都满足才取指
                  | jal_redirect | br_redirect | jalr_redirect;
```

> **仔细看 `pc_fetch` 的修改**：原来的 `!if_stall` 展开是 `ifetch_valid`。现在增加 `pipe_stall` 后，条件变为"取指就绪 **且** 不在 load-use 停顿"才能正常 PC+4。但跳转发生时（redirect）仍然要无条件更新 PC，所以跳转项不受 `&&` 约束。

### 3.8 EX 阶段无需修改

因为前推已经在 ID 阶段完成，`op_datA`/`op_datB` 已经是正确的值，被锁入 ID/EX 后变为 `ex_rf_rd1`/`ex_rf_rd2`。EX 阶段的 ALU 输入保持不变：

```verilog
// 保持不变！因为前推值已经通过 op_datA/op_datB 进入了 ID/EX
assign alu_a = ex_alua_sel ? ex_pc : ex_rf_rd1;
assign alu_b = ex_alub_sel ? ex_ext : ex_rf_rd2;
```

---

## 四、改动汇总

```
cpu_core.v 改动清单（按代码位置从上到下）:
┌──────┬────────────────────────────────────────────┬──────────┐
│ 位置  │ 改动                                        │ 行数     │
├──────┼────────────────────────────────────────────┼──────────┤
│ ID    │ 新增: id_rs1, id_rs2, id_rd 提取           │ ~3 行    │
│ ID    │ 新增: id_rf1, id_rf2 读标志                │ ~15 行   │
│ ID    │ 新增: id_ex_rd, ex_mem_rd, mem_wb_rd 等    │ ~12 行   │
│ ID    │ 新增: 三种 RAW 情形检测 (A/B/C)            │ ~16 行   │
│ ID    │ 新增: op_datA/op_datB 前推 MUX             │ ~12 行   │
│ ID    │ 新增: load_use_hazard 检测                 │ ~6 行    │
│ ID    │ 修改: id_ex_din — rf_rd1→op_datA 等       │ 改 2 行  │
│ ID    │ 修改: if_stall 加 pipe_stall               │ 改 1 行  │
│ ID    │ 修改: U_ID_EX flush 加 pipe_stall          │ 改 1 行  │
│ ID    │ 修改: pc_fetch                            │ 改 1 行  │
│ EX    │ 不修改！                                   │ 0 行     │
├──────┼────────────────────────────────────────────┼──────────┤
│ 合计  │                                            │ ~70 行   │
└──────┴────────────────────────────────────────────┴──────────┘
```

**不需要改动的文件**：`pipeline_reg.v`, `Controller.v`, `ALU.v`, `RF.v`, `SEXT.v`, `MREQ.v`, `MEXT.v`, `PC.v`, `cpu_top.v`

**不需要修改 `ID_EX_WID`**（与之前方案的关键区别）。

---

## 五、与课程实现的对照

| 课程概念 | 本实现中的对应 |
|----------|---------------|
| `REG_ID/EX.RD` | `id_ex_rd`（从 `id_ex_dout[183:179]` 截取） |
| `REG_EX/MEM.RD` | `ex_mem_rd`（从 `ex_mem_dout[110:106]` 截取） |
| `REG_MEM/WB.RD` | `mem_wb_rd`（从 `mem_wb_dout[103:99]` 截取） |
| `ID.RS1` | `id_rs1` = `id_inst[19:15]` |
| `ID.RS2` | `id_rs2` = `id_inst[24:20]` |
| `id_rf1` | 组合逻辑：opcode 非 LUI/AUIPC/JAL 时 = 1 |
| `id_rf2` | 组合逻辑：opcode 为 R/B/S 型时 = 1 |
| `wb_we` | `mem_wb_rf_we`（从 `mem_wb_dout[2]` 截取） |
| `forward_dat` | `op_datA` / `op_datB`（前推 MUX 输出） |
| `original_opA` | `rf_rd1`（RF 原始读出值） |
| 课程参考 RTL 的 `always @(posedge)` | 本实现中，通过组合逻辑 MUX + `id_ex_din` 在 pipeline_reg 的 posedge 捕获，效果等价 |

---

## 六、验证方案

### 6.1 零 NOP 测试汇编

前推实现后，以下紧密排列的指令序列必须全部通过：

```asm
.section .text.init
.globl _start

_start:
    jal x0, reset_vector

reset_vector:
    # === 情形 A 测试：背靠背 (producer 在 EX, consumer 在 ID) ===
    addi t0, zero, 1       # t0 = 1
    addi t1, t0,   0       # t1 = t0 (需前推自 EX)  → t1 = 1

    # === 情形 B 测试：隔 1 条 (producer 在 MEM) ===
    addi t2, zero, 3       # t2 = 3
    addi x0, x0, 0         # NOP
    addi t3, t2, 0         # t3 = t2 (需前推自 EX/MEM) → t3 = 3

    # === 情形 C 测试：隔 2 条 (producer 在 WB) ===
    addi s0, zero, 5       # s0 = 5
    addi x0, x0, 0
    addi x0, x0, 0
    addi s1, s0, 0         # s1 = s0 (需前推自 MEM/WB) → s1 = 5

    # === 双重匹配：两个 producer 写同一寄存器 ===
    addi t0, zero, 10      # t0 = 10 (覆盖之前的值)
    addi t0, zero, 20      # t0 = 20
    addi t4, t0, 0         # t4 = 20 (应取最近的，即 EX 前推)

    # === 验证 t1 == 1 ===
    addi x28, zero, 1
    bne  t1, x28, fail

    # === 验证 t3 == 3 ===
    addi x28, zero, 3
    bne  t3, x28, fail

    # === 验证 s1 == 5 ===
    addi x28, zero, 5
    bne  s1, x28, fail

    # === 验证 t4 == 20 (优先取最新的) ===
    addi x28, zero, 20
    bne  t4, x28, fail

    # Pass
    addi x17, x0, 93
    addi x10, x0, 0
    ecall

fail:
    addi x17, x0, 93
    addi x10, x0, 1
    ecall
```

> **注意**：检查代码（setter → bne consumer）之间仍然需要 3 个 NOP，因为 bne 读 x28 时存在 RAW 冒险——前推只能覆盖 ALU 操作数，bne 的比较在 EX 阶段也会被前推到，但如果 setter 是 addi 产生 x28，bne 是 consumer 读 x28 和 t0，这两种情况你都需要前推。实际验证时，可以在 difftest 框架下运行，它逐条比对写回结果，不需要在汇编里自检。

### 6.2 各情形的测试覆盖

| 情形 | 测试指令对 | 前推来源 | 期望结果 |
|------|-----------|----------|----------|
| A | `addi t0,zero,1` → `addi t1,t0,0` | alu_c (EX) | t1 = 1 |
| B | `addi t2,zero,3` → NOP → `addi t3,t2,0` | ex_mem_alu_c | t3 = 3 |
| C | `addi s0,zero,5` → NOP×2 → `addi s1,s0,0` | rf_wD (WB) | s1 = 5 |
| 双重匹配 (EX优先) | `addi t0,zero,10` → `addi t0,zero,20` → `addi t4,t0,0` | alu_c (EX, 更新) | t4 = 20 |
| 无依赖 | `addi t0,zero,1` → `addi t1,zero,2` → `add t2,t0,t1` | 各取自 EX/MEM+RF | t2 = 3 |

---

## 七、效果

| 维度 | 修改前 | 修改后 |
|------|--------|--------|
| 相邻指令 RAW | 需 3 NOP | **0 NOP** |
| 隔 1 条 RAW | 需 3 NOP | **0 NOP** |
| 隔 2 条 RAW | 需 3 NOP | **0 NOP** |
| Load-Use | — | 需 1 拍 stall（硬件自动） |
| CPI（ALU 密集） | ~4 | **~1** |
| 代码膨胀 | 3× | **1×** |
| 关键路径增长 | — | alu_c → op_datA → ID/EX（情形 A 的组合路径略增） |
