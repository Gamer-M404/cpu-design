# 数据前推实现 — 修改总结

## 修改文件

仅 `cpu_core.v`，共 ~100 行新增/修改。

---

## 修改一：添加 ID 阶段前推检测基础设施

### 1.1 提取 rs1/rs2/rd 寄存器号（line 72-74）

```verilog
wire [4:0] id_rs1 = id_inst[19:15];
wire [4:0] id_rs2 = id_inst[24:20];
wire [4:0] id_rd  = id_inst[11:7];
```

### 1.2 添加 id_rf1 / id_rf2 读标志（line 79-87）

防止 I 型、U 型、J 型指令的 RAW 误判（参考课程 §1.3）：

```verilog
wire id_rf1;
assign id_rf1 = !(id_opcode == 7'b0110111 ||   // LUI
                  id_opcode == 7'b0010111 ||   // AUIPC
                  id_opcode == 7'b1101111);    // JAL

wire id_rf2;
assign id_rf2 = (id_opcode == 7'b0110011) ||   // R-type
                (id_opcode == 7'b1100011) ||   // B-type
                (id_opcode == 7'b0100011);     // S-type
```

### 1.3 从流水寄存器中提取 rd 和 rf_we（供 ID 阶段引用）

```verilog
// ID/EX (line 208-210)
wire [4:0] id_ex_rd      = id_ex_dout[183:179];
wire       id_ex_rf_we   = id_ex_dout[18];
wire [1:0] id_ex_rf_wsel = id_ex_dout[17:16];   // 前推数据选择用

// EX/MEM (line 295-296)
wire [4:0] ex_mem_rd    = ex_mem_dout[110:106];
wire       ex_mem_rf_we = ex_mem_dout[9];
// mem_rf_wsel 沿用已有的 mem_rf_wsel = ex_mem_dout[8:7]

// MEM/WB (line 391-392)
wire [4:0] mem_wb_rd    = mem_wb_dout[103:99];
wire       mem_wb_rf_we = mem_wb_dout[2];
```

---

## 修改二：RAW 三种情形检测（课程 §1.1-§1.3）

检测全部在 **ID 阶段**，比较流水线寄存器中的 rd 与当前指令的 rs1/rs2。

### 情形 A：producer 在 EX，consumer 在 ID（line 213-216）

```verilog
wire rs1_ex_hazard;
wire rs2_ex_hazard;
assign rs1_ex_hazard = (id_ex_rd == id_rs1) & id_ex_rf_we & id_rf1 & (id_ex_rd != 5'h0);
assign rs2_ex_hazard = (id_ex_rd == id_rs2) & id_ex_rf_we & id_rf2 & (id_ex_rd != 5'h0);
```

### 情形 B：producer 在 MEM，consumer 在 ID（line 298-301）

```verilog
wire rs1_mem_hazard;
wire rs2_mem_hazard;
assign rs1_mem_hazard = (ex_mem_rd == id_rs1) & ex_mem_rf_we & id_rf1 & (ex_mem_rd != 5'h0);
assign rs2_mem_hazard = (ex_mem_rd == id_rs2) & ex_mem_rf_we & id_rf2 & (ex_mem_rd != 5'h0);
```

### 情形 C：producer 在 WB，consumer 在 ID（line 394-398）

```verilog
wire rs1_wb_hazard;
wire rs2_wb_hazard;
assign rs1_wb_hazard = (mem_wb_rd == id_rs1) & mem_wb_rf_we & id_rf1 & (mem_wb_rd != 5'h0);
assign rs2_wb_hazard = (mem_wb_rd == id_rs2) & mem_wb_rf_we & id_rf2 & (mem_wb_rd != 5'h0);
```

四种条件缺一不可：① rd 匹配、② 真写寄存器、③ 真读源寄存器、④ rd ≠ x0。

---

## 修改三：前推数据选择 — 根据 rf_wsel 选择正确的数据源

> **这是最关键的修正。** 初版直接取 `alu_c`，但 LUI/JAL/Load 的真实结果不在 ALU 输出中。

### 情形 A 前推数据（line 305-310）

Producer 在 EX，根据 `id_ex_rf_wsel` 选择：

```verilog
wire [31:0] ex_fwd_data;
assign ex_fwd_data = (id_ex_rf_wsel == `WB_ALU) ? alu_c                :
                     (id_ex_rf_wsel == `WB_PC4) ? id_ex_dout[82:51]  : // ex_pc4
                     (id_ex_rf_wsel == `WB_EXT) ? id_ex_dout[178:147]: // ex_ext
                                                  alu_c;
