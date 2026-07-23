# miniRV_basic 项目 Verilog 模块分析

> 分析日期: 2026-07-13
> 目标器件: xc7a35tcsg324-1 (基于 Xilinx Artix-7)
> 工具版本: Vivado v2023.2

---

## 一、项目文件总览

### 1.1 RTL 源文件 (.v)

| 文件路径 | 模块名 | 描述 |
|---------|--------|------|
| `src/rtl/miniRV_SoC.v` | `miniRV_SoC` | 顶层 SoC 模块 |
| `src/rtl/cpu_top.v` | `cpu_top` | CPU 顶层（核心+存储器互联） |
| `src/rtl/cpu_core.v` | `cpu_core` | CPU 核心（五级流水线） |
| `src/rtl/ALU.v` | `ALU` | 算术逻辑单元 |
| `src/rtl/Controller.v` | `Controller` | 控制器（指令译码） |
| `src/rtl/Data_RAM.v` | `Data_RAM` | 数据存储器封装 |
| `src/rtl/Inst_ROM.v` | `Inst_ROM` | 指令存储器封装 |
| `src/rtl/MEXT.v` | `MEXT` | 内存读数据扩展 |
| `src/rtl/MREQ.v` | `MREQ` | 内存请求生成 |
| `src/rtl/NPC.v` | `NPC` | 下一 PC 计算 |
| `src/rtl/PC.v` | `PC` | 程序计数器 |
| `src/rtl/RF.v` | `RF` | 寄存器堆 |
| `src/rtl/SEXT.v` | `SEXT` | 立即数符号扩展 |
| `src/rtl/multiplier.v` | `multiplier` | 乘法器（参数化） |
| `src/rtl/divider.v` | `divider` | 除法器（参数化） |

### 1.2 头文件

| 文件路径 | 描述 |
|---------|------|
| `src/rtl/defines.vh` | 全局宏定义（指令编码、控制信号编码、地址空间映射） |

### 1.3 IP 核文件

| 文件路径 | IP 核名 | 描述 |
|---------|---------|------|
| `src/rtl/ip/IROM/IROM_stub.v` | `IROM` | 指令 ROM IP stub |
| `src/rtl/ip/IROM/IROM_sim_netlist.v` | `IROM` | 指令 ROM 仿真网表 |
| `src/rtl/ip/DRAM/DRAM_stub.v` | `DRAM` | 数据 RAM IP stub |
| `src/rtl/ip/DRAM/DRAM_sim_netlist.v` | `DRAM` | 数据 RAM 仿真网表 |
| `src/rtl/ip/clk_wiz_0/clk_wiz_0.xci` | `clk_wiz_0` | PLL 时钟 IP |

---

## 二、模块层次结构（依赖关系图）

```
miniRV_SoC.v (顶层)
├── `include "defines.vh"`
├── clk_wiz_0 (Xilinx PLL IP)          ← 时钟生成
└── cpu_top.v
    ├── `include "defines.vh"`
    ├── cpu_core.v
    │   ├── `include "defines.vh"`
    │   ├── NPC.v                       ← 下一PC计算
    │   ├── PC.v                        ← 程序计数器
    │   ├── Controller.v                ← 指令译码/控制信号
    │   │   └── `include "defines.vh"`
    │   ├── RF.v                        ← 寄存器堆
    │   ├── SEXT.v                      ← 立即数扩展
    │   ├── ALU.v                       ← 算术逻辑单元
    │   │   ├── `include "defines.vh"`
    │   │   ├── multiplier.v (×2)       ← 有符号/无符号乘法器
    │   │   └── divider.v (×2)          ← 有符号/无符号除法器
    │   ├── MREQ.v                      ← 内存请求生成
    │   │   └── `include "defines.vh"`
    │   └── MEXT.v                      ← 内存读数据扩展
    │       └── `include "defines.vh"`
    ├── Inst_ROM.v
    │   ├── `include "defines.vh"`
    │   └── IROM (Xilinx Block Memory IP)
    └── Data_RAM.v
        ├── `include "defines.vh"`
        └── DRAM (Xilinx Block Memory IP)
```

### 依赖关系总结

