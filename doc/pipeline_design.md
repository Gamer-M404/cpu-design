# 五级流水线 CPU — 流水寄存器设计

## 一、五级流水线概览

```
                    前推 (Forwarding)
              ┌─────────────────────────────────┐
              │                                 │
     ┌────┐  │  ┌────┐  ┌────┐  ┌────┐  ┌────┐ │  ┌────┐
PC──→│ IF │─→│IF/ID│─→│ ID │─→│ID/EX│─→│ EX │─→│EX/MEM│─→│ MEM │─→│MEM/WB│─→│ WB │──→ RF
     └────┘  │  └────┘  ├────┤  └────┘  ├────┤  └────┘
              │          │    │          │    │
              │    RF (组合读) │        ALU    MEXT
              │          │    │          │    │
              └──────────┴────┴──────────┴────┘
                    前推检测 + 冒险检测
```

五条指令同时在流水线中，每拍各阶段处理不同的指令：

```
Cycle   IF      ID      EX      MEM     WB
  1     inst0
  2     inst1   inst0
  3     inst2   inst1   inst0
  4     inst3   inst2   inst1   inst0
  5     inst4   inst3   inst2   inst1   inst0
```

## 二、流水寄存器模块（通用）

用一个参数化的通用模块，通过 concatenation（位拼接）把各路信号打包传递：

```verilog
// pipeline_reg.v
// 通用流水线寄存器，支持 stall（停顿）和 flush（冲刷）

module pipeline_reg #(
    parameter WIDTH = 32          // 数据宽度
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 stall,   // 1 = 保持当前值
    input  wire                 flush,   // 1 = 清零（优先级 > stall）
    input  wire [WIDTH-1:0]     din,
    output reg  [WIDTH-1:0]     dout
);

    always @(posedge clk or posedge rst) begin
        if (rst)
            dout <= {WIDTH{1'b0}};
        else if (flush)
            dout <= {WIDTH{1'b0}};
        else if (stall)
            dout <= dout;              // 保持
        else
            dout <= din;               // 正常流动
    end

endmodule
```

### 控制信号优先级

```
rst  >  flush  >  stall  >  正常流动
```

- **rst = 1**：全清零（复位）
- **flush = 1**：全清零（分支预测失败，冲刷错误指令）
- **stall = 1**：保持当前值（流水线中某级卡住了）
- **三者都为 0**：正常打入新值

---

## 三、IF/ID 流水寄存器

从取指进入译码阶段，需要保存 **pc** 和 **指令本身**。

```
IF → [IF/ID] → ID
```

| 信号 | 位宽 | 来源 | 说明 |
|---|---|---|---|
| `if_pc` | 32 | pc (IF阶段) | 当前指令的 PC，debug 用 |
| `if_pc4` | 32 | pc + 4 | PC+4，JAL/JALR 写回时用 |
| `if_inst` | 32 | ifetch_inst | 32 位指令机器码 |

**拼接信号**：

```verilog
// 在 cpu_core.v 中
localparam IF_ID_WID = 32 + 32 + 32;   // 96 bits

wire [IF_ID_WID-1:0] if_id_din;
wire [IF_ID_WID-1:0] if_id_dout;

// 打包: {if_pc, if_pc4, if_inst}
assign if_id_din = {pc, pc4, inst};

// 拆包
wire [31:0] id_pc   = if_id_dout[95:64];
wire [31:0] id_pc4  = if_id_dout[63:32];
wire [31:0] id_inst = if_id_dout[31:0];

pipeline_reg #(.WIDTH(IF_ID_WID)) U_IF_ID (
    .clk      (cpu_clk),
    .rst      (cpu_rst),
    .stall    (stall_if_id),
    .flush    (flush_if_id),
    .din      (if_id_din),
    .dout     (if_id_dout)
);
```

---

## 四、ID/EX 流水寄存器

从译码进入执行阶段。这是**信号最多**的一级——所有控制信号 + 所有操作数。

```
ID → [ID/EX] → EX
```

### 4.1 控制信号组（来自 Controller）