```

### 情形 B 前推数据（line 312-317）

Producer 在 MEM，根据 `mem_rf_wsel` 选择：

```verilog
wire [31:0] mem_fwd_data;
assign mem_fwd_data = (mem_rf_wsel == `WB_ALU) ? ex_mem_dout[41:10]  : // mem_alu_c
                      (mem_rf_wsel == `WB_PC4) ? ex_mem_dout[73:42]  : // mem_pc4
                      (mem_rf_wsel == `WB_EXT) ? ex_mem_dout[105:74] : // mem_ext
                                                 ex_mem_dout[41:10];
```

### 情形 C 前推数据

直接使用 `rf_wD`（WB 阶段已经过 MUX，无需再区分类型）。

### 前推 MUX（line 319-329）

```verilog
wire [31:0] op_datA;
assign op_datA = rs1_ex_hazard ? ex_fwd_data :
                 rs1_mem_hazard ? mem_fwd_data :
                 rs1_wb_hazard ? rf_wD :
                                 rf_rd1;

wire [31:0] op_datB;
assign op_datB = rs2_ex_hazard ? ex_fwd_data :
                 rs2_mem_hazard ? mem_fwd_data :
                 rs2_wb_hazard ? rf_wD :
                                 rf_rd2;
```

---

## 修改四：id_ex_din 使用前推后的操作数（line 160-165）

```verilog
assign id_ex_din = {
    id_inst[11:7],
    ext,
    op_datB,      // ← 替换原来的 rf_rd2
    op_datA,      // ← 替换原来的 rf_rd1
    id_pc4,
    id_pc,
    rf_we,
    rf_wsel,
    ...
};
```

> 位宽和位号完全不变，`ID_EX_WID` 保持 184。EX 阶段解包代码不需要任何改动。

---

## 修改五：Load-Use 冒险检测 + 停顿（line 219-226）

前推无法解决 load-use（load 数据到 MEM 末尾才拿到，consumer 在 EX 就需要）。

```verilog
wire load_use_hazard;
assign load_use_hazard =
    (id_ex_ram_rop != `RAM_EXT_N) &&        // ID/EX 是 load
    (id_ex_rd != 5'h0) &&                   // 目标不是 x0
    ((id_ex_rd == id_rs1 & id_rf1) ||
     (id_ex_rd == id_rs2 & id_rf2));
```

### 停顿控制

```verilog
wire pipe_stall;
assign pipe_stall = load_use_hazard;

// IF/ID stall: 原条件 + load-use 停顿时保持 (line 49)
assign if_stall = !ifetch_valid | pipe_stall;

// ID/EX: load-use 时插入气泡 (line 181)
.flush(flush_id_ex | pipe_stall)

// PC 也停顿 (line 427)
assign pc_fetch = (!if_stall && !pipe_stall) | jal_redirect | br_redirect | jalr_redirect;
```

---

## 修复的 Bug

| Bug | 位置 | 原因 | 后果 |
|-----|------|------|------|
| `load_use_harzard` 拼写 | line 36 | `harzard` → `hazard` | pipe_stall 信号悬空，load-use 停顿完全失效 |
| `ex_mem_rd` 隐式 1-bit | line 295 | `wire ex_mem_rd` → `wire [4:0] ex_mem_rd` | 5-bit rd 截断为 1-bit，情形 B 前推匹配错乱 |
| `op_datB` 未声明 | line 314 | 缺少 `wire [31:0] op_datB;` | 隐式 1-bit，32-bit 数据被截断 |
| `rs2_wb_harard` 拼写 | line 395 | `harard` → `hazard` | 信号不一致，情形 C rs2 检测失效 |
| **前推数据源错误**（最严重） | line 308,315 | 所有情形一律取 `alu_c` | LUI(需ext)、JAL(需pc4)、Load(需mem数据) 前推拿到错误值 |

---

## 测试验证

| 测试 | 状态 |
|------|------|
| `ideal_pipe` (7条用户指令) | ✅ Pass |
| `add` (38个ADD测试用例) | ✅ Pass |

add 测试覆盖了关键场景：
- `lui x2, 0xffff8` → `add x14, x1, x2`（LUI→ADD 前推，验证 ex_fwd_data 选择 ext 而非 alu_c）
- 各种 NOP 间隔（0/1/2 条）的 ADD → ADD 前推

---

## 当前流水线冒险处理状态

| 冒险类型 | 状态 | 方法 |
|----------|------|------|
| RAW 情形 A (ALU→ALU) | ✅ | 前推 `ex_fwd_data`（按 rf_wsel 选择） |
| RAW 情形 A (LUI→*) | ✅ | 前推 `ex_ext` |
| RAW 情形 A (JAL→*) | ✅ | 前推 `ex_pc4` |
| RAW 情形 B | ✅ | 前推 `mem_fwd_data`（按 rf_wsel 选择） |
| RAW 情形 C | ✅ | 前推 `rf_wD` |
| Load-Use | ✅ | ID 检测 + 停顿 1 拍 |
| 控制冒险 (JAL) | ✅ | ID 重定向 + 冲刷 IF/ID |
| 控制冒险 (分支/JALR) | ✅ | EX 重定向 + 冲刷 IF/ID 和 ID/EX |
