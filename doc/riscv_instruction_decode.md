# RISC-V 指令译码：opcode、funct3、funct7 详解

> 说明：本文档结合 miniRV_basic 项目的 `Controller.v` 实际代码，解释 RISC-V RV32I 指令译码的三级字段如何协同工作，生成硬件控制信号。

---

## 一、三个字段分别表示什么？

RISC-V 基础指令（RV32I）为 **32 位定长指令**。译码器通过硬连线逻辑截取指令中特定位置的比特位：

```
┌────────────┬──────────┬──────────┬──────────┬──────────┐
│  bit[31:25]│ bit[24:20]│ bit[19:15]│ bit[14:12]│ bit[11:7] │ bit[6:0]  │
│   funct7   │   rs2     │   rs1     │   funct3  │   rd      │   opcode  │
│   7 bits   │   5 bits  │   5 bits  │   3 bits  │   5 bits  │   7 bits  │
└────────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
```

### 1.1 Opcode — 指令的"大类标签"（bit[6:0]，7 位）

**作用**：决定指令属于哪种 **格式**（R / I / S / B / U / J 型）以及大致的**操作类别**。

| opcode 值 | 格式 | 类别 | 说明 |
|-----------|------|------|------|
| `0110011` | R-type | 寄存器-寄存器 ALU 运算 | ADD, SUB, AND, OR, XOR, SLT, SLL, SRL, SRA |
| `0010011` | I-type | 寄存器-立即数 ALU 运算 | ADDI, ORI, ANDI, SLLI, SRLI, SRAI, SLTI |
| `0000011` | I-type | Load 访存 | LW, LH, LHU, LB, LBU |
| `0100011` | S-type | Store 访存 | SW, SH, SB |
| `1100011` | B-type | 条件分支 | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| `1101111` | J-type | 无条件跳转 | JAL |
| `1100111` | I-type | 寄存器跳转 | JALR |
| `0110111` | U-type | 加载立即数高位 | LUI |
| `0010111` | U-type | PC 相对偏移 | AUIPC |

> **对应代码**（`Controller.v`）：译码器第一层就是用 opcode 做 wire 赋值，例如：
> ```verilog
> wire r_type  = (opcode == 7'b0110011);
> wire i_type  = (opcode == 7'b0010011);
> wire load    = (opcode == 7'b0000011);
> ```

### 1.2 funct3 — opcode 的"子类细分"（bit[14:12]，3 位）

**作用**：在 opcode 大类下进一步缩小范围，区分**具体运算类型**或**数据宽度**。

**示例 1：R-type 指令中**

| funct3 | 指令 | 含义 |
|--------|------|------|
| `000` | ADD / SUB | 加法 / 减法（由 funct7 最终区分） |
| `001` | SLL | 逻辑左移 |
| `010` | SLT | 有符号比较置位 |
| `011` | SLTU | 无符号比较置位 |
| `100` | XOR | 按位异或 |
| `101` | SRL / SRA | 逻辑右移 / 算术右移（由 funct7 区分） |
| `110` | OR | 按位或 |
| `111` | AND | 按位与 |

**示例 2：Load 指令中**

| funct3 | 指令 | 含义 |
|--------|------|------|
| `000` | LB | 加载字节（符号扩展） |
| `001` | LH | 加载半字（符号扩展） |
| `010` | LW | 加载字 |
| `100` | LBU | 加载字节（零扩展） |
| `101` | LHU | 加载半字（零扩展） |

**示例 3：Branch 指令中**

| funct3 | 指令 | 含义 |
|--------|------|------|
| `000` | BEQ | 相等则分支 |
| `001` | BNE | 不等则分支 |
| `100` | BLT | 小于则分支（有符号） |
| `101` | BGE | 大于等于则分支（有符号） |
| `110` | BLTU | 小于则分支（无符号） |
| `111` | BGEU | 大于等于则分支（无符号） |

> **对应代码**（`Controller.v`）：译码器第二层结合 opcode + funct3 生成具体指令 wire：
> ```verilog
> wire ADDI   = i_type  & (funct3 == 3'b000);
> wire ORI    = i_type  & (funct3 == 3'b110);
> wire SLLI   = i_type  & (funct3 == 3'b001);
> ```

### 1.3 funct7 — 最深层的"扩展标识"（bit[31:25]，7 位）