| 模块 | 直接实例化的子模块 | 依赖的 include 文件 |
|------|-------------------|-------------------|
| `miniRV_SoC` | `clk_wiz_0`, `cpu_top` | `defines.vh` |
| `cpu_top` | `cpu_core`, `Inst_ROM`, `Data_RAM` | `defines.vh` |
| `cpu_core` | `NPC`, `PC`, `Controller`, `RF`, `SEXT`, `ALU`, `MREQ`, `MEXT` | `defines.vh` |
| `ALU` | `multiplier`×2, `divider`×2 | `defines.vh` |
| `Inst_ROM` | `IROM` (IP) | `defines.vh` |
| `Data_RAM` | `DRAM` (IP) | `defines.vh` |
| `Controller` | *(纯组合逻辑，无子模块)* | `defines.vh` |
| `NPC` | *(纯组合逻辑，无子模块)* | *(无)* |
| `PC` | *(时序逻辑，无子模块)* | *(无)* |
| `RF` | *(时序逻辑，无子模块)* | *(无)* |
| `SEXT` | *(纯组合逻辑，无子模块)* | *(无)* |
| `MREQ` | *(纯组合逻辑，无子模块)* | `defines.vh` |
| `MEXT` | *(纯组合逻辑，无子模块)* | `defines.vh` |
| `multiplier` | *(未实现，TODO 状态)* | *(无)* |
| `divider` | *(未实现，TODO 状态)* | *(无)* |

---

## 三、各模块功能详解

### 3.1 `miniRV_SoC` — 顶层 SoC 模块

**功能**: 整个系统的顶层封装，连接 FPGA 外部引脚与 CPU 内部核心。

**主要输入输出**:
- 输入: `fpga_clk`（板载时钟）、`fpga_rst`（低有效复位）、`sw[15:0]`（拨码开关）、`rx`（串口接收）
- 输出: `led[15:0]`（LED）、`dig_en[7:0]`/`dig_seg[7:0]`/`dig_seg1[7:0]`（数码管）、`tx`（串口发送）

**关键逻辑**: 通过 PLL (`clk_wiz_0`) 产生稳定的系统时钟，当 PLL 锁定后系统才释放复位，开始运行。

---

### 3.2 `cpu_top` — CPU 顶层

**功能**: 连接 CPU 核心 (`cpu_core`) 与指令存储器 (`Inst_ROM`)、数据存储器 (`Data_RAM`)。

**互联信号**:
- **取指接口**: `cpu2ic_rreq`, `cpu2ic_addr` → `Inst_ROM`; `Inst_ROM` → `ic2cpu_valid`, `ic2cpu_inst`
- **数据访存接口**: `cpu2dc_ren`, `cpu2dc_addr`, `cpu2dc_wen`, `cpu2dc_wdata` → `Data_RAM`; `Data_RAM` → `dc2cpu_valid`, `dc2cpu_rdata`, `dc2cpu_wresp`

---

### 3.3 `cpu_core` — CPU 核心

**功能**: 五级流水线 RISC-V (RV32I 子集) CPU 核心，包含 IF/ID/EX/MEM/WB 五个阶段。

**流水线阶段概览**:

| 阶段 | 英文 | 主要工作 |
|------|------|---------|
| IF | Instruction Fetch | PC 更新、取指请求发送 |
| ID | Instruction Decode | 指令译码、寄存器读取、立即数扩展 |
| EX | Execute | ALU 运算、乘除法、分支判断 |
| MEM | Memory Access | 读写数据存储器、数据对齐/扩展 |
| WB | Write Back | 结果写回寄存器堆 |

**关键控制信号**:
- `npc_op`: 选择下一条指令地址（PC+4 / 分支 / 跳转）
- `rf_wsel`: 选择写回寄存器的数据来源（ALU / 内存 / PC+4 / 立即数）
- `sext_op`: 选择立即数扩展类型（I / B / U / J 型）
- `alu_op`: 选择 ALU 操作类型
- `ram_rop` / `ram_wop`: 选择内存读写宽度

**多周期指令处理**:
- 访存指令 (`ld_st_flag`) 和乘除法指令 (`mul_div_flag`) 需要多周期完成
- 普通指令单周期完成（取指即执行完成）

---

### 3.4 `NPC` — 下一 PC 计算

**功能**: 根据当前 PC 和控制信号计算下一 PC 值。

