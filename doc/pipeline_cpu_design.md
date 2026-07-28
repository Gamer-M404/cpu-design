# 五级流水线 CPU 设计方案

## 概述

将现有的单周期 CPU（`miniRV_basic_ego1/miniRV_basic/src/rtl/cpu_core.v`）改造为经典 RISC 五级流水线 CPU（IF-ID-EX-MEM-WB），支持 RV32I + M 扩展指令集。

## 流水线结构

```
               +-------+      +-------+      +-------+      +-------+      +-------+
  PC -------->|  IF   |----->|  ID   |----->|  EX   |----->|  MEM  |----->|  WB   |
               +-------+      +-------+      +-------+      +-------+      +-------+
                   |              |              |              |              |
              IF/ID 寄存器    ID/EX 寄存器    EX/MEM 寄存器   MEM/WB 寄存器    写回 RF
```

### 各流水级功能

| 阶段 | 名称 | 功能 |
|------|------|------|
| **IF** | Instruction Fetch | 取指：从 IROM 读取指令 |
| **ID** | Instruction Decode | 译码：解析指令、读寄存器堆、生成控制信号、数据前递 |
| **EX** | Execute | 执行：ALU 运算、分支判断 |
| **MEM** | Memory Access | 访存：读写数据存储器 |
| **WB** | Write Back | 写回：将结果写入寄存器堆 |

## 文件修改清单

| 文件 | 改动 |
|------|------|
| `src/rtl/cpu_core.v` | **完全重写** — 实现五级流水线 |
| 其余文件 | **复用，无需修改** |

### 复用模块（无改动）

- `defines.vh` — 宏定义
- `Controller.v` — 控制单元（译码）
- `RF.v` — 寄存器堆
- `SEXT.v` — 立即数扩展
- `ALU.v` — 算术逻辑单元（含乘法器/除法器）
- `NPC.v` — 下址计算
- `MREQ.v` — 访存请求生成
- `MEXT.v` — 访存数据扩展
- `Inst_ROM.v` — 指令存储器
- `Data_RAM.v` — 数据存储器
- `cpu_top.v` — 顶层模块
- `multiplier.v` / `divider.v` — 乘法器/除法器

## 流水寄存器设计

采用 `<源级><目标级>_<信号>` 命名规范：

| 寄存器 | 接口信号 | 传递内容 |
|--------|---------|---------|
| **IF/ID** | `fd_pc`, `fd_inst` | PC、32位指令机器码 |
| **ID/EX** | `de_*` (17个字段) | PC、控制信号(alu_op/npc_op/sext_op等)、寄存器值(rf_rd1/rf_rd2)、立即数(ext)、寄存器地址(rs1/rs2/rd)、写回控制(rf_we/rf_wsel) |
| **EX/MEM** | `em_*` (14个字段) | PC、ALU结果(alu_c)、分支信息(br)、访存控制(ram_rop/ram_wop)、写回控制、寄存器数据(rf_rd2用于store) |
| **MEM/WB** | `mw_*` (10个字段) | PC、ALU结果、访存扩展数据(ram_ext)、写回控制 |

## 关键技术实现

### 1. 取指逻辑

```verilog
// 暂停取指条件：多周期操作进行中 或 load-use 冲突
wire pause_ifetch = mul_div_stall_flag |
                    (ld_st_active && !ldst_done) |
                    (de_is_ld_st && !ldst_done) |
                    (de_is_mul_div && mul_div_busy) |
                    stall_load_use;

// 取指请求：首次取指 | 连续取指 | 分支跳转 | 暂停后恢复
assign ifetch_req  = !pause_ifetch & (first_req | ifetch_valid | ex_bj_f | resume_ifetch);
assign ifetch_addr = ex_bj_f ? ex_bj_target : pc;
```

- `first_req`：复位后首次取指
- `ifetch_valid`：上一条已取回，立即取下一条（连续取指）
- `ex_bj_f`：分支预测失败，用正确的目标地址取指
- `resume_ifetch`：多周期操作结束，恢复取指

### 2. 数据冒险检测与前递（Forwarding）

#### 三种 RAW 冒险情形

```
情形A (相邻):       I1: add x1, x2, x3    ← 生产者(EX)
                    I2: sub x4, x1, x5    ← 消费者(ID), 需要x1

情形B (间隔1条):    I1: add x1, x2, x3    ← 生产者(MEM)
                    I2: add x5, x6, x7
                    I3: sub x4, x1, x8    ← 消费者(ID), 需要x1

情形C (间隔2条):    I1: add x1, x2, x3    ← 生产者(WB)
                    I2: add x5, x6, x7
                    I3: add x8, x9, x10
                    I4: sub x4, x1, x11   ← 消费者(ID), 需要x1
```