**作用**：当 opcode + funct3 相同但指令不同时，由 funct7 做最终区分。也用于标识扩展指令集。

**最典型的 case**：

| opcode | funct3 | funct7 | 指令 |
|--------|--------|--------|------|
| `0110011` | `000` | `0000000` | **ADD** |
| `0110011` | `000` | `0100000` | **SUB** |
| `0110011` | `101` | `0000000` | **SRL** |
| `0110011` | `101` | `0100000` | **SRA** |
| `0010011` | `101` | `0000000` | **SRLI** |
| `0010011` | `101` | `0100000` | **SRAI** |

**M 扩展中的示例**：

| opcode | funct3 | funct7 | 指令 |
|--------|--------|--------|------|
| `0110011` | `000` | `0000001` | MUL |
| `0110011` | `001` | `0000001` | MULH |
| `0110011` | `010` | `0000001` | MULHSU |

**规律总结**：
- `funct7 = 7'b0000000`：标准算术/逻辑（ADD、SLL、SLT、XOR、SRL、OR、AND）
- `funct7 = 7'b0100000`：变体（SUB、SRA、SRAI）—— 核心区别在 bit[30] 位
- `funct7 = 7'b0000001`：M 扩展乘除法

> **对应代码**（`Controller.v`）：译码器第三层加入 funct7 条件：
> ```verilog
> wire ADD  = r_type & (funct3 == 3'b000) & (funct7 == 7'b0000000);
> wire SUB  = r_type & (funct3 == 3'b000) & (funct7 == 7'b0100000);
> wire SRL  = r_type & (funct3 == 3'b101) & (funct7 == 7'b0000000);
> wire SRA  = r_type & (funct3 == 3'b101) & (funct7 == 7'b0100000);
> ```

---

## 二、多级漏斗模型：从指令字段到控制信号

```
                    ┌─────────────────────────────────┐
                    │         32-bit 指令              │
                    │  funct7 │ rs2 │ rs1 │ funct3 │ ... │ opcode  │
                    └───┬─────┴─────┴─────┴───┬────┴─────┴───┬────┘
                        │                     │              │
                        ▼                     ▼              ▼
              ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐
              │   funct7[31:25] │  │   funct3[14:12] │  │ opcode[6:0] │
              └────────┬────────┘  └────────┬────────┘  └──────┬──────┘
                       │                    │                   │
                       ▼                    ▼                   ▼
              ╔═══════════════════════════════════════════════════════╗
              ║                  主译码器 (Controller)                ║
              ║         纯组合逻辑：与门 + 或门 + 非门                  ║
              ╚═══════════════╤═══════════════════════════════════════╝
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
   │  第 1 级      │   │  第 2 级      │   │  第 3 级      │
   │  Opcode 译码  │   │  funct3 译码  │   │  funct7 译码  │
   │  → 格式+类别  │   │  → 子类细分   │   │  → 最终区分   │
   └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
          │                   │                   │
          ▼                   ▼                   ▼
   ┌──────────────────────────────────────────────────┐
   │              控制信号 (Control Signals)           │
   │                                                  │
   │  npc_op    rf_we    rf_wsel    sext_op           │
   │  alu_op    alua_sel alub_sel   ram_rop/ram_wop   │
   │  is_mul    is_div   ...                          │
   └──────────────────────┬───────────────────────────┘
                          │
                          ▼
   ┌──────────────────────────────────────────────────┐
   │              数据通路 (Datapath)                  │
   │                                                  │
   │  PC → NPC → RF → SEXT → ALU → MREQ → MEXT → WB  │
   └──────────────────────────────────────────────────┘
```

### 第 1 级：Opcode 决定"走哪条主干道"

译码器首先根据 opcode 确定数据通路的基本走向，产生**大类控制信号**：