| `npc_op` 值 | 含义 | 计算方式 |
|-------------|------|---------|
| `NPC_PC4` (2'b00) | PC+4 | `npc = pc + 4` |
| `NPC_BRA` (2'b10) | 条件分支 | `npc = br ? pc + offset : pc + 4` |
| `NPC_JMP` (2'b11) | 无条件跳转 | `npc = pc + offset` |

**与 `defines.vh` 关系**: 不直接 include，但依赖宏定义 `NPC_PC4`/`NPC_BRA`/`NPC_JMP`（通过上层模块传入）。

---

### 3.5 `PC` — 程序计数器

**功能**: 程序计数器寄存器。复位时初始化为 `PC_INIT_VAL` (32'h0)，`fetch` 信号有效时更新为 `npc` 值。

---

### 3.6 `Controller` — 控制器

**功能**: 纯组合逻辑，根据指令的 `opcode`、`funct3`、`funct7` 字段生成所有控制信号。

**当前支持的指令集** (RV32I 子集):

| 指令 | 类型 | opcode | funct3 | 功能 |
|------|------|--------|--------|------|
| `ADDI` | I-type | 0010011 | 000 | 立即数加法 |
| `ORI` | I-type | 0010011 | 110 | 立即数或 |
| `SLLI` | I-type | 0010011 | 001 | 立即数左移 |
| `LW` | I-type | 0000011 | 010 | 加载字 |
| `BEQ` | B-type | 1100011 | 000 | 相等分支 |
| `BNE` | B-type | 1100011 | 001 | 不等分支 |
| `LUI` | U-type | 0110111 | — | 加载立即数到高位 |
| `JAL` | J-type | 1101111 | — | 跳转并链接 |

**乘除法指令**: `is_mul` 和 `is_div` 信号当前固定为 0，表示乘除法硬件存在但未被当前译码逻辑使用。

---

### 3.7 `RF` — 寄存器堆

**功能**: 32 个 32-bit 通用寄存器，x0 硬连线为 0。

**特性**:
- 双读口 (rR1 → rD1, rR2 → rD2)
- 单写口 (we 有效时写入选定寄存器)
- 寄存器 x0 (wR=0) 不能被写入
- 同步时钟写入（写使能 + posedge clk）

---

### 3.8 `SEXT` — 立即数扩展

**功能**: 根据指令类型，将 25-bit 的 `imm[31:7]` 扩展为 32-bit 立即数。

| `sext_op` 值 | 类型 | 扩展方式 |
|-------------|------|---------|
| `EXT_I` (3'b000) | I-type | 12-bit 符号扩展到 32-bit |
| `EXT_B` (3'b010) | B-type | 13-bit 符号扩展（含分支偏移重组） |
| `EXT_U` (3'b011) | U-type | 20-bit 高位移位（LUI） |
| `EXT_J` (3'b100) | J-type | 21-bit 符号扩展（含跳转偏移重组） |

---

### 3.9 `ALU` — 算术逻辑单元

**功能**: 执行算术/逻辑运算和分支比较。内部还实例化了乘法器和除法器。

**当前实现的运算**:

| `alu_op` 值 | 操作 | 说明 |
|-------------|------|------|
| `ALU_ADD` (5'h00) | `c = a + b` | 加法 |
| `ALU_OR` (5'h03) | `c = a \| b` | 按位或 |
| `ALU_SLL` (5'h05) | `c = a << b[4:0]` | 左移 |
| `ALU_EQ` (5'h08) | `br = (a == b)` | 相等比较 |
| `ALU_NE` (5'h09) | `br = (a != b)` | 不等比较 |

**乘除法硬件**: `multiplier` 和 `divider` 已实例化在代码中，但 `mul_flag`/`mulu_flag`/`div_flag`/`divu_flag` 信号当前固定为 0，乘除法运算未被激活使用。

---

### 3.10 `MREQ` — 内存请求生成

**功能**: 将 CPU 的 Load/Store 指令转换为对数据总线的读写请求。

**写操作处理**:
- `RAM_WE_W` (sw): 生成 4-bit 写使能 `da_wen = 4'hF`（要求字对齐）
- `RAM_WE_B` (sb)、`RAM_WE_H` (sh): TODO 状态

**读操作处理**:
- `ram_rop != RAM_EXT_N` 时生成读请求
- 非字宽度的读操作（lb, lbu, lh, lhu）处于 TODO 状态

---

### 3.11 `MEXT` — 内存读数据扩展

**功能**: 将从数据存储器读回的 32-bit 数据进行字节对齐调整，并根据 Load 指令类型进行符号/零扩展。

**处理流程**: 先根据 `byte_offs` 进行字节移位 → 再根据 `op` 进行扩展

**当前状态**: `RAM_EXT_B`/`RAM_EXT_BU`/`RAM_EXT_H`/`RAM_EXT_HU` 的扩展逻辑返回 0（TODO），只有 `RAM_EXT_W` (lw) 功能完整。

---

### 3.12 `Inst_ROM` — 指令存储器封装

**功能**: 封装 `IROM` IP 核，为 CPU 提供指令读取接口。

**接口协议**: 当 `inst_rreq` 有效时，下一周期通过 `inst_valid` 返回有效数据和 `inst_out`。

---

### 3.13 `Data_RAM` — 数据存储器封装

**功能**: 封装 `DRAM` IP 核，为 CPU 提供数据读写接口。

**接口协议**: 
- 读: `data_ren` 非零时下一周期返回 `data_valid` + `data_rdata`
- 写: `data_wen` 非零时下一周期返回 `data_wresp`

---

### 3.14 `multiplier` / `divider` — 乘除法器

**功能**: 参数化的乘法器和除法器，借助 Xilinx DSP 或 LUT 资源实现。

**当前状态**: 两个模块均为 **TODO 未完成**状态，只有端口声明，内部逻辑尚未实现。设计中预留了乘除法指令的信号通路（`is_mul`, `is_div`, `mul_div_busy` 等），但控制器当前不触发乘除法操作。

---

## 四、IP 核说明

### 4.1 `clk_wiz_0` — 时钟 IP (Xilinx Clocking Wizard)

| 属性 | 值 |
|------|-----|
| IP 类型 | Xilinx Clocking Wizard |
| 用途 | 将 FPGA 外部时钟经 PLL 倍频/分频后生成稳定的系统时钟 |
| 输入 | `clk_in1` (fpga_clk) |
| 输出 | `clk_out1` (系统时钟), `locked` (PLL 锁定信号) |
| 配置 | `.xci` 文件（Vivado IP 配置文件） |

**在 `miniRV_SoC` 中的处理**: 将 `pll_clk1` 与 `pll_lock` 进行 AND 操作后作为系统时钟 (`sys_clk`)，确保 PLL 锁定后才有时钟进入 CPU。`RUN_TRACE` 宏定义在仿真时绕过 PLL，直接使用 `fpga_clk`。

---

### 4.2 `IROM` — 指令 ROM IP (Xilinx Block Memory Generator v8.4)

| 属性 | 值 |
|------|-----|
| IP VLNV | `xilinx.com:ip:blk_mem_gen:8.4` |
| 用途 | 存放 CPU 执行指令的程序存储器（只读） |
| 类型 | Single-Port Block RAM (Native Interface) |
| 数据宽度 | 32-bit |
| 地址宽度 | 14-bit (16384 深度) |
| 实际容量 | 8192 字节（MEM_SIZE=8192） |
| 初始化 | 通过 `.coe` 文件（位于 `src/coe/`）初始化 |
| 读延迟 | 1 时钟周期 |

**端口定义**:
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clka` | Input | 1 | 时钟 |
| `addra` | Input | 14 | 地址（CPU addr[15:2]，因为数据 32-bit 对齐） |
| `douta` | Output | 32 | 读出数据 |

**相关文件**:
- `IROM_stub.v` / `IROM_stub.vhdl`: 综合用的黑盒 stub
- `IROM_sim_netlist.v` / `IROM_sim_netlist.vhdl`: 仿真用的网表
- `simulation/blk_mem_gen_v8_4.v`: 行为级仿真模型
- `synth/IROM.vhd`: 综合用的 VHDL 封装
- `IROM.xci`: Vivado IP 配置文件
- `IROM.mif`: 内存初始化文件

---

### 4.3 `DRAM` — 数据 RAM IP (Xilinx Block Memory Generator v8.4)

| 属性 | 值 |
|------|-----|
| IP VLNV | `xilinx.com:ip:blk_mem_gen:8.4` |
| 用途 | 存放 CPU 运行时数据（可读写） |
| 类型 | Single-Port Block RAM (Native Interface) with Byte-Write Enable |
| 数据宽度 | 32-bit |
| 地址宽度 | 15-bit (32768 深度) |
| 实际容量 | 8192 字节（MEM_SIZE=8192） |
| 写使能 | 4-bit 字节级写使能 (wea[3:0]) |
| 读写延迟 | 1 时钟周期 |

**端口定义**:
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clka` | Input | 1 | 时钟 |
| `wea` | Input | 4 | 字节写使能（1 位控制 1 字节） |
| `addra` | Input | 15 | 地址（CPU addr[16:2]） |
| `dina` | Input | 32 | 写入数据 |
| `douta` | Output | 32 | 读出数据 |

**与 IROM 的关键区别**: DRAM 有 `wea` 和 `dina` 端口，支持字节级写入；IROM 只有 `douta` 只读端口。

**相关文件**:
- `DRAM_stub.v` / `DRAM_stub.vhdl`: 综合用的黑盒 stub
- `DRAM_sim_netlist.v` / `DRAM_sim_netlist.vhdl`: 仿真用的网表
- `simulation/blk_mem_gen_v8_4.v`: 行为级仿真模型
- `synth/DRAM.vhd`: 综合用的 VHDL 封装
- `DRAM.xci`: Vivado IP 配置文件
- `DRAM.mif`: 内存初始化文件

---

## 五、地址空间映射 (from defines.vh)

| 基地址 | 区域名称 | 大小 | 说明 |
|--------|---------|------|------|
| `0x0000_0000` | `MEM_BLOCK_MEMORY` | 512KB | 块状存储器 (BRAM) |
| `0x2000_0000` | `MEM_DDR3` | 512MB | DDR3 内存 |
| `0xFFFF_0000` | `PERI_ADDR_SWITCH` | — | 拨码开关 |
| `0xFFFF_1000` | `PERI_ADDR_LED` | — | LED |
| `0xFFFF_2000` | `PERI_ADDR_DIGLED` | — | 数码管 |
| `0xFFFF_3000` | `PERI_ADDR_UART` | — | 串口 |
| `0xFFFF_4000` | `PERI_ADDR_TIMER` | — | 定时器 |

---

## 六、当前项目状态总结

### 已实现的功能
- ✅ RV32I 基础指令: ADDI, ORI, SLLI, LW, BEQ, BNE, LUI, JAL (共 8 条)
- ✅ 五级流水线 CPU 核心 (IF/ID/EX/MEM/WB)
- ✅ 多周期指令支持框架 (访存、乘除法的 busy/flag 机制)
- ✅ 指令 ROM 和数据 RAM (基于 Xilinx BRAM IP)
- ✅ PLL 时钟生成
- ✅ 寄存器堆 (32 个 32-bit 寄存器)
- ✅ 分支和跳转支持

### 未完成 / TODO 的功能
- ❌ **乘除法器**: `multiplier.v` 和 `divider.v` 内部逻辑未实现
- ❌ **字节/半字读写**: `MREQ.v` 中的 `sb`/`sh`/`lb`/`lbu`/`lh`/`lhu` 指令的内存访问逻辑未实现
- ❌ **内存读扩展**: `MEXT.v` 中的 `RAM_EXT_B`/`RAM_EXT_BU`/`RAM_EXT_H`/`RAM_EXT_HU` 扩展逻辑未实现
- ❌ **ALU 完整运算**: 减法、异或、右移、比较等 RV32I 指令尚未添加
- ❌ **外设接口**: `miniRV_SoC` 中定义了 SW/LED/数码管/UART/Timer 的端口，但未实现与外设的连接逻辑
- ❌ **RV32I 剩余指令**: 大量基础整数指令尚未加入 Controller 的译码逻辑

---

## 七、关键设计参数 (defines.vh)

| 宏定义 | 值 | 说明 |
|--------|-----|------|
| `PC_INIT_VAL` | `32'h0` | 程序计数器复位初值 |
| `ALU_ADD` | `5'h00` | 加法操作码 |
| `ALU_OR` | `5'h03` | 按位或操作码 |
| `ALU_SLL` | `5'h05` | 左移操作码 |
| `ALU_EQ` | `5'h08` | 相等比较操作码 |
| `ALU_NE` | `5'h09` | 不等比较操作码 |
| `NPC_PC4` | `2'b00` | 顺序执行 |
| `NPC_BRA` | `2'b10` | 条件分支 |
| `NPC_JMP` | `2'b11` | 无条件跳转 |
| `EXT_I/B/U/J` | `3'b000/010/011/100` | 立即数扩展类型 |
| `WB_ALU/RAM/PC4/EXT` | `2'b00/01/10/11` | 写回数据来源选择 |
| `IC_BLK_LEN` | `1` (默认) / `4` (ICACHE使能时) | 指令缓存块长度 |
| `DC_BLK_LEN` | `1` (默认) / `4` (DCACHE使能时) | 数据缓存块长度 |