#### 检测逻辑

```verilog
// 情形A：EX阶段冒险（生产者刚从ID进入EX）
// 注意：乘除法运算中的数据不可前递（busy=1时数据未就绪）
wire ex_result_ready = !de_is_mul_div || !mul_div_busy;
wire rs1_ex_hazard = de_rf_we && (de_rd != 0) && (de_rd == id_rs1) && id_rf1 && ex_result_ready;
wire rs2_ex_hazard = de_rf_we && (de_rd != 0) && (de_rd == id_rs2) && id_rf2 && ex_result_ready;

// 情形B：MEM阶段冒险
wire rs1_mem_hazard = em_rf_we && (em_rd != 0) && (em_rd == id_rs1) && id_rf1;
wire rs2_mem_hazard = em_rf_we && (em_rd != 0) && (em_rd == id_rs2) && id_rf2;

// 情形C：WB阶段冒险
wire rs1_wb_hazard = mw_rf_we && (mw_rd != 0) && (mw_rd == id_rs1) && id_rf1;
wire rs2_wb_hazard = mw_rf_we && (mw_rd != 0) && (mw_rd == id_rs2) && id_rf2;
```

其中 `id_rf1`/`id_rf2` 是**读标志信号**，用于判断当前指令是否真正读取 RS1/RS2（避免对 U 型、J 型指令产生误判）。

#### 前递数据源

```verilog
// 数据来源（优先级 EX > MEM > WB，最新数据优先）
wire [31:0] ex_forward_data  = alu_c;
wire [31:0] mem_forward_data = (em_rf_wsel == WB_RAM) ? ram_ext : em_alu_c;
wire [31:0] wb_forward_data  = mw_wb_data;

// RS1 前递选择
wire [31:0] rf_rd1_fw = rs1_ex_hazard  ? ex_forward_data  :
                         rs1_mem_hazard ? mem_forward_data :
                         rs1_wb_hazard  ? wb_forward_data  :
                         rf_rd1_raw;
// RS2 同理
```

### 3. Load-Use 冒险处理

Load 指令的数据在 **MEM 阶段结束** 才可用，比 ALU 指令晚 1 个周期。因此 load-use 冲突需要**暂停 1 个周期 + 插入气泡**。

```
         T0      T1      T2      T3      T4
  lw:    IF  →   ID  →   EX  →  MEM  →  WB
                                    ↓ 前递
 add:            IF  →   ID  → (停) →  EX  → ...
                           ↑
                       检测冲突，插入气泡
```

```verilog
wire load_use_hazard = de_is_ld_st && de_rf_we && (de_rd != 0) &&
                       ((de_rd == id_rs1 && id_rf1) || (de_rd == id_rs2 && id_rf2));

wire stall_load_use = load_use_hazard;
wire flush_id_ex    = stall_load_use;  // ID/EX 插入 NOP（气泡）
```

### 4. 乘除法指令处理（多周期）

乘除法需要多个时钟周期才能完成运算。采用**预暂停**机制：

> 在乘除法指令**还在 ID 阶段时**就设置暂停标志，使其**进入 EX 之前**冻结流水线。

```verilog
// 预暂停：乘除法指令即将进入 ID/EX 时设置标志
always @(posedge cpu_clk) begin
    if (id_is_mul_div && !stall_if_id)
        mul_div_stall_flag <= 1'b1;          // 提前暂停
    else if (!mul_div_busy)
        mul_div_stall_flag <= 1'b0;          // 运算完成，释放
end

wire stall_all = mul_div_stall_flag;          // 冻结 ID/EX, EX/MEM, MEM/WB
```

**时序说明**：
1. 乘除法在 ID 阶段被检测到 → 下一拍 `mul_div_stall_flag=1` 且 mul 进入 EX
2. `stall_all=1` 冻结 EX/MEM（阻止中间结果传播）
3. ALU 内部状态机跟踪运算进度（`op_r` 保存操作码）
4. 运算完成 → `mul_div_busy=0` → 标志清除 → 流水线恢复

### 5. 控制冒险处理（分支预测）

采用**静态预测：默认不跳转**。

```verilog
// 分支判断（在EX阶段）
wire ex_is_branch = (de_npc_op == NPC_BRA);   // 条件分支
wire ex_is_jal    = (de_npc_op == NPC_JMP);   // JAL
wire ex_is_jalr   = (de_npc_op == NPC_JALR);  // JALR

// 跳转条件：条件分支满足 || JAL || JALR
wire ex_bj_f = (ex_is_branch && alu_br) || ex_is_jal || ex_is_jalr;

// 跳转目标地址
wire [31:0] ex_bj_target = (de_npc_op == NPC_JALR) ? {alu_c[31:1], 1'b0}
                                                    : (de_pc + de_ext);

// 分支预测失败：清空 IF/ID 和 ID/EX，PC 重定向
wire ex_flush = ex_bj_f && !stall_all;
```