| opcode 类型 | ALUSrc | MemRead | MemWrite | Branch | Jump | RegWrite |
|------------|--------|---------|----------|--------|------|----------|
| R-type | RS2（寄存器） | 0 | 0 | 0 | 0 | 1 |
| I-type (ALU) | EXT（立即数） | 0 | 0 | 0 | 0 | 1 |
| Load | EXT（立即数） | 1 | 0 | 0 | 0 | 1 |
| Store | EXT（立即数） | 0 | 1 | 0 | 0 | 0 |
| B-type | RS2（寄存器） | 0 | 0 | 1 | 0 | 0 |
| JAL | — | 0 | 0 | 0 | 1 | 1 |
| JALR | EXT（立即数） | 0 | 0 | 0 | 1 | 1 |
| LUI | EXT（立即数） | 0 | 0 | 0 | 0 | 1 |
| AUIPC | EXT（立即数） | 0 | 0 | 0 | 0 | 1 |

> **对应代码**（`Controller.v` 中的 OR-reduction 信号）：
> ```verilog
> // 哪些指令需要写寄存器？
> wire RF_OP_WE  = ADDI | ORI | SLLI | LW | LUI | JAL;   // 目前8条
>
> // 哪些指令使用立即数作为 ALU 第二操作数？
> wire ALU_B_SEL_EXT = ADDI | ORI | SLLI | LUI | LW;
>
> // 哪些指令要跳转？
> wire NPC_OP_JMP = JAL;
> wire NPC_OP_BRA = BEQ | BNE;
> ```

### 第 2 级：funct3 决定"走哪个岔路"

对于需要 ALU 参与的指令，funct3 决定具体的运算类别：

```
Opcode=0110011 (R-type)
    ├── funct3=000 ──→ {ADD, SUB}     → 需要 funct7 最终区分
    ├── funct3=001 ──→ SLL
    ├── funct3=010 ──→ SLT
    ├── funct3=011 ──→ SLTU
    ├── funct3=100 ──→ XOR
    ├── funct3=101 ──→ {SRL, SRA}     → 需要 funct7 最终区分
    ├── funct3=110 ──→ OR
    └── funct3=111 ──→ AND
```

对于 Load/Store 指令，funct3 决定数据宽度和扩展方式：

```
Opcode=0000011 (Load)
    ├── funct3=000 ──→ LB    (字节，符号扩展)
    ├── funct3=001 ──→ LH    (半字，符号扩展)
    ├── funct3=010 ──→ LW    (字)
    ├── funct3=100 ──→ LBU   (字节，零扩展)
    └── funct3=101 ──→ LHU   (半字，零扩展)
```

### 第 3 级：funct7 做"最终选择"

当 opcode 和 funct3 都相同时，funct7（尤其是 bit[30]）做最后一次区分：

```
Opcode=0110011, funct3=000
    ├── funct7=0000000 ──→ ADD    → ALU_Control = ALU_ADD
    └── funct7=0100000 ──→ SUB    → ALU_Control = ALU_SUB

Opcode=0110011, funct3=101
    ├── funct7=0000000 ──→ SRL    → ALU_Control = ALU_SRL
    └── funct7=0100000 ──→ SRA    → ALU_Control = ALU_SRA
```

> **规律**：RISC-V 设计者用 `funct7` 的 bit[30] 来区分"算术变体"和"逻辑变体"。bit[30]=0 为常规操作，bit[30]=1 为算术变体（SUB/SRA/SRAI）。

---

## 三、在 miniRV Controller.v 中的代码映射

将上述三级漏斗模型对照实际 `Controller.v` 代码结构：

### 3.1 指令识别（decode wires）

```verilog
// === 第 1 级：按 opcode 分类 ===
wire r_type  = (opcode == 7'b0110011);    // R-type ALU
wire i_type  = (opcode == 7'b0010011);    // I-type ALU
wire load    = (opcode == 7'b0000011);    // Load
wire store   = (opcode == 7'b0100011);    // Store
wire branch  = (opcode == 7'b1100011);    // Branch
wire jal     = (opcode == 7'b1101111);    // JAL
wire jalr    = (opcode == 7'b1100111);    // JALR
wire lui     = (opcode == 7'b0110111);    // LUI

// === 第 2+3 级：按 funct3 + funct7 细分 ===
wire ADDI  = i_type  & (funct3 == 3'b000);
wire ORI   = i_type  & (funct3 == 3'b110);
wire SLLI  = i_type  & (funct3 == 3'b001);
// ... 更多指令
wire ADD   = r_type  & (funct3 == 3'b000) & (funct7 == 7'b0000000);
wire SUB   = r_type  & (funct3 == 3'b000) & (funct7 == 7'b0100000);
```