| 信号 | 位宽 | 说明 |
|---|---|---|
| `npc_op` | 2 | 下一条 PC 选择 |
| `rf_wsel` | 2 | 写回数据选择（ALU/PC4/EXT/RAM） |
| `alu_op` | 5 | ALU 操作码 |
| `alua_sel` | 1 | ALU A口选择（RS1/PC） |
| `alub_sel` | 1 | ALU B口选择（RS2/EXT） |
| `ram_rop` | 3 | 读内存操作类型 |
| `ram_wop` | 4 | 写内存操作类型 |
| `rf_we` | 1 | 寄存器写使能 |
| `sext_op` | 3 | 立即数扩展类型 |
| `is_mul` | 1 | 乘法指令标志 |
| `is_div` | 1 | 除法指令标志 |

控制信号合计：2+2+5+1+1+3+4+1+3+1+1 = **24 bits**

### 4.2 数据组

| 信号 | 位宽 | 说明 |
|---|---|---|
| `pc` | 32 | 当前指令PC（AUIPC用） |
| `pc4` | 32 | PC+4（JAL/JALR写回用） |
| `rf_rd1` | 32 | 寄存器读数据1（ALU A口） |
| `rf_rd2` | 32 | 寄存器读数据2（ALU B口 / store data） |
| `ext` | 32 | 立即数扩展结果 |

数据合计：32×5 = **160 bits**

### 4.3 寄存器号（前推检测用）

| 信号 | 位宽 | 说明 |
|---|---|---|
| `rs1` | 5 | 源寄存器1号 |
| `rs2` | 5 | 源寄存器2号 |
| `rd` | 5 | 目标寄存器号（inst[11:7]） |
| `if_pc` | 32 | 指令PC（debug trace用） |

寄存器号+debug合计：5+5+5+32 = **47 bits**

### 4.4 总宽度与打包

```
总位宽: 24 + 160 + 47 = 231 bits
```

```verilog
// 在 cpu_core.v 中
localparam ID_EX_WID = 24 + 160 + 47;   // 231 bits

// 打包顺序（从高位到低位）
wire [ID_EX_WID-1:0] id_ex_din;
wire [ID_EX_WID-1:0] id_ex_dout;

assign id_ex_din = {
    // 控制 (24 bits)
    npc_op,       // 2
    rf_wsel,      // 2
    alu_op,       // 5
    alua_sel,     // 1
    alub_sel,     // 1
    ram_rop,      // 3
    ram_wop,      // 4
    rf_we,        // 1
    sext_op,      // 3
    is_mul,       // 1
    is_div,       // 1
    // 数据 (160 bits)
    id_pc,        // 32
    id_pc4,       // 32
    op_rf_rd1,    // 32  ← 注意：这里用前推后的值
    op_rf_rd2,    // 32  ← 同上
    ext,          // 32
    // 寄存器号 + debug (47 bits)
    id_inst[19:15],   // rs1 (5)
    id_inst[24:20],   // rs2 (5)
    id_inst[11:7],    // rd  (5)
    id_pc             // if_pc for debug (32)
};
```

> **重要**：`op_rf_rd1` 和 `op_rf_rd2` 不是直接从 RF 出来的 `rf_rd1`/`rf_rd2`，而是经过前推 MUX 选择后的值（详见第六章）。Load-use 冒险会在这里引入停顿。

---

## 五、EX/MEM 流水寄存器

从执行进入访存阶段。

```
EX → [EX/MEM] → MEM
```

### 5.1 信号列表

| 信号 | 位宽 | 说明 |
|---|---|---|
| `npc_op` | 2 | 用于分支冲刷判断 |
| `rf_wsel` | 2 | 写回选择 |
| `ram_rop` | 3 | 读操作类型 → MREQ |
| `ram_wop` | 4 | 写操作类型 → MREQ |
| `rf_we` | 1 | 写使能 |
| `alu_c` | 32 | ALU结果（访存地址 / 运算结果） |
| `rf_rd2` | 32 | 寄存器读数据2（store data → MREQ） |
| `pc4` | 32 | PC+4（JAL/JALR写回） |
| `br` | 1 | 分支是否跳转 |
| `rd` | 5 | 目标寄存器号 |
| `is_ld_st` | 1 | 是否为访存指令 → MEM stall判断 |
| `pc` | 32 | debug PC |

