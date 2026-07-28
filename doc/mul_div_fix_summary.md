# Mul/Div 指令修复总结

## 概述

在 38/45 测试通过的基础上，修复了 7 个乘除法指令测试（mul, mulh, mulhu, div, divu, rem, remu），最终实现 **45/45 全部通过**。

## 修改文件

| 文件 | 改动类型 |
|------|----------|
| `src/rtl/ALU.v` | 修改 start 标志 + 新增输出端口 |
| `src/rtl/cpu_core.v` | 重写 Stall 机制 + wb_done 抑制 + daccess 保护 |

---

## Bug 1: ALU 乘除法模块无限重启（ALU.v）

### 根因

`mul_flag` 等启动信号是电平敏感的：

```verilog
// 修改前（有 bug）
assign mul_flag  = (op == `ALU_MUL || op == `ALU_MULH) && !mul_busy;
assign mulu_flag = (op == `ALU_MULHU) && !mulu_busy;
assign div_flag  = (op == `ALU_DIV  || op == `ALU_REM) && !div_busy;
assign divu_flag = (op == `ALU_DIVU || op == `ALU_REMU)&& !divu_busy;
```

**时序分析：**

1. 乘法器完成运算 → `mul_busy` 变为 0
2. 此时流水线被冻结（`stall_all=1`），EX 阶段仍保持 `op = MUL`
3. `mul_flag = (op==MUL) && !0 = 1` → **乘法器被再次启动！**
4. 乘法器又进入 CALC 状态 → `busy` 重新变 1 → 永远无法结束
5. 这是一个死循环，流水线被永久卡住

### 修复

给 4 个启动信号都加上 `op_r == 5'h0` 条件，确保只触发一次：