### 3.2 控制信号 OR-reduction

每一类需要相同控制信号的指令做"或"运算：

```verilog
// 哪些指令需要写寄存器？
wire RF_OP_WE = ADDI | ORI | SLLI | LW | LUI | JAL | ADD | SUB | AND | OR | XOR | ...;

// 哪些指令的 ALU 第二操作数是立即数？
wire ALU_B_SEL_EXT = ADDI | ORI | SLLI | SLTI | ANDI | XORI | SRLI | SRAI | LW | ...;

// 哪些指令需要内存读取？
wire RAM_REN = LW | LH | LB | LHU | LBU;

// 哪些指令需要内存写入？
wire RAM_WEN = SW | SH | SB;
```

### 3.3 控制信号编码输出

```verilog
// alu_op 信号的编码输出（用 {N{condition}} & MACRO 模式）
assign alu_op = ( {5{ADD  }} & `ALU_ADD  ) |
                ( {5{SUB  }} & `ALU_SUB  ) |
                ( {5{AND  }} & `ALU_AND  ) |
                ( {5{OR   }} & `ALU_OR   ) |
                ( {5{XOR  }} & `ALU_XOR  ) |
                ( {5{SLL  }} & `ALU_SLL  ) |
                ( {5{SRL  }} & `ALU_SRL  ) |
                ( {5{SRA  }} & `ALU_SRA  ) |
                ( {5{SLT  }} & `ALU_SLT  ) |
                // ... 默认值
                ( {5{1'b0 }} & 5'h0       );
```

---

## 四、完整译码流程示意（以 ADD 指令为例）

```
指令: ADD x10, x5, x8
二进制: 0000000_01000_00101_000_01010_0110011
        └─funct7─┘└─rs2─┘└─rs1─┘└─f3─┘└─rd─┘└─opcode┘

步骤 1 — Opcode 检测
    opcode[6:0] = 0110011 → 命中 R-type
    → 初步判断：ALU运算、源操作数来自寄存器、结果写回寄存器

步骤 2 — funct3 检测
    funct3[14:12] = 000 → 命中 ADD/SUB 组
    → 缩小范围：是加法或减法

步骤 3 — funct7 检测
    funct7[31:25] = 0000000 → 命中 ADD
    → 最终确定：加法指令，ALU 执行 a + b

步骤 4 — 控制信号输出
    npc_op   = NPC_PC4     (顺序执行，不跳转)
    rf_we    = 1           (写回寄存器)
    rf_wsel  = WB_ALU      (写回数据来自 ALU 结果)
    sext_op  = EXT_I       (R型不需要立即数，但信号有默认值)
    alu_op   = ALU_ADD     (加法)
    alua_sel = ALU_A_RS1   (ALU 第一操作数 = rs1 = x5)
    alub_sel = ALU_B_RS2   (ALU 第二操作数 = rs2 = x8)
    ram_rop  = RAM_EXT_N   (不访问内存)

结果: x10 = x5 + x8
```

---

## 五、总结

| 译码级别 | 输入 | 决策内容 | 类比 |
|---------|------|---------|------|
| **第 1 级** | opcode[6:0] | 指令格式 + 基本类别（ALU/访存/分支/跳转） | 选**主干道** |
| **第 2 级** | opcode + funct3[14:12] | 具体操作（加/减/与/或/异或/移位）或数据宽度 | 选**岔路** |
| **第 3 级** | opcode + funct3 + funct7[31:25] | 最终区分（ADD vs SUB, SRL vs SRA） | 选**最终出口** |

**硬件本质**：

```
译码器 = 纯组合逻辑
       = 与门(AND) × N
       + 或门(OR) × M
       + 非门(NOT) × K

输入：32 个指令 bit 中的 opcode(7) + funct3(3) + funct7(7) = 17 个 bit
输出：若干根控制信号线（每个信号 1~5 bit 不等）

本质：一个多输入多输出的组合逻辑真值表，
      用与或非门实现，无状态、无时钟、即刻响应。
```

> 高效添加新指令的方法：先用 `数据通路表、控制信号取值表_miniRV - 模板.xlsx` 把新指令的 opcode/funct3/funct7 和对应的控制信号取值填好，然后按三级漏斗模型在 `Controller.v` 中添加译码 wire 和控制信号编码即可。