总宽度：2+2+3+4+1+32+32+32+1+5+1+32 = **147 bits**

### 5.2 实例化

```verilog
localparam EX_MEM_WID = 147;

wire [EX_MEM_WID-1:0] ex_mem_din;
wire [EX_MEM_WID-1:0] ex_mem_dout;

assign ex_mem_din = {
    npc_op_d,        //  2   来自 ID/EX
    rf_wsel_d,       //  2
    ram_rop_d,       //  3
    ram_wop_d,       //  4
    rf_we_d,         //  1
    alu_c,           // 32   ALU 输出
    rf_rd2_d,        // 32   来自 ID/EX（store data）
    pc4_d,           // 32   来自 ID/EX
    br,              //  1   ALU 输出
    rd_d,            //  5   来自 ID/EX
    is_ld_st_d,      //  1   来自 ID/EX
    id_pc_d          // 32   debug
};

pipeline_reg #(.WIDTH(EX_MEM_WID)) U_EX_MEM (
    .clk      (cpu_clk),
    .rst      (cpu_rst),
    .stall    (stall_ex_mem),
    .flush    (flush_ex_mem),
    .din      (ex_mem_din),
    .dout     (ex_mem_dout)
);
```

---

## 六、MEM/WB 流水寄存器

从访存进入写回阶段。

```
MEM → [MEM/WB] → WB
```

### 6.1 信号列表

| 信号 | 位宽 | 说明 |
|---|---|---|
| `rf_wsel` | 2 | 写回数据选择 |
| `rf_we` | 1 | 寄存器写使能 |
| `alu_c` | 32 | ALU 运算结果 |
| `ram_ext` | 32 | 从 MEXT 出来的 load 数据 |
| `pc4` | 32 | PC+4 |
| `rd` | 5 | 目标寄存器号 |
| `pc` | 32 | debug PC |

总宽度：2+1+32+32+32+5+32 = **136 bits**

### 6.2 实例化

```verilog
localparam MEM_WB_WID = 136;

wire [MEM_WB_WID-1:0] mem_wb_din;
wire [MEM_WB_WID-1:0] mem_wb_dout;

assign mem_wb_din = {
    rf_wsel_e,       //  2   来自 EX/MEM
    rf_we_e,         //  1   来自 EX/MEM
    alu_c_e,         // 32   来自 EX/MEM
    ram_ext,         // 32   MEXT 输出（纯组合，load 时有效）
    pc4_e,           // 32   来自 EX/MEM
    rd_e,            //  5   来自 EX/MEM
    pc_e             // 32   debug
};

pipeline_reg #(.WIDTH(MEM_WB_WID)) U_MEM_WB (
    .clk      (cpu_clk),
    .rst      (cpu_rst),
    .stall    (stall_mem_wb),
    .flush    (flush_mem_wb),
    .din      (mem_wb_din),
    .dout     (mem_wb_dout)
);
```

---

## 七、WB 阶段的连接

MEM/WB 的输出直接驱动写回：

```verilog
// 解包 MEM/WB 输出
wire [ 1:0]  wb_rf_wsel = mem_wb_dout[135:134];
wire         wb_rf_we   = mem_wb_dout[133];
wire [31:0]  wb_alu_c   = mem_wb_dout[132:101];
wire [31:0]  wb_ram_ext = mem_wb_dout[100:69];
wire [31:0]  wb_pc4     = mem_wb_dout[68:37];
wire [ 4:0]  wb_rd      = mem_wb_dout[36:32];
// wire [31:0] wb_pc   = mem_wb_dout[31:0];  // debug

// 写回数据选择（4选1 MUX，纯粹组合逻辑）
reg [31:0] rf_wD;
always @(*) begin
    case (wb_rf_wsel)
        `WB_ALU: rf_wD = wb_alu_c;
        `WB_RAM: rf_wD = wb_ram_ext;
        `WB_PC4: rf_wD = wb_pc4;
        // `WB_EXT: 不再需要（LUI 的 ext 已通过 ALU 旁路）
        default: rf_wD = 32'h0;
    endcase
end

