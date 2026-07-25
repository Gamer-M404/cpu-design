# Load/Store 指令修复文档

## 问题背景

原始 5 级流水线 CPU（`cpu_core.v`）中，load（lw/lh/lb/lbu/lhu）和 store（sw/sh/sb）指令的数据通路**从未正确实现**。具体问题：

| 问题 | 影响 |
|------|------|
| `ram_ext` 未接入 `mem_wb_din` | load 指令写回错误的寄存器值 |
| `WB_RAM` 不在 WB stage case 中 | load 结果无法写入寄存器堆 |
| store data 未传入 EX/MEM | `ram_wdata` 硬编码为 0，store 写入错误数据 |
| DRAM 为寄存器输出（1 拍延迟） | load 数据比黄金模型晚 1 拍，difftest 同步失败 |
| MEXT 使用延迟 1 拍的 `mem_ram_rop_r` | 半字/字节 load 的符号扩展错误 |
| `mem_fwd_data` 未处理 `WB_RAM` | load-use 前推时传入地址而非数据 |

---

## 修复一：DRAM 改为组合逻辑读出

### 文件：`vsrc/ram.v`

**原因**：DRAM 是寄存器输出 (`douta <= mem[addra]` at posedge)，数据比黄金模型晚 1 个周期。difftest 逐拍比较写回结果，1 拍延迟导致同步失败。

**修改**：将读操作从寄存器改为组合逻辑，写操作保持寄存器：

```verilog
// 修改前（寄存器读 + 寄存器写在一起）
always @(posedge clka) begin
    if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
    if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
    if (wea[2]) mem[addra][23:16] <= dina[23:16];
    if (wea[3]) mem[addra][31:24] <= dina[31:24];

    // 寄存器读（1 拍延迟）
    douta <= {wea[3] ? dina[31:24] : mem[addra][31:24],
              wea[2] ? dina[23:16] : mem[addra][23:16],
              wea[1] ? dina[15: 8] : mem[addra][15: 8],
              wea[0] ? dina[ 7: 0] : mem[addra][ 7: 0]};
end

// 修改后（写：寄存器，读：组合逻辑）
// 写法分离
always @(posedge clka) begin
    if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
    if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
    if (wea[2]) mem[addra][23:16] <= dina[23:16];
    if (wea[3]) mem[addra][31:24] <= dina[31:24];
end

// 组合逻辑读（当拍返回数据）
always @(*) begin
    douta = {wea[3] ? dina[31:24] : mem[addra][31:24],
             wea[2] ? dina[23:16] : mem[addra][23:16],
             wea[1] ? dina[15: 8] : mem[addra][15: 8],
             wea[0] ? dina[ 7: 0] : mem[addra][ 7: 0]};
end
```

> **Write-First 行为保留**：若 `wea` 有效，读操作返回 `dina`（正在写入的数据），而非 `mem` 中的旧值。

---

## 修复二：daccess 信号全部改为组合逻辑

### 文件：`cpu_core.v`

**原因**：`daccess_ren`、`daccess_addr`、`daccess_wen`、`daccess_wdata` 原本都是寄存器输出（`<=` at posedge），存在 1 拍延迟。DRAM 已是组合逻辑，这些信号必须同步改为组合逻辑。

**修改**：

```verilog
// 修改前（全部寄存器）
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

// 修改后（全部组合逻辑）
always @(*) begin
    daccess_ren   = cpu_rst ? 4'h0 : da_ren;
    daccess_addr  = cpu_rst ? 32'h0 : da_addr;
    daccess_wen   = cpu_rst ? 4'h0 : da_wen;
    daccess_wdata = cpu_rst ? 32'h0 : da_wdata;
end
```

> **时序说明**：load 指令在 EX/MEM 锁存后进入 MEM 阶段，`mem_alu_c` 更新 → `da_ren`/`da_addr` 更新（组合）→ `daccess_ren`/`daccess_addr` 更新（组合）→ DRAM 读（组合）→ `ram_ext` 有效（组合）→ `mem_wb_din` 更新（组合）→ 下一 posedge MEM/WB 锁存。全部在 1 个周期内完成。

---

## 修复三：Store 数据传入 EX/MEM 流水寄存器

### 文件：`cpu_core.v`

**原因**：store 指令的 `rs2`（要存的数据）未传入 EX/MEM，导致 `MREQ.ram_wdata` 硬编码为 `32'h0`。

### 3.1 扩展 EX_MEM_WID

```verilog
// 修改前
localparam EX_MEM_WID = 111;

// 修改后（增加 32-bit store data 字段）
localparam EX_MEM_WID = 143;   // 111 + 32
```

### 3.2 ex_mem_din 加入 store data

