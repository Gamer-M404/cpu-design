# 乘除法指令修复文档

## 问题分析

### 乘除法指令的执行机制

ALU 中的乘除法器是**多周期**硬件模块。以 32-bit 乘法器为例（Booth 算法），需要 16~33 个时钟周期才能完成一次计算。

```verilog
// ALU.v — 关键信号
assign mul_flag  = (op == `ALU_MUL || op == `ALU_MULH) && !mul_busy;
assign busy      = mul_busy | mulu_busy | div_busy | divu_busy;

// 结果选择：用 op_r（寄存器保存的操作码）而非 op（传入的新操作码）
always @(*) begin
    case (op_r != 4'h0 ? op_r : op)
        `ALU_MUL  : c = mul_res[31:0];
        `ALU_DIV  : c = div_quo;
        ...
    endcase
end
```

运行时序（以 MUL 为例）：

| 周期 | MUL 状态 | `busy` | `alu_c` |
|------|---------|--------|---------|
| 1 | 进入 EX，`mul_flag=1`，启动乘法器 | 0→1 | 中间结果 |
| 2~33 | 乘法器计算中 | 1 | 中间结果（随 `mul_res` 变化） |
| 34 | 乘法完成 | 1→0 | **最终结果** |

### 为什么当前代码失败

`cpu_core.v` 中 `mul_div_busy` 信号**悬空未用**：

```verilog
// cpu_core.v — line ~237
wire        mul_div_busy;   // ← 从 ALU 输出，但之后再也没有引用

ALU U_ALU (
    ...
    .busy       (mul_div_busy)  // ← 连到 ALU，但接收端无逻辑
);
```

**后果**：乘法器还在计算（`busy=1`），下一条指令已经进入 EX 阶段：

```
周期1: MUL 进入 EX → 启动乘法器 (busy=1)
周期2: 下一条指令进入 EX → ALU 的 op 变成新指令的 op
       op_r 还是 ALU_MUL → c 仍输出 mul_res（中间值 ≠ 正确结果）
       同时乘法器重新启动（因为 op 变化可能触发新的 mul_flag）
```

这导致：
1. **MUL 结果错误**：下一条指令的 ALU 操作干扰了 `c` 的输出
2. **乘法器被错误触发**：新指令的 `op` 可能恰好也是 MUL 操作码，触发重复启动
3. **下一条指令也错**：它用了 MUL 的中间结果或错误数据

---

## 解决方案：多周期 EX 停顿

### 核心思路

当 `mul_div_busy = 1` 时，**停顿** IF/ID、ID/EX 和 EX/MEM，让乘除法指令**独占** EX 阶段直到计算完成。

```
正常流水:
  IF → ID → EX → MEM → WB    (每拍前进)

乘除法流水:
  IF → ID → EX ←→ EX ←→ EX → MEM → WB
            ↑_____|  busy=1   |
                              ↓
                          busy=0，放行
```

### 改动范围

仅 `cpu_core.v`，约 6 行改动。

---

## 实现代码

### Step 1：添加 `ex_stall` 信号

在 EX 阶段解包之后（`mul_div_busy` 连接点附近）添加：

```verilog
// ---- 多周期 EX 停顿：乘除法指令需要多个周期完成 ----
wire ex_stall;
assign ex_stall = mul_div_busy;
```

### Step 2：IF/ID 停顿

```verilog
// 修改前
assign if_stall = !ifetch_valid | pipe_stall;

// 修改后
assign if_stall = !ifetch_valid | pipe_stall | ex_stall;
```

### Step 3：ID/EX 停顿

```verilog
// 修改前
pipeline_reg #(.WIDTH(ID_EX_WID)) U_ID_EX (
    .stall    (1'b0),
    ...
);

// 修改后
pipeline_reg #(.WIDTH(ID_EX_WID)) U_ID_EX (
    .stall    (ex_stall),
    ...
);
```

### Step 4：EX/MEM 停顿

```verilog
// 修改前
pipeline_reg #(.WIDTH(EX_MEM_WID)) U_EX_MEM (
    .stall    (1'b0),
    ...
);

// 修改后
pipeline_reg #(.WIDTH(EX_MEM_WID)) U_EX_MEM (
    .stall    (ex_stall),
    ...
);
```

### Step 5：PC 停顿

```verilog
// 修改前
assign pc_fetch = (!if_stall && !pipe_stall) | jal_redirect | br_redirect | jalr_redirect;

// 修改后
assign pc_fetch = (!if_stall && !pipe_stall && !ex_stall)
                  | jal_redirect | br_redirect | jalr_redirect;
```

---

## 完整运行时序（修复后）

以 `mul x10, x5, x6` 为例：

```
周期     IF      ID      EX          MEM     WB
C1      inst3   inst2   inst1
C2      inst4   inst3   MUL(busy=1)  inst1   ← stall 生效
C3      inst4   inst3   MUL(busy=1)  inst1   ← IF/ID,ID/EX,EX/MEM 全部停
...
C34     inst4   inst3   MUL(busy=0)  ← 计算完成，unstall
C35     inst5   inst4   inst3        MUL     ← MUL 进 MEM
C36     inst6   inst5   inst4        inst3   MUL ← MUL 进 WB，写回正确结果
```

**停顿期间**：
- IF/ID 保持 → 不取新指令
- ID/EX 保持 → inst3 留在 ID，不进入 EX
- EX/MEM 保持 → MUL 留在 EX
- MEM/WB **不停顿** → inst1 正常完成 WB（乘除法之前的老指令继续退休）
- PC 停顿 → 不重复取指

---

## 与 difftest 的兼容性

停顿期间不产生写回（`rf_we=0`），difftest 跳过无写回的 tick，不会误比较。

停顿结束后，MUL 的写回出现在正确的 PC 位置，difftest 正常比较。

**已验证**：类似的 `pipe_stall`（load-use 停顿）机制已通过全部 29 个测试，`ex_stall` 使用相同的停顿模式。

---

## ALU 内部状态保证

停顿期间 ALU 保持正确的内部状态：

```verilog
// op_r 在乘法启动时锁存操作码
always @(posedge clk) begin
    if (mul_flag | mulu_flag | div_flag | divu_flag)
        op_r <= op;        // 启动时锁存 ALU_MUL
    else if (!busy)
        op_r <= 4'h0;      // 完成后清零
end
```

- 停顿期间 `busy=1`：`op_r` 保持不变（`ALU_MUL`）
- 结果选择 `case (op_r != 0 ? op_r : op)`：用 `op_r = ALU_MUL` → `c = mul_res`
- 完成后 `busy=0`：下一个 posedge `op_r <= 0`，同时 EX/MEM 已锁存正确的 `alu_c`

---

## 改动总结

```
cpu_core.v:
  + wire ex_stall = mul_div_busy;               // 1 行
  ~ if_stall: + ex_stall                         // 改 1 行
  ~ U_ID_EX.stall: 1'b0 → ex_stall              // 改 1 行
  ~ U_EX_MEM.stall: 1'b0 → ex_stall             // 改 1 行
  ~ pc_fetch: + !ex_stall                       // 改 1 行
─────────────────────────────────────────────────
  总计: 约 5 行改动，全部在 cpu_core.v
```

> 不需要改动 ALU.v、pipeline_reg.v 或任何其他模块。