// 寄存器堆写
assign rf_we1 = wb_rf_we;
assign rf_wR  = wb_rd;
// rf_wD 由上述 MUX 驱动
```

> **关键变化**：WB 信号的来源从原来的组合逻辑直连（`inst`, `alu_c`, `ext` 等）全部改为从 MEM/WB 流水寄存器取。

---

## 八、Stall 和 Flush 控制

### 8.1 Stall 条件

| 条件 | 影响的流水寄存器 | 说明 |
|---|---|---|
| **load-use 冒险** | IF/ID, ID/EX stall; EX/MEM 写入 0（气泡） | ID/EX 是 load 且 IF/ID 用到它的目标寄存器 |
| **EX 多周期** | IF/ID, ID/EX stall | mul/div 在执行中（`mul_div_busy = 1`） |
| **MEM 等待** | IF/ID, ID/EX, EX/MEM stall | load/store 在等 `daccess_rvalid` |

### 8.2 Flush 条件

| 条件 | 影响的流水寄存器 | 说明 |
|---|---|---|
| **分支跳转** | IF/ID, ID/EX flush | EX 阶段 `br = 1` 时，冲刷后面的两条指令 |
| **跳转指令** (JAL/JALR) | IF/ID flush | 无条件跳转，冲刷下一条指令 |

### 8.3 控制逻辑实现

```verilog
// ---- Load-Use 冒险检测 ----
// ID/EX 是一条 load (ram_rop != N), 且目标寄存器 rd != 0,
// 且 rd == IF/ID 的 rs1 或 rs2
wire load_use_hazard;
assign load_use_hazard =
    (id_ex_ram_rop != `RAM_EXT_N) &&      // ID/EX 是 load
    (id_ex_rd != 5'h0) &&                 // 目标不是 x0
    ((id_ex_rd == id_inst[19:15]) ||      // rd == rs1
     (id_ex_rd == id_inst[24:20]));       // rd == rs2

// ---- EX 阶段多周期 ----
wire ex_stall;
assign ex_stall = mul_div_busy;           // ALU busy = mul/div 正在算

// ---- MEM 阶段等待 ----
wire mem_stall;
assign mem_stall = (ex_mem_ram_rop != `RAM_EXT_N) && !daccess_rvalid;  // 在等数据
// 或 ex_mem_ram_wop != `RAM_WE_N 且 !daccess_wresp  // store 等待

// ---- 分支跳转 ----
wire branch_flush;
assign branch_flush = (ex_mem_br) || (ex_mem_npc_op == `NPC_JMP)
                    || (ex_mem_npc_op == `NPC_JALR);

// ---- 综合 stall/flush 信号 ----
assign stall_if_id  = load_use_hazard | ex_stall | mem_stall;
assign stall_id_ex  = load_use_hazard | ex_stall | mem_stall;
assign stall_ex_mem = mem_stall;
assign stall_mem_wb = 1'b0;              // WB 级不主动停顿

assign flush_if_id  = branch_flush;
assign flush_id_ex  = branch_flush | (load_use_hazard ? 1'b1 : 1'b0);  // load-use 时向 ID/EX 插入气泡
assign flush_ex_mem = 1'b0;
assign flush_mem_wb = 1'b0;
```

### 8.4 Load-Use 冒险的详细时序

```
         Cycle N      Cycle N+1     Cycle N+2