- 条件分支预测正确（不跳转）：无性能损失
- 条件分支预测失败（跳转）：损失 2 个周期（IF/ID 和 ID/EX 被清空）
- JAL/JALR：总是"预测失败"，损失 2 个周期

### 6. 访存指令处理

由于系统采用**哈佛结构**（独立 IROM 和 DRAM），且 DRAM 在 1 个周期内响应：

- Load/Store 指令自然流经 EX→MEM→WB，无需额外暂停
- 只有 Load-Use 数据冒险需要暂停（见第 3 节）
- 多周期访存（如果 DRAM 延迟 >1 周期）可通过 `ld_st_active` 标志处理

## 流水线暂停机制总结

| 暂停类型 | stall_all | stall_if_id | flush_id_ex | 说明 |
|---------|-----------|-------------|-------------|------|
| **乘除法** | ✓ | ✓ | ✗ | 冻结全部流水级，乘除法保持在 EX |
| **Load-Use** | ✗ | ✓ | ✓ | IF/ID 暂停1拍，ID/EX 插入 NOP（气泡） |
| **分支失败** | ✗ | ✗ | ✓ | 清空 IF/ID 和 ID/EX，PC 重定向 |
| **多周期访存** | ✓ | ✓ | ✗ | 冻结全部流水级，等待访存完成 |

### 寄存器更新逻辑

```verilog
// PC
if (ex_bj_f)      pc <= ex_bj_target;
else if (!stall_if_id) pc <= npc;

// IF/ID 寄存器
if (rst || ex_flush)     → NOP (清空)
else if (!stall_if_id)   → 正常更新
else                     → 保持（暂停）

// ID/EX 寄存器
if (rst || ex_flush || flush_id_ex) → NOP (清空/气泡)
else if (!stall_all)                → 正常更新
else                                → 保持（暂停）

// EX/MEM、MEM/WB 寄存器
if (rst)                → 清零
else if (!stall_all)    → 正常更新
else                    → 保持（暂停）
```

## Debug/Trace 信号

```verilog
// WB 阶段
debug_wb_pc    = mw_pc;           // 写回指令的 PC
debug_wb_rf_we = mw_rf_we_actual; // 寄存器写使能
debug_wb_rf_wR = mw_rd;           // 目标寄存器号
debug_wb_rf_wD = mw_wb_data;      // 写回数据

// MEM 阶段
debug_mem_pc    = em_pc;          // 访存指令的 PC
debug_mem_we    = daccess_wen;    // 写使能
debug_mem_waddr = daccess_addr;   // 写地址
debug_mem_wdata = daccess_wdata;  // 写数据
```

## 验证方案

### 1. 理想流水线测试

使用无相关性、无访存、无乘除法的简单指令序列验证基本流水线架构：

```asm
xori  t0, zero, 1
ori   t1, zero, 2
addi  t2, zero, 3
lui   t4, 0x4
auipc t5, 0x0
slti  t6, zero, 2
add   s0, t0, t1
```

### 2. 数据前递测试

```asm
addi t0, zero, 5    # t0 = 5
addi t1, t0, 3      # t1 = t0 + 3 = 8 (需要前递)
add  t2, t1, t0     # t2 = t1 + t0 = 13 (需要前递)
```

### 3. Load-Use 暂停测试

```asm
lw   t0, 0(x2)      # 从内存加载
addi t1, t0, 5      # 使用加载结果 (需要暂停1拍+前递)
```

### 4. 分支测试

```asm
addi t0, zero, 1
addi t1, zero, 2
beq  t0, t1, label  # 不跳转
addi t2, zero, 3    # 正确路径
label:
addi t3, zero, 4
```

### 5. 乘除法测试

```asm
addi t0, zero, 10
addi t1, zero, 3
mul  t2, t0, t1     # t2 = 30
div  t3, t0, t1     # t3 = 3
add  t4, t2, t3     # t4 = 33 (需要等待乘除法完成)
```

仿真测试可使用现有的 `src/sim/soc_simple_tb.v` 测试平台。

## 关键设计决策

1. **哈佛结构** — 分离的指令存储器和数据存储器，消除结构冒险
2. **静态分支预测** — 预测不跳转，实现简单，满足课程要求
3. **预暂停机制** — 乘除法在 ID 阶段提前暂停，避免中间结果传播
4. **前递禁止** — 乘除法运算期间禁止 EX 阶段前递（`ex_result_ready` 条件）
5. **气泡插入** — Load-Use 和分支失败通过清空 ID/EX（设为 NOP）实现气泡