```verilog
// 修改前
assign ex_mem_din = {
    ex_rd,         // [110:106]
    ex_ext,        // [105:74]
    ex_pc4,        // [73:42]
    alu_c,         // [41:10]
    ex_rf_we,      // [9]
    ex_rf_wsel,    // [8:7]
    ex_ram_rop,    // [6:4]
    ex_ram_wop     // [3:0]
};

// 修改后（加入 ex_rf_rd2 = store data）
assign ex_mem_din = {
    ex_rd,         // [142:138]
    ex_ext,        // [137:106]
    ex_pc4,        // [105:74]
    ex_rf_rd2,     // [73:42]  ← store data（已在前推 MUX 中处理）
    alu_c,         // [41:10]
    ex_rf_we,      // [9]
    ex_rf_wsel,    // [8:7]
    ex_ram_rop,    // [6:4]
    ex_ram_wop     // [3:0]
};
```

> **注意**：`ex_rf_rd2` 来自 ID/EX（=`op_datB`），已经过前推 MUX，包含正确的 store data。所有字段位号重新计算，`alu_c` 及以下字段位号不变。

### 3.3 MEM 阶段解包

```verilog
// 新增 store data 字段
wire [ 4:0] mem_rd         = ex_mem_dout[142:138];  // was [110:106]
wire [31:0] mem_ext        = ex_mem_dout[137:106];  // was [105:74]
wire [31:0] mem_pc4        = ex_mem_dout[105:74];   // was [73:42]
wire [31:0] mem_store_data = ex_mem_dout[73:42];    // NEW: store data
wire [31:0] mem_alu_c      = ex_mem_dout[41:10];    // unchanged
// ... 以下字段位号不变
```

### 3.4 MREQ 连接

```verilog
// 修改前
MREQ U_MEM_REQ (
    .ram_wdata  (32'h0),   // 硬编码为 0
    ...
);

// 修改后
MREQ U_MEM_REQ (
    .ram_wdata  (mem_store_data),  // 前推后的 store data
    ...
);
```

---

## 修复四：MEM/WB 数据选择 + WB_RAM

### 文件：`cpu_core.v`

### 4.1 mem_wb_data MUX

```verilog
// 对于 load 指令：写回 ram_ext（从 DRAM 读出的数据）
// 对于其他指令：写回 mem_alu_c（ALU 结果）
wire [31:0] mem_wb_data;
assign mem_wb_data = (mem_ram_rop != `RAM_EXT_N) ? ram_ext : mem_alu_c;

assign mem_wb_din = {
    mem_rd,
    mem_ext,
    mem_pc4,
    mem_wb_data,    // ← 替代原来的 mem_alu_c
    mem_rf_we,
    mem_rf_wsel
};
```

### 4.2 WB stage 增加 WB_RAM 分支

```verilog
// 修改前（缺少 WB_RAM）
always @(*) begin
    case (wb_rf_wsel)
        `WB_ALU: rf_wD = wb_alu_c;
        `WB_PC4: rf_wD = wb_pc4;
        `WB_EXT: rf_wD = wb_ext;
        default: rf_wD = 32'h0;
    endcase
end

// 修改后（新增 WB_RAM）
always @(*) begin
    case (wb_rf_wsel)
        `WB_ALU: rf_wD = wb_alu_c;
        `WB_RAM: rf_wD = wb_alu_c;   // load 数据存在 alu_c 字段
        `WB_PC4: rf_wD = wb_pc4;
        `WB_EXT: rf_wD = wb_ext;
        default: rf_wD = 32'h0;
    endcase
end
```

> **设计决策**：`WB_RAM` 复用 `wb_alu_c` 字段（`mem_wb_dout[34:3]`），因为 `mem_wb_data` 已将 load 数据放在该位置，无需扩展 MEM_WB_WID。

---

## 修复五：MEXT 使用组合逻辑输入

### 文件：`cpu_core.v`

**原因**：MEXT 原本用 `mem_ram_rop_r`（寄存器，延迟 1 拍）和 `mem_alu_c_r`（寄存器，延迟 1 拍）。DRAM 改为组合逻辑后，`daccess_rdata` 当拍有效，但 MEXT 操作码还是上一拍的，导致半字/字节 load 的符号扩展错误。

```verilog
// 修改前
MEXT U_MEM_EXT (
    .op         (mem_ram_rop_r),    // 延迟 1 拍
    .din        (daccess_rdata),
    .byte_offs  (mem_alu_c_r[1:0]), // 延迟 1 拍
    .ext        (ram_ext)
);

// 修改后
MEXT U_MEM_EXT (
    .op         (mem_ram_rop),      // 当前组合逻辑值
    .din        (daccess_rdata),
    .byte_offs  (mem_alu_c[1:0]),   // 当前组合逻辑值
    .ext        (ram_ext)
);
```

> **数据流**：EX/MEM 锁存后 `mem_ram_rop`/`mem_alu_c` 立即更新 → MEXT 立即计算 → `ram_ext` 立即有效 → `mem_wb_data` 立即更新 → 同周期 MEM/WB 锁存。全组合路径，无延迟。

---