IF:      lw x1,...    add x3,x1,x4  (正常推进)
ID:                   lw x1,...     add x3,x1,x4
EX:                                 lw x1,...  (x1 还没算出来)
MEM:                                           lw x1,...  (x1 在这一拍可用)
```

检测到 load-use 时（Cycle N+1 的 ID 阶段）：

1. **Cycle N+1**：`stall_if_id = 1`, `stall_id_ex = 1` → IF/ID 和 ID/EX 保持
2. **Cycle N+2**：`stall_if_id = 0`, `stall_id_ex = 0`, 但 `flush_id_ex = 1`
   - IF/ID 正常流动（`add` 继续 → ID/EX）
   - ID/EX 被 flush 清零（上周期卡住的 NOP 不再需要）

实际上更简单的实现：

```verilog
// Load-use: 停顿 1 拍
// Cycle N+1: stall IF/ID, ID/EX 保持; 同时向 ID/EX 的下一级（即 EX）插入气泡
//            → 让 lw 可以进入 EX，但 add 在 ID 中原地踏步
//            → ID/EX 输出被清除（气泡进入 EX）
// Cycle N+2: 恢复正常流动，add 进入 EX
```

更精确的实现：

```verilog
assign stall_pc     = load_use_hazard | ex_stall | mem_stall;  // PC 也停
assign stall_if_id  = load_use_hazard | ex_stall | mem_stall;
assign stall_id_ex  = ex_stall | mem_stall;   // load-use 不休顿 ID/EX...
assign flush_id_ex  = load_use_hazard;        // ...而是冲刷掉它（变NOP）
```

> `stall_if_id` 让 add 保持在 IF/ID；ID/EX 正常打入（lw 进入），同时下一拍 ID/EX 被打入 flushed 值 → add 进入 EX 时已经被清掉了。

---

## 九、PC 的改动

流水线中 PC 的控制变复杂了：

```verilog
// PC 在以下情况需要停顿:
// 1. load-use hazard
// 2. EX 多周期
// 3. MEM 等待
assign pc_fetch = !stall_pc;

// 当分支跳转发生时，需要立即把 PC 设置为跳转目标
// 分支目标 = alu_c（在 EX 阶段算出），或者是 JAL 的 pc+offset
wire [31:0] branch_target;
assign branch_target = (ex_mem_npc_op == `NPC_JMP) ? ex_mem_pc4 + ex_mem_offset
                                                   : ex_mem_alu_c;

// 修改后的 PC
always @(posedge clk or posedge rst) begin
    if (rst)
        pc <= `PC_INIT_VAL;
    else if (branch_flush)
        pc <= branch_target;
    else if (pc_fetch)
        pc <= npc;
end
```

---

## 十、各模块修改总结

```
         修改前                    修改后
         ──────                    ──────
cpu_core.v  ─────────→  大幅重写：
                          - 拆出 5 个阶段
                          - 例化 4 级流水寄存器
                          - WB 信号改从 MEM/WB 取

pipeline_reg.v  ──────→  新文件：通用流水寄存器模块

PC.v           ──────→  加 branch_flush 和 branch_target 输入

Controller.v   ──────→  不改（译码逻辑完全不变）

ALU.v          ──────→  不改（多周期 FSM 不变）

RF.v           ──────→  不改（异步读、同步写满足流水线）

SEXT.v         ──────→  不改

MREQ.v         ──────→  不改

MEXT.v         ──────→  不改

NPC.v          ──────→  微调（可能需要加 offset 端口用于 JMP flush）

multiplier.v   ──────→  不改

divider.v      ──────→  不改
```

---

## 十一、关键注意事项

1. **x0 寄存器**：前推/冒险检测时，rd == 0 表示不写回，不能触发 stall/flush。

2. **WB_EXT 消失**：原设计 LUI 用 `WB_EXT` 写回（ext = imm << 12）。流水线中 LUI 的 ext 在 ID 阶段就进入 ID/EX，然后经过 EX/MEM → MEM/WB。如果保持 WB_EXT 通路，需要在每级流水寄存器中额外传递 ext。更简单的方法是让 LUI 走 ALU（ALU_A = 0, ALU_B = ext → c = ext），或者直接在 WB 阶段用 pc 重新算。**推荐方案**：保持 ext 在 ID/EX 中，并一路传到 MEM/WB，在 WB 四选一中加入 `WB_EXT`。

3. **Store 的数据来源**：`rf_rd2`（要存的数据）需要在 ID/EX 就准备好。如果有前推，需要前推到 `rf_rd2` 通路。

4. **jalr 的 target**：`jalr rd, rs1, offset` → PC = (rs1 + offset) & ~1。这个在 EX 阶段由 ALU 算出。JALR 在 EX 阶段时，IF/ID 中已经取了下一条指令，需要 flush 掉。

5. **NPC 的计算时机**：当前的 NPC 是组合逻辑。在流水线中，NPC 需要在 IF 阶段就确定。但分支条件 `br` 要到 EX 才知道，所以默认按 "不跳转" 预测（NPC = PC+4），跳转发生时再修正。