```verilog
// 修改后（修复）
assign mul_flag  = (op == `ALU_MUL || op == `ALU_MULH) && !mul_busy && (op_r == 5'h0);
assign mulu_flag = (op == `ALU_MULHU) && !mulu_busy && (op_r == 5'h0);
assign div_flag  = (op == `ALU_DIV  || op == `ALU_REM) && !div_busy && (op_r == 5'h0);
assign divu_flag = (op == `ALU_DIVU || op == `ALU_REMU)&& !divu_busy && (op_r == 5'h0);
```

**原理：** `op_r` 是 ALU 内部寄存的当前操作码。空闲时为 0，启动后在第一个时钟沿被设为 `op`。运算完成（`busy=0`）后在下一个时钟沿清零。因此 `(op_r == 0)` 恰好标识"尚未启动"状态。

同时新增输出端口供 cpu_core 使用：

```verilog
output wire mul_div_active;        // 新增端口
assign mul_div_active = |op_r;     // op_r 非零表示多周期运算正在进行中
```

---

## Bug 2: 背靠背乘除法指令的 Stall 缺失（cpu_core.v）

### 根因

原来的 Stall 机制用寄存器 `mul_div_stall_flag` 实现预暂停：在乘除法指令还在 ID 阶段时就设标志，下一拍冻结流水线。

```verilog
// 修改前（有 bug）
always @(posedge cpu_clk or posedge cpu_rst) begin
    if (cpu_rst)
        mul_div_stall_flag <= 1'b0;
    else if (id_is_mul_div && !stall_if_id)
        mul_div_stall_flag <= 1'b1;       // mul 在 ID → 预暂停
    else if (!mul_div_busy)
        mul_div_stall_flag <= 1'b0;       // 运算完成 → 释放
end
wire stall_all = mul_div_stall_flag;
```

**背靠背场景时序分析：**

```
mul1 在 EX, mul2 在 ID（被 stall）
...
mul1 完成 → stall_all=0
mul2 进入 EX, mul3 进入 ID
```

- 当 mul1 完成时，`stall_all` 在同一拍清零
- mul2 **在同一拍**从 ID 进入 EX
- 此时 `de_is_mul_div=1`（mul2 在 EX），但 `mul_div_stall_flag=0`（刚清零）
- `stall_all=0` → EX/MEM **没有被冻结**
- 下一拍 EX/MEM 捕获了 mul2 启动时的**中间垃圾数据**

### 修复

用组合逻辑替代寄存器，直接在 EX 阶段检测是否需要 Stall：

```verilog
// 修改后（修复）
// 组合逻辑：当 EX 阶段有乘除法指令，且满足以下任一条件时 Stall：
//   (a) 子模块正在计算（mul_div_busy=1）
//   (b) 子模块还没开始（mul_div_active=0，第一拍）
wire stall_all = de_is_mul_div && (mul_div_busy || !mul_div_active);
```

- 不再依赖 ID 阶段的预判
- 只要 `de_is_mul_div=1`（EX 阶段有 mul/div），立即组合逻辑地拉高 `stall_all`
- 对背靠背场景：mul2 一进入 EX，`stall_all` 立刻为 1，EX/MEM 被冻结
- 删除了 `mul_div_stall_flag` 寄存器及其更新逻辑

---

## Bug 3: Stall 期间写回信号重复触发（cpu_core.v）

### 根因

`stall_all=1` 时，MEM/WB 流水线寄存器被冻结。冻结前已经存在 MEM/WB 中的有效写回（`mw_rf_we=1`）在**每一个时钟周期**都重复出现在 debug 信号上。

```cpp
// Diff Test 框架的行为（test.cpp）
do {
    rtl_trace = top->tick();                      // 每个周期 tick 一次
} while (rtl_trace.wb_rf_we == 0 || ...);        // 直到出现有效写回

check(rtl_trace, model_trace, 0);                 // 与 Golden Model 对比
```

- Stall 期间，每个 tick 都看到同一个写回（MEM/WB 被冻结）
- Diff test 误认为这是多个不同的写回事件
- Golden Model 已经前进到后面的指令 → **PC 不匹配**

### 修复

引入 `wb_done` 标志，在 Stall 的第一拍后将写回标记为"已消费"，后续周期抑制：

```verilog
// 修改后（新增）
reg wb_done;
always @(posedge cpu_clk or posedge cpu_rst) begin
    if (cpu_rst)
        wb_done <= 1'b0;
    else if (!stall_all)
        wb_done <= 1'b0;              // 正常流水：每拍都是新写回
    else if (stall_all && !wb_done)
        wb_done <= 1'b1;              // Stall 第一拍：标记已消费
end

wire mw_rf_we_actual = mw_rf_we && (mw_rd != 5'h0);
wire rf_we_gated = mw_rf_we_actual && !wb_done;   // 门控后的写使能
```

**时序：**

| 周期 | stall_all | wb_done | rf_we_gated | 效果 |
|------|-----------|---------|-------------|------|
| N（stall 前） | 0 | 0 | mw_rf_we | 正常写回 ✓ |
| N+1（stall 第一拍） | 1 | 0 | mw_rf_we | 写回可见（新数据）✓ |
| N+2（stall 第二拍） | 1 | 1 | 0 | **抑制** |
| ... | 1 | 1 | 0 | **抑制** |
| N+K（stall 结束） | 0 | 1→0 | mw_rf_we | 新数据进入，正常写回 ✓ |

`rf_we_gated` 同时用于：
- **寄存器堆写使能**（`RF.we`）：防止 Stall 期间重复写同一值
- **Debug 信号**（`debug_wb_rf_we`）：防止 Diff Test 看到重复事件

---

## Bug 4: Stall 期间 Load 指令的 DRAM 请求被覆盖（cpu_core.v）

### 根因

`daccess_*` 寄存器**没有**被 `stall_all` 门控，每个周期都从 `da_*`（MREQ 组合逻辑输出，来自 EX 阶段信号）更新：

```verilog
// 修改前（有 bug）
always @(posedge cpu_clk or posedge cpu_rst) begin
    if (cpu_rst) begin ... end
    else begin
        daccess_ren   <= da_ren;      // 每周期更新！
        daccess_addr  <= da_addr;     // 每周期更新！
        ...
    end
end
```

**时序分析：**

1. Load 指令进入 MEM 阶段 → `daccess_addr = load_addr`，DRAM 开始读
2. 同一拍 mul 进入 EX → `stall_all=1`，流水线冻结
3. **但是 `daccess_addr` 仍在更新**：被 mul 的 `alu_c`（中间计算值/垃圾值）覆盖
4. DRAM 输出 `data_rdata` 变成 mul 地址对应的随机数据
5. Stall 结束后，Load 到达 WB 阶段 → `mw_ram_ext` 捕获到的是垃圾数据
6. **Load 写回的数据变成 0x00000000（或其他错误值）**

### 修复

用 `!stall_all` 门控 `daccess_*` 的更新：

```verilog
// 修改后（修复）
always @(posedge cpu_clk or posedge cpu_rst) begin
    if (cpu_rst) begin ... end
    else if (!stall_all) begin
        daccess_ren   <= da_ren;
        daccess_addr  <= da_addr;
        daccess_wen   <= da_wen;
        daccess_wdata <= da_wdata;
    end
end
```

Stall 期间 `daccess_addr` 保持 Load 的地址不变，DRAM 持续输出正确的 Load 数据。Stall 结束后 Load 到达 WB，`mw_ram_ext` 捕获到正确的值。

---

## 完整修改清单

### ALU.v

| 行号 | 改动 |
|------|------|
| 15 | 新增 `output wire mul_div_active` 端口 |
| 62 | `mul_flag` 加 `&& (op_r == 5'h0)` |
| 63 | `mulu_flag` 加 `&& (op_r == 5'h0)` |
| 64 | `div_flag` 加 `&& (op_r == 5'h0)` |
| 65 | `divu_flag` 加 `&& (op_r == 5'h0)` |
| 67 | 新增 `assign mul_div_active = \|op_r;` |

### cpu_core.v

| 区域 | 改动 |
|------|------|
| Stall 逻辑 | 删除 `mul_div_stall_flag` 寄存器，改为组合逻辑 `wire stall_all = de_is_mul_div && (mul_div_busy \|\| !mul_div_active);` |
| ALU 例化 | 新增 `.mul_div_active(mul_div_active)` 连接 |
| WB 写回抑制 | 新增 `wb_done` 寄存器 + `rf_we_gated` 门控信号 |
| RF 例化 | `.we(rf_we_gated)` 替代 `.we(mw_rf_we_actual)` |
| Debug 信号 | `debug_wb_*` 改用 `rf_we_gated` 门控 |
| daccess 寄存器 | 新增 `else if (!stall_all)` 门控条件 |

## 测试结果

```
Passed Tests (45):
xor, mulhu, sltu, and, lhu, addi, xori, remu, srai, srl, bne, sll, ori,
jalr, slt, lui, beq, slli, lh, lw, rem, auipc, sra, mulh, divu, sltiu,
mul, or, div, bltu, slti, lbu, sb, start, sh, lb, srli, add, bgeu, blt,
jal, sub, sw, bge, andi

Failed Tests (0):
```