## 修复六：前推逻辑增加 WB_RAM 支持

### 文件：`cpu_core.v`

**原因**：load-use 场景下，load 在 MEM 阶段前推时，`mem_fwd_data` 未处理 `WB_RAM`，落入 `default` 分支返回 `mem_alu_c`（地址），而非 `ram_ext`（数据）。

### 6.1 情形 B 前推（MEM → ID）

```verilog
// 修改前（缺少 WB_RAM，default 返回地址）
wire [31:0] mem_fwd_data;
assign mem_fwd_data = (mem_rf_wsel == `WB_ALU) ? mem_alu_c  :
                      (mem_rf_wsel == `WB_PC4) ? mem_pc4    :
                      (mem_rf_wsel == `WB_EXT) ? mem_ext    :
                                                 mem_alu_c;  // ← WRONG for loads

// 修改后（新增 WB_RAM，前推内存数据）
wire [31:0] mem_fwd_data;
assign mem_fwd_data = (mem_rf_wsel == `WB_ALU) ? mem_alu_c  :
                      (mem_rf_wsel == `WB_PC4) ? mem_pc4    :
                      (mem_rf_wsel == `WB_EXT) ? mem_ext    :
                      (mem_rf_wsel == `WB_RAM) ? ram_ext    :  // ← 前推 load 数据
                                                 mem_alu_c;
```

### 6.2 情形 A 前推（EX → ID）

```verilog
// 修改前（load 在 EX 时数据不可用，default 返回地址 → 错误）
wire [31:0] ex_fwd_data;
assign ex_fwd_data = (id_ex_rf_wsel == `WB_ALU) ? alu_c  :
                     (id_ex_rf_wsel == `WB_PC4) ? id_ex_dout[82:51] :
                     (id_ex_rf_wsel == `WB_EXT) ? id_ex_dout[178:147] :
                                                  alu_c;

// 修改后（load 在 EX 时数据不可用，返回 0 并依赖 load-use stall）
wire [31:0] ex_fwd_data;
assign ex_fwd_data = (id_ex_rf_wsel == `WB_ALU) ? alu_c                :
                     (id_ex_rf_wsel == `WB_PC4) ? id_ex_dout[82:51]  :
                     (id_ex_rf_wsel == `WB_EXT) ? id_ex_dout[178:147]:
                     (id_ex_rf_wsel == `WB_RAM) ? 32'h0 :  // load 数据未就绪，由 stall 处理
                                                  alu_c;
```

> **配合机制**：情形 A 的 load-use 由 `load_use_hazard` 检测 + `pipe_stall` 停顿处理，consumer 不会从 EX 阶段取 load 数据；load 进入 MEM 后，数据就绪，由情形 B（`mem_fwd_data`）或情形 C（`rf_wD`）前推。

---

## 完整数据流（修复后）

### Load 指令（以 LW 为例）

```
ID:  RF 读 rs1 → op_datA (前推MUX) → id_ex_din
EX:  ALU 算地址 → alu_c → ex_mem_din
MEM: mem_alu_c → MREQ/da_addr → daccess_addr (组合) → DRAM (组合) → daccess_rdata
     → MEXT(op=mem_ram_rop, combo) → ram_ext → mem_wb_data (MUX选ram_ext)
     → mem_wb_din → MEM/WB 锁存 (next posedge)
WB:  wb_rf_wsel=WB_RAM → rf_wD = wb_alu_c (= ram_ext)
     → RF 写 (next posedge)
```

### Store 指令（以 SW 为例）

```
ID:  RF 读 rs1, rs2 → op_datA, op_datB (前推MUX)
     → op_datB = store data → id_ex_din
EX:  ALU 算地址 → alu_c → ex_mem_din
     ex_rf_rd2 (=op_datB) → ex_mem_din (store data)
MEM: mem_alu_c → MREQ/da_addr → daccess_addr (组合)
     mem_store_data → MREQ/da_wdata → daccess_wdata (组合)
     → DRAM: wea=daccess_wen, dina=daccess_wdata → write-first 写入
WB:  无写回 (rf_we=0)
```

---

## 测试验证

| 测试类型 | 测试名 | 状态 |
|----------|--------|------|
| Load word | `lw` | ✅ |
| Load half | `lh` | ✅ |
| Load byte | `lb` | ✅ |
| Load byte unsigned | `lbu` | ✅ |
| Load half unsigned | `lhu` | ✅ |
| Store word | `sw` | ✅ |
| Store half | `sh` | ✅ |
| Store byte | `sb` | ✅ |
| 回归（ALU） | `add`, `ideal_pipe`, `lui`, `addi`, `sub`, `ori`, `xori`, `andi`, `slti`, `beq`, `bne`, `jal`, `jalr`, `auipc`, `sll`, `slli`, `srl`, `srli`, `sra`, `srai`, `slt`, `sltu`, `and`, `or`, `xor` | ✅ (29/29) |
